// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 OpenHarmony PC Image Contributors

// Multi-tab terminal for pc_ptl (2in1 / x86_64), OpenHarmony.
//
// UI/UX references (design only, no code copied):
//   * GNOME Terminal / Ubuntu Terminal -- "tab strip on top + pure terminal
//     canvas, no extra toolbars", Ctrl+Shift+T/W/C/V, Ctrl+PageUp/PageDown.
//   * iTerm2 "Minimal/Compact" appearance -- short top tab bar, active tab
//     highlighted, one close glyph per tab, a single "+" tab button.
//   * Termony (OHOS, Apache-2.0) -- proved the OHOS input plumbing we now use:
//     KeyEvent.unicode for text + KeyEvent.keyText ("KEYCODE_*") for specials,
//     AxisEvent#getVerticalAxisValue() for the wheel, and the IME controller
//     (insertText / deleteLeft / sendFunctionKey) for soft-keyboard input.
//   * par-term / tabit (debuggeando) -- tab bar overflow is handled by
//     horizontally scrolling the tab strip instead of an overflow menu.
//
// No on-screen "mobile shortcut" key row is used (explicitly rejected): the
// window is a tab bar plus the terminal surface, exactly like a desktop
// terminal.  Every OS key (Backspace, arrows, Home/End, PgUp/PgDn, F-keys,
// Ctrl+<letter>, ...) is translated to the correct xterm byte sequence.

import { BusinessError } from '@kit.BasicServicesKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { inputMethod } from '@kit.IMEKit';
import font from '@ohos.font';
import promptAction from '@ohos.promptAction';
import { Terminal } from '../model/terminal';
import { Theme, THEMES, themeById } from '../model/theme';
import { Session } from '../model/session';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

const DOMAIN: number = 0x0011;
const TAG: string = 'OHOSTerm';

// Window-corner policy (see ARKUI_UI_STANDARD.md §10).
//
// The system decoration draws the window frame with rounded corners and a drop
// shadow, and EntryAbility keeps the *window* background transparent
// (#00000000) so that frame stays visible.  The page must therefore not paint
// a square opaque surface over it: every interactive area lives in ONE inner
// container that is inset by OUTER_PAD and clipped to WIN_RADIUS.
//
//   OUTER_PAD  : uniform gap between the window edge and the content surface,
//                so the decoration's rounded corner pixels are never covered.
//   WIN_RADIUS : radius of that inner surface; must be <= the decoration's
//                radius so the two curves nest instead of crossing.
//
// Never set both to 0 for a decorated window: that is exactly what makes the
// terminal's interactive area (canvas + tab row) look like it overflows the
// rounded corner.
const OUTER_PAD: number = 6;
const WIN_RADIUS: number = 10;

// Settings option tables.
class Opt {
  id: string;
  label: string;
  constructor(id: string, label: string) {
    this.id = id;
    this.label = label;
  }
}

const FONT_OPTS: Opt[] = [
  new Opt('Mono', 'Noto Sans Mono'),
  new Opt('MonoLight', 'Noto Sans Mono Light'),
  new Opt('MonoCond', 'Noto Sans Mono Condensed')
];

const CURSOR_OPTS: Opt[] = [
  new Opt('block', '块状'),
  new Opt('underline', '下划线'),
  new Opt('bar', '竖线')
];

const SCROLLBACK_OPTS: Opt[] = [
  new Opt('1000', '1000'),
  new Opt('5000', '5000'),
  new Opt('20000', '20000'),
  new Opt('50000', '50000')
];

const TABWIDTH_OPTS: Opt[] = [
  new Opt('2', '2'),
  new Opt('4', '4'),
  new Opt('8', '8')
];

// What to do when the last tab's shell ends (`exit`).
const LASTTAB_OPTS: Opt[] = [
  new Opt('close-last-tab', '关闭应用'),
  new Opt('keep-app', '保留空窗口')
];

class TabInfo {
  id: number = 0;
  title: string = '';
  constructor(id: number, title: string) {
    this.id = id;
    this.title = title;
  }
}

function clampInt(v: number, lo: number, hi: number): number {
  return v < lo ? lo : (v > hi ? hi : v);
}

@Entry
@Component
struct Index {
  @State tabs: TabInfo[] = [];
  @State activeId: number = -1;
  @State fontSize: number = 15;
  @State fontFamily: string = 'Mono';
  @State themeId: string = 'dark';
  @State cursorStyle: string = 'block';
  @State scrollbackLines: number = 5000;
  @State tabWidth: number = 8;
  @State showSettings: boolean = false;
  @State status: string = '';
  // What happens when the last remaining tab ends (the user typed `exit`):
  //   'close-last-tab' -> the terminal app closes (default, desktop-like)
  //   'keep-app'       -> stay open with an empty terminal area
  @State lastTabBehavior: string = 'close-last-tab';
  @State windowMaximized: boolean = false;

  private sessions: Session[] = [];
  private nextId: number = 1;
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private timer: number = -1;
  private cellW: number = 9;
  private cellH: number = 21;
  private padX: number = 8;
  private padY: number = 6;
  private vw: number = 0;
  private vh: number = 0;
  private areaW: number = 0;
  private areaH: number = 0;
  private lastCols: number = 0;
  private lastRows: number = 0;
  private blinkOn: boolean = true;
  private blinkTick: number = 0;
  private ctrlDown: boolean = false;
  private shiftDown: boolean = false;
  private altDown: boolean = false;
  private wheelAcc: number = 0;
  private fontLoaded: boolean = false;
  // selection (for the active session)
  private selActive: boolean = false;
  private selStartAbs: number = 0;
  private selStartCol: number = 0;
  private selEndAbs: number = 0;
  private selEndCol: number = 0;
  private mouseDown: boolean = false;
  private canvasGX: number = 0;
  private canvasGY: number = 0;
  private imeAttached: boolean = false;
  // pre-maximize window rect, restored by toggleMaximize()
  private savedRect: number[] = [0, 0, 1000, 640];
  private imController: inputMethod.InputMethodController = inputMethod.getController();

  private th(): Theme {
    return themeById(this.themeId);
  }

  aboutToAppear(): void {
    this.loadSettings();
    // Register bundled monospace fonts (the device ships no monospace family).
    try {
      font.registerFont({ familyName: 'Mono', familySrc: $rawfile('NotoSansMono-Regular.ttf') });
      font.registerFont({ familyName: 'MonoB', familySrc: $rawfile('NotoSansMono-Bold.ttf') });
      font.registerFont({ familyName: 'MonoLight', familySrc: $rawfile('NotoSansMono-Light.ttf') });
      font.registerFont({ familyName: 'MonoCond', familySrc: $rawfile('NotoSansMono-Condensed.ttf') });
      this.fontLoaded = true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'registerFont failed %{public}s', JSON.stringify(e));
    }
    this.timer = setInterval((): void => {
      this.blinkTick++;
      if (this.blinkTick >= 16) {
        this.blinkTick = 0;
        this.blinkOn = !this.blinkOn;
        const s = this.activeSession();
        if (s) { s.term.dirty = true; }
      }
      const s = this.activeSession();
      if (!s) { return; }
      if (s.term.dirty) {
        s.term.dirty = false;
        this.draw();
      }
      this.computeSize(s);
    }, 33);
    this.setupIme();
    this.newTab();
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) { clearInterval(this.timer); }
    for (let i = 0; i < this.sessions.length; i++) { this.sessions[i].close(); }
    this.sessions = [];
  }

  // ---- persisted settings --------------------------------------------------
  private prefs(): preferences.Preferences | undefined {
    try {
      const ctx = this.getUIContext().getHostContext() as common.Context;
      if (ctx === undefined || ctx === null) { return undefined; }
      return preferences.getPreferencesSync(ctx, { name: 'term_settings' });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'prefs open failed %{public}s', JSON.stringify(e));
      return undefined;
    }
  }

  private loadSettings(): void {
    try {
      const p = this.prefs();
      if (p === undefined) { return; }
      this.fontSize = clampInt(p.getSync('fontSize', 15) as number, 8, 40);
      this.fontFamily = p.getSync('fontFamily', 'Mono') as string;
      this.themeId = p.getSync('theme', 'dark') as string;
      this.cursorStyle = p.getSync('cursor', 'block') as string;
      this.scrollbackLines = p.getSync('scrollback', 5000) as number;
      this.tabWidth = p.getSync('tabWidth', 8) as number;
      this.lastTabBehavior = p.getSync('lastTabBehavior', 'close-last-tab') as string;
      hilog.info(DOMAIN, TAG, 'settings loaded fs=%{public}d theme=%{public}s',
        this.fontSize, this.themeId);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'loadSettings failed %{public}s', JSON.stringify(e));
    }
  }

  private saveSettings(): void {
    try {
      const p = this.prefs();
      if (p === undefined) { return; }
      p.putSync('fontSize', this.fontSize);
      p.putSync('fontFamily', this.fontFamily);
      p.putSync('theme', this.themeId);
      p.putSync('cursor', this.cursorStyle);
      p.putSync('scrollback', this.scrollbackLines);
      p.putSync('tabWidth', this.tabWidth);
      p.putSync('lastTabBehavior', this.lastTabBehavior);
      p.flush();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'saveSettings failed %{public}s', JSON.stringify(e));
    }
  }

  // Apply the current settings to every live session.
  private applySettingsToSessions(): void {
    for (let i = 0; i < this.sessions.length; i++) {
      const s = this.sessions[i];
      s.term.applyTheme(this.th());
      s.term.setScrollback(this.scrollbackLines);
      s.term.setTabWidth(this.tabWidth);
      s.term.setCursorStyle(this.cursorStyle);
    }
  }

  setFontSize(v: number): void {
    const nf = clampInt(Math.round(v), 8, 40);
    if (nf === this.fontSize) { return; }
    this.fontSize = nf;
    this.applyFont();
    const s = this.activeSession();
    if (s) {
      this.lastCols = 0;
      this.lastRows = 0;
      this.computeSize(s);
      s.term.dirty = true;
    }
    this.saveSettings();
    this.draw();
  }

  setFontFamily(f: string): void {
    if (f === this.fontFamily) { return; }
    this.fontFamily = f;
    this.applyFont();
    const s = this.activeSession();
    if (s) {
      this.lastCols = 0;
      this.lastRows = 0;
      this.computeSize(s);
      s.term.dirty = true;
    }
    this.saveSettings();
    this.draw();
  }

  setTheme(id: string): void {
    if (id === this.themeId) { return; }
    this.themeId = id;
    this.applySettingsToSessions();
    this.saveSettings();
    this.draw();
  }

  setCursorStyle(c: string): void {
    if (c === this.cursorStyle) { return; }
    this.cursorStyle = c;
    this.applySettingsToSessions();
    this.saveSettings();
    this.draw();
  }

  setScrollbackLines(n: number): void {
    if (n === this.scrollbackLines) { return; }
    this.scrollbackLines = n;
    this.applySettingsToSessions();
    this.saveSettings();
    this.draw();
  }

  setTabWidth(n: number): void {
    if (n === this.tabWidth) { return; }
    this.tabWidth = n;
    this.applySettingsToSessions();
    this.saveSettings();
    this.draw();
  }

  // ---- IME (soft keyboard) -------------------------------------------------
  // The soft keyboard / IME is off by default: on a 2-in-1 the physical
  // keyboard is delivered straight to onKeyEvent as clean ASCII, exactly like
  // a desktop terminal.  The IME is attached on demand (Ctrl+Shift+K) for
  // touch input; while it is attached the IME composes keystrokes, so it is
  // deliberately not forced on.
  setupIme(): void {
    // nothing to do until the user toggles it; listeners are registered on attach
  }

  private registerImeListeners(): void {
    try {
      this.imController.on('insertText', (text: string): void => {
        if (text.length > 0) { this.sendInputStr(text); }
      });
      this.imController.on('deleteLeft', (len: number): void => {
        for (let i = 0; i < len; i++) { this.sendInputStr('\x7f'); }
      });
      this.imController.on('sendFunctionKey', (fk: inputMethod.FunctionKey): void => {
        this.sendInputStr('\r');
      });
      hilog.info(DOMAIN, TAG, 'ime listeners registered');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'ime listeners %{public}s', JSON.stringify(e));
    }
  }

  toggleIme(): void {
    if (this.imeAttached) {
      this.imController.detach().then((): void => {
        this.imeAttached = false;
        promptAction.showToast({ message: '软键盘已关闭', duration: 1000 });
      }).catch((e: BusinessError): void => {
        this.imeAttached = false;
      });
      return;
    }
    this.imController.attach(true, {
      inputAttribute: {
        textInputType: inputMethod.TextInputType.TEXT,
        enterKeyType: inputMethod.EnterKeyType.NEWLINE
      }
    }).then((): void => {
      this.imeAttached = true;
      this.registerImeListeners();
      promptAction.showToast({ message: '软键盘已开启', duration: 1000 });
    }).catch((e: BusinessError): void => {
      this.imeAttached = false;
      hilog.warn(DOMAIN, TAG, 'ime attach failed %{public}s', JSON.stringify(e));
      promptAction.showToast({ message: '输入法不可用', duration: 1200 });
    });
  }

  // ---- session / tabs ------------------------------------------------------
  activeSession(): Session | undefined {
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id === this.activeId) { return this.sessions[i]; }
    }
    return undefined;
  }

  private sessionById(id: number): Session | undefined {
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id === id) { return this.sessions[i]; }
    }
    return undefined;
  }

  private syncTabs(): void {
    const out: TabInfo[] = [];
    for (let i = 0; i < this.sessions.length; i++) {
      const s = this.sessions[i];
      out.push(new TabInfo(s.id, s.title.length > 0 ? s.title : ('Shell ' + s.id)));
    }
    this.tabs = out;
  }

  newTab(): void {
    this.ctrlDown = false; this.shiftDown = false; this.altDown = false;
    const cols: number = this.lastCols > 0 ? this.lastCols : 80;
    const rows: number = this.lastRows > 0 ? this.lastRows : 24;
    const id: number = this.nextId++;
    const sess: Session = new Session(id, cols, rows,
      (): void => { /* data arrives; the draw timer polls term.dirty */ },
      (): void => { this.syncTabs(); },
      (): void => { this.onSessionExited(id); });
    sess.term.applyTheme(this.th());
    sess.term.setScrollback(this.scrollbackLines);
    sess.term.setTabWidth(this.tabWidth);
    sess.term.setCursorStyle(this.cursorStyle);
    this.sessions.push(sess);
    this.syncTabs();
    this.activeId = id;
    this.clearSelection();
    sess.connect();
    const area: number[] = this.gridSize();
    if (area[0] > 0 && area[1] > 0) {
      sess.term.resize(area[0], area[1], this.vh);
      sess.sendResize(area[0], area[1]);
    }
    sess.term.dirty = true;
    this.requestFocus();
  }

  activateTab(id: number): void {
    if (id === this.activeId) { return; }
    this.activeId = id;
    this.clearSelection();
    const s = this.sessionById(id);
    if (s) {
      const area: number[] = this.gridSize();
      if (area[0] > 0 && area[1] > 0) {
        s.term.resize(area[0], area[1], this.vh);
        s.sendResize(area[0], area[1]);
      }
      s.term.dirty = true;
    }
    this.requestFocus();
    this.draw();
  }

  // Drop a tab without recreating one behind the user's back.  When the last
  // tab goes away the app either closes (default) or keeps an empty shell,
  // depending on the `lastTabBehavior` setting.
  private removeTab(id: number, closeSession: boolean): void {
    let idx: number = -1;
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id === id) { idx = i; break; }
    }
    if (idx < 0) { return; }
    if (closeSession) { this.sessions[idx].close(); }
    this.sessions.splice(idx, 1);
    if (this.sessions.length === 0) {
      this.syncTabs();
      this.activeId = -1;
      this.clearSelection();
      this.draw();
      if (this.lastTabBehavior === 'close-last-tab') { this.closeApp(); }
      return;
    }
    if (this.activeId === id) {
      const na: number = this.sessions[clampInt(idx, 0, this.sessions.length - 1)].id;
      this.activeId = na;
    }
    this.syncTabs();
    this.clearSelection();
    this.draw();
  }

  closeTab(id: number): void {
    this.removeTab(id, true);
  }

  // The shell of `id` ended on its own (`exit`, `logout`, killed).  Close that
  // tab; if it was the only one, apply the last-tab behaviour.
  onSessionExited(id: number): void {
    hilog.info(DOMAIN, TAG, 'session %{public}d exited, closing tab', id);
    this.removeTab(id, false);
  }

  closeApp(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (ctx === undefined || ctx === null) { return; }
      ctx.terminateSelf().catch((e: BusinessError): void => {
        hilog.warn(DOMAIN, TAG, 'terminateSelf failed %{public}s', JSON.stringify(e));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'closeApp failed %{public}s', JSON.stringify(e));
    }
  }

  // ---- frameless window control -------------------------------------------
  private async mainWindow(): Promise<window.Window | undefined> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (ctx === undefined || ctx === null) { return undefined; }
      return await window.getLastWindow(ctx);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getLastWindow failed %{public}s', JSON.stringify(e));
      return undefined;
    }
  }

  minimizeWindow(): void {
    this.mainWindow().then((w: window.Window | undefined): void => {
      if (w) { w.minimize(); }
    });
  }

  // OHOS has no `unmaximize()` in this SDK, so the pre-maximize rect is
  // remembered and restored with moveWindowTo()+resize().
  toggleMaximize(): void {
    this.mainWindow().then((w: window.Window | undefined): void => {
      if (!w) { return; }
      if (this.windowMaximized) {
        w.moveWindowTo(this.savedRect[0], this.savedRect[1]).then((): void => {
          w.resize(this.savedRect[2], this.savedRect[3]);
        }).catch((e: BusinessError): void => {
          hilog.warn(DOMAIN, TAG, 'restore %{public}s', JSON.stringify(e));
        });
        this.windowMaximized = false;
        return;
      }
      try {
        const r = w.getWindowProperties().windowRect;
        this.savedRect = [r.left, r.top, r.width, r.height];
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'getWindowProperties %{public}s', JSON.stringify(e));
      }
      w.maximize().then((): void => { this.windowMaximized = true; })
        .catch((e: BusinessError): void => {
          hilog.warn(DOMAIN, TAG, 'maximize %{public}s', JSON.stringify(e));
        });
    });
  }

  // NOTE: the window-drag helpers that used to live here (PanGesture +
  // moveWindowTo) were removed together with the self-drawn title bar.  With
  // the system decoration enabled the system title bar is the drag handle, so
  // a second drag implementation would only fight it.

  closeWindow(): void {
    this.closeApp();
  }

  nextTab(delta: number): void {
    if (this.sessions.length < 2) { return; }
    let idx: number = 0;
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id === this.activeId) { idx = i; break; }
    }
    const n: number = (idx + delta + this.sessions.length) % this.sessions.length;
    this.activateTab(this.sessions[n].id);
  }

  requestFocus(): void {
    try { focusControl.requestFocus('termcanvas'); } catch (e) { /* ignore */ }
  }

  // ---- font / geometry -----------------------------------------------------
  applyFont(): void {
    this.ctx.font = this.fontSize + 'px ' + this.fontFamily;
    let w: number = this.ctx.measureText('M').width;
    if (!(w > this.fontSize * 0.35 && w < this.fontSize * 1.3)) {
      w = this.fontSize * 0.6; // Noto Sans Mono advance = 0.6 em
    }
    this.cellW = Math.max(4, Math.round(w * 100) / 100);
    this.cellH = Math.round(this.fontSize * 1.4);
    this.ctx.textBaseline = 'top';
  }

  private fontFor(bold: boolean): string {
    if (bold) { return this.fontFamily === 'Mono' ? 'MonoB' : this.fontFamily; }
    return this.fontFamily;
  }

  private gridSize(): number[] {
    const w: number = (this.areaW > 0 ? this.areaW : this.ctx.width) - this.padX * 2;
    const h: number = (this.areaH > 0 ? this.areaH : this.ctx.height) - this.padY * 2;
    if (w <= 0 || h <= 0) { return [0, 0]; }
    let cw: number = this.cellW;
    let ch: number = this.cellH;
    if (cw <= 0) { cw = 9; }
    if (ch <= 0) { ch = 21; }
    const cols: number = Math.max(2, Math.floor(w / cw));
    const rows: number = Math.max(1, Math.floor(h / ch));
    return [cols, rows];
  }

  computeSize(s: Session): void {
    this.vw = this.areaW > 0 ? this.areaW : this.ctx.width;
    this.vh = this.areaH > 0 ? this.areaH : this.ctx.height;
    if (this.vw <= 0 || this.vh <= 0) { return; }
    const area: number[] = this.gridSize();
    const cols: number = area[0];
    const rows: number = area[1];
    const st: string = cols + 'x' + rows + (s.connected ? '' : ' ...');
    if (st !== this.status) { this.status = st; }
    if (cols !== s.term.cols || rows !== s.term.rows) {
      this.lastCols = cols;
      this.lastRows = rows;
      s.term.resize(cols, rows, this.vh);
      s.sendResize(cols, rows);
      s.term.dirty = true;
    }
  }

  // ---- transport shorthand -------------------------------------------------
  sendInputStr(s: string): void {
    const sess = this.activeSession();
    if (sess) { sess.sendInputStr(s); }
  }

  // ---- key handling --------------------------------------------------------
  // Map a printable key from its *key code* + Shift state instead of trusting
  // KeyEvent.unicode.  Some emulated/virtual keyboards report the shifted
  // unicode for every key (letters always uppercase, '-' as '_', ...), which
  // would corrupt typed commands; deriving the glyph from the US layout is
  // robust both on real hardware and under QEMU.
  private charForKey(kc: number): string {
    const shift: boolean = this.shiftDown;
    if (kc >= KeyCode.KEYCODE_A && kc <= KeyCode.KEYCODE_Z) {
      const c: string = String.fromCharCode(97 + (kc - KeyCode.KEYCODE_A));
      return shift ? c.toUpperCase() : c;
    }
    if (kc >= KeyCode.KEYCODE_0 && kc <= KeyCode.KEYCODE_9) {
      const low: string = '0123456789';
      const high: string = ')!@#$%^&*(';
      const i: number = kc - KeyCode.KEYCODE_0;
      return shift ? high.charAt(i) : low.charAt(i);
    }
    if (kc >= KeyCode.KEYCODE_NUMPAD_0 && kc <= KeyCode.KEYCODE_NUMPAD_9) {
      return String.fromCharCode(48 + (kc - KeyCode.KEYCODE_NUMPAD_0));
    }
    switch (kc) {
      case KeyCode.KEYCODE_SPACE: return ' ';
      case KeyCode.KEYCODE_GRAVE: return shift ? '~' : '`';
      case KeyCode.KEYCODE_MINUS: return shift ? '_' : '-';
      case KeyCode.KEYCODE_EQUALS: return shift ? '+' : '=';
      case KeyCode.KEYCODE_LEFT_BRACKET: return shift ? '{' : '[';
      case KeyCode.KEYCODE_RIGHT_BRACKET: return shift ? '}' : ']';
      case KeyCode.KEYCODE_BACKSLASH: return shift ? '|' : '\\';
      case KeyCode.KEYCODE_SEMICOLON: return shift ? ':' : ';';
      case KeyCode.KEYCODE_APOSTROPHE: return shift ? '"' : '\'';
      case KeyCode.KEYCODE_COMMA: return shift ? '<' : ',';
      case KeyCode.KEYCODE_PERIOD: return shift ? '>' : '.';
      case KeyCode.KEYCODE_SLASH: return shift ? '?' : '/';
      case KeyCode.KEYCODE_STAR: return '*';
      case KeyCode.KEYCODE_POUND: return '#';
      case KeyCode.KEYCODE_PLUS: return '+';
      case KeyCode.KEYCODE_NUMPAD_DOT: return '.';
      default: return '';
    }
  }

  private specialSeq(keyCode: number): string {
    const s = this.activeSession();
    const app: boolean = s !== undefined ? s.term.appCursor : false;
    switch (keyCode) {
      case KeyCode.KEYCODE_DPAD_UP: return app ? '\x1bOA' : '\x1b[A';
      case KeyCode.KEYCODE_DPAD_DOWN: return app ? '\x1bOB' : '\x1b[B';
      case KeyCode.KEYCODE_DPAD_RIGHT: return app ? '\x1bOC' : '\x1b[C';
      case KeyCode.KEYCODE_DPAD_LEFT: return app ? '\x1bOD' : '\x1b[D';
      case KeyCode.KEYCODE_MOVE_HOME: return app ? '\x1bOH' : '\x1b[H';
      case KeyCode.KEYCODE_MOVE_END: return app ? '\x1bOF' : '\x1b[F';
      case KeyCode.KEYCODE_PAGE_UP: return '\x1b[5~';
      case KeyCode.KEYCODE_PAGE_DOWN: return '\x1b[6~';
      case KeyCode.KEYCODE_INSERT: return '\x1b[2~';
      case KeyCode.KEYCODE_FORWARD_DEL: return '\x1b[3~';
      case KeyCode.KEYCODE_F1: return '\x1bOP';
      case KeyCode.KEYCODE_F2: return '\x1bOQ';
      case KeyCode.KEYCODE_F3: return '\x1bOR';
      case KeyCode.KEYCODE_F4: return '\x1bOS';
      case KeyCode.KEYCODE_F5: return '\x1b[15~';
      case KeyCode.KEYCODE_F6: return '\x1b[17~';
      case KeyCode.KEYCODE_F7: return '\x1b[18~';
      case KeyCode.KEYCODE_F8: return '\x1b[19~';
      case KeyCode.KEYCODE_F9: return '\x1b[20~';
      case KeyCode.KEYCODE_F10: return '\x1b[21~';
      case KeyCode.KEYCODE_F11: return '\x1b[23~';
      case KeyCode.KEYCODE_F12: return '\x1b[24~';
      default: return '';
    }
  }

  // Intercept key events before ArkUI's default processing (Tab focus
  // traversal, IME).  Returning true marks the event consumed so Tab really
  // reaches the shell instead of moving the focus ring to the tab bar.
  private handleKey(e: KeyEvent): boolean {
    if (this.imeAttached) { return false; } // let the soft IME compose text
    this.onKey(e);
    return true;
  }

  onKey(e: KeyEvent): void {
    const kc: number = e.keyCode;
    // Prefer the framework's modifier state; fall back to locally tracked
    // flags.  This keeps typed case correct even if a Shift key-up is dropped.
    const osShift: boolean = e.getModifierKeyState !== undefined ? e.getModifierKeyState(['Shift']) : false;
    const osCtrl: boolean = e.getModifierKeyState !== undefined ? e.getModifierKeyState(['Ctrl']) : false;
    const osAlt: boolean = e.getModifierKeyState !== undefined ? e.getModifierKeyState(['Alt']) : false;
    this.shiftDown = osShift || this.shiftDown;
    this.ctrlDown = osCtrl || this.ctrlDown;
    this.altDown = osAlt || this.altDown;
    if (e.type === KeyType.Down) {
      if (kc === KeyCode.KEYCODE_CTRL_LEFT || kc === KeyCode.KEYCODE_CTRL_RIGHT) { this.ctrlDown = true; return; }
      if (kc === KeyCode.KEYCODE_SHIFT_LEFT || kc === KeyCode.KEYCODE_SHIFT_RIGHT) { this.shiftDown = true; return; }
      if (kc === KeyCode.KEYCODE_ALT_LEFT || kc === KeyCode.KEYCODE_ALT_RIGHT) { this.altDown = true; return; }

      // ---- desktop terminal shortcuts (never sent to the shell) ----
      if (this.ctrlDown && this.shiftDown) {
        if (kc === KeyCode.KEYCODE_T) { this.newTab(); return; }
        if (kc === KeyCode.KEYCODE_W) { this.closeTab(this.activeId); return; }
        if (kc === KeyCode.KEYCODE_C) { this.copySelection(); return; }
        if (kc === KeyCode.KEYCODE_V) { this.doPaste(); return; }
        if (kc === KeyCode.KEYCODE_EQUALS || kc === KeyCode.KEYCODE_NUMPAD_ADD) { this.changeFont(1); return; }
        if (kc === KeyCode.KEYCODE_MINUS || kc === KeyCode.KEYCODE_NUMPAD_SUBTRACT) { this.changeFont(-1); return; }
        if (kc === KeyCode.KEYCODE_K) { this.toggleIme(); return; }
        if (kc === KeyCode.KEYCODE_COMMA) { this.showSettings = true; return; }
        if (kc === KeyCode.KEYCODE_D) { this.toggleTheme(); return; }
        if (kc === KeyCode.KEYCODE_U) { this.cycleCursor(); return; }
        if (kc === KeyCode.KEYCODE_F) { this.cycleFont(); return; }
      }
      if (this.ctrlDown && !this.shiftDown) {
        if (kc === KeyCode.KEYCODE_PAGE_UP) { this.nextTab(-1); return; }
        if (kc === KeyCode.KEYCODE_PAGE_DOWN) { this.nextTab(1); return; }
        if (kc === KeyCode.KEYCODE_TAB) { this.nextTab(1); return; }
        if (kc === KeyCode.KEYCODE_COMMA) { this.showSettings = true; return; }
      }
      if (this.shiftDown && kc === KeyCode.KEYCODE_PAGE_UP) { this.scrollLines(5); return; }
      if (this.shiftDown && kc === KeyCode.KEYCODE_PAGE_DOWN) { this.scrollLines(-5); return; }
      if (this.shiftDown && kc === KeyCode.KEYCODE_MOVE_HOME) { this.scrollToTop(); return; }
      if (this.shiftDown && kc === KeyCode.KEYCODE_MOVE_END) { this.scrollToBottom(); return; }

      // ---- keys with a fixed escape sequence ----
      const seq: string = this.specialSeq(kc);
      if (seq.length > 0) { this.sendInputStr(seq); return; }
      if (kc === KeyCode.KEYCODE_ESCAPE) { this.sendInputStr('\x1b'); return; }
      if (kc === KeyCode.KEYCODE_TAB) { this.sendInputStr(this.shiftDown ? '\x1b[Z' : '\t'); return; }
      if (kc === KeyCode.KEYCODE_ENTER || kc === KeyCode.KEYCODE_NUMPAD_ENTER) {
        this.sendInputStr('\r');
        this.ctrlDown = false; this.shiftDown = false; this.altDown = false;
        return;
      }
      // Backspace is KEYCODE_DEL -> 0x7F (DEL); forward-delete is KEYCODE_FORWARD_DEL -> CSI 3~.
      if (kc === KeyCode.KEYCODE_DEL) { this.sendInputStr('\x7f'); return; }

      const uni: number = e.unicode !== undefined ? e.unicode : 0;
      // ---- Ctrl + letter / space -> C0 control byte ----
      if (this.ctrlDown) {
        if (uni >= 0x61 && uni <= 0x7a) { this.sendInputStr(String.fromCharCode(uni - 0x60)); return; }
        if (uni >= 0x41 && uni <= 0x5a) { this.sendInputStr(String.fromCharCode(uni - 0x40)); return; }
        if (kc === KeyCode.KEYCODE_SPACE || uni === 0x20) { this.sendInputStr('\x00'); return; }
        if (kc === KeyCode.KEYCODE_LEFT_BRACKET || uni === 0x5b) { this.sendInputStr('\x1b'); return; }
        if (kc === KeyCode.KEYCODE_BACKSLASH || uni === 0x5c) { this.sendInputStr('\x1c'); return; }
        if (kc === KeyCode.KEYCODE_RIGHT_BRACKET || uni === 0x5d) { this.sendInputStr('\x1d'); return; }
      }
      // ---- printable text: derive the glyph from keyCode + Shift ----
      const ch: string = this.charForKey(kc);
      if (ch.length > 0) {
        this.sendInputStr(ch);
        return;
      }
      // ---- fallback: KeyEvent.unicode (IME / non-US layouts) ----
      if (uni >= 0x20 && uni !== 0x7f) {
        this.sendInputStr(String.fromCharCode(uni));
        return;
      }
      // ---- last resort: some builds expose the character in keyText ----
      const kt: string = e.keyText;
      if (kt.length === 1 && kt.charCodeAt(0) >= 0x20) { this.sendInputStr(kt); }
    } else if (e.type === KeyType.Up) {
      if (kc === KeyCode.KEYCODE_CTRL_LEFT || kc === KeyCode.KEYCODE_CTRL_RIGHT) { this.ctrlDown = false; }
      if (kc === KeyCode.KEYCODE_SHIFT_LEFT || kc === KeyCode.KEYCODE_SHIFT_RIGHT) { this.shiftDown = false; }
      if (kc === KeyCode.KEYCODE_ALT_LEFT || kc === KeyCode.KEYCODE_ALT_RIGHT) { this.altDown = false; }
    }
  }

  // ---- scrolling / font ----------------------------------------------------
  scrollLines(lines: number): void {
    const s = this.activeSession();
    if (s) { s.term.scrollView(lines); s.term.dirty = true; }
  }
  scrollToTop(): void {
    const s = this.activeSession();
    if (s) { s.term.scrollView(s.term.scrollbackLen); s.term.dirty = true; }
  }
  scrollToBottom(): void {
    const s = this.activeSession();
    if (s) { s.term.scrollToBottom(); s.term.dirty = true; }
  }

  changeFont(delta: number): void {
    this.setFontSize(this.fontSize + delta);
  }

  // ---- selection / clipboard ----------------------------------------------
  private clearSelection(): void {
    this.selActive = false;
    this.mouseDown = false;
  }

  private cellAt(x: number, y: number): number[] {
    const s = this.activeSession();
    if (!s) { return [0, 0]; }
    const col: number = clampInt(Math.floor((x - this.padX) / this.cellW), 0, s.term.cols - 1);
    const row: number = clampInt(Math.floor((y - this.padY) / this.cellH), 0, s.term.rows - 1);
    return [row, col];
  }

  copySelection(): void {
    const s = this.activeSession();
    if (!s || !this.selActive) {
      promptAction.showToast({ message: '先拖动鼠标选择文本', duration: 1500 });
      return;
    }
    let a: number = this.selStartAbs;
    let ca: number = this.selStartCol;
    let b: number = this.selEndAbs;
    let cb: number = this.selEndCol;
    if (a > b || (a === b && ca > cb)) {
      a = this.selEndAbs; ca = this.selEndCol; b = this.selStartAbs; cb = this.selStartCol;
    }
    const txt: string = s.term.selectionText(a, ca, b, cb);
    if (txt.length === 0) { return; }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, txt);
    pasteboard.getSystemPasteboard().setData(data).then((): void => {
      promptAction.showToast({ message: '已复制 ' + txt.length + ' 字符', duration: 1200 });
    }).catch((e: BusinessError): void => {
      promptAction.showToast({ message: '复制失败', duration: 1200 });
    });
  }

  doPaste(): void {
    pasteboard.getSystemPasteboard().getData().then((d: pasteboard.PasteData): void => {
      const txt: string = d.getPrimaryText();
      const s = this.activeSession();
      if (txt === undefined || txt.length === 0 || !s) { return; }
      if (s.term.bracketPaste) {
        s.sendInputStr('\x1b[200~' + txt + '\x1b[201~');
      } else {
        s.sendInputStr(txt);
      }
    }).catch((e: BusinessError): void => {
      promptAction.showToast({ message: '粘贴板为空', duration: 1200 });
    });
  }

  // ---- mouse reporting forward (for vi / less / htop etc.) -----------------
  private mouseButtonCode(b: number): number {
    if (b === MouseButton.Right) { return 2; }
    if (b === MouseButton.Middle) { return 1; }
    return 0;
  }

  private sendMouseButton(code: number, col: number, row: number, release: boolean): void {
    const s = this.activeSession();
    if (!s || !s.term.mouseReport) { return; }
    if (s.term.mouseSgr) {
      s.sendInputStr('\x1b[<' + code + ';' + (col + 1) + ';' + (row + 1) + (release ? 'm' : 'M'));
    } else {
      const cb: number = 32 + code;
      const cx: number = 32 + col + 1;
      const cy: number = 32 + row + 1;
      s.sendInputStr('\x1b[M' + String.fromCharCode(cb > 255 ? 255 : cb) +
        String.fromCharCode(cx > 255 ? 255 : cx) + String.fromCharCode(cy > 255 ? 255 : cy));
    }
  }

  private sendWheel(up: boolean, col: number, row: number): void {
    const s = this.activeSession();
    if (!s || !s.term.mouseReport) { return; }
    const code: number = up ? 64 : 65;
    if (s.term.mouseSgr) {
      s.sendInputStr('\x1b[<' + code + ';' + (col + 1) + ';' + (row + 1) + 'M');
    } else {
      s.sendInputStr('\x1b[M' + String.fromCharCode(32 + code) +
        String.fromCharCode(32 + col + 1) + String.fromCharCode(32 + row + 1));
    }
  }

  // ---- rendering -----------------------------------------------------------
  draw(): void {
    const ctx = this.ctx;
    const T = this.th();
    if (this.vw <= 0 || this.vh <= 0) { return; }
    const s = this.activeSession();
    if (!s) { return; }
    const t = s.term;
    ctx.fillStyle = T.bg;
    ctx.fillRect(0, 0, this.vw, this.vh);
    ctx.textBaseline = 'top';
    ctx.globalAlpha = 1.0;

    for (let r = 0; r < t.rows; r++) {
      const y = this.padY + r * this.cellH;
      if (y > this.vh) { break; }
      const abs: number = t.topAbs() + r;
      const line = t.visibleLine(r);

      // selection band for this line
      let selFrom: number = -1;
      let selTo: number = -1;
      if (this.selActive) {
        for (let c = 0; c < t.cols; c++) {
          if (this.selContains(abs, c)) { if (selFrom < 0) { selFrom = c; } selTo = c; }
        }
      }
      if (selFrom >= 0) {
        ctx.fillStyle = T.sel;
        ctx.fillRect(this.padX + selFrom * this.cellW, y, (selTo - selFrom + 1) * this.cellW, this.cellH);
      } else {
        for (let c = 0; c < t.cols; c++) {
          const cell = line[c];
          if (cell === undefined || cell.cont) { continue; }
          if (cell.bg !== T.bg || cell.inv) {
            const w: number = cell.width > 0 ? cell.width : 1;
            ctx.fillStyle = cell.inv ? cell.fg : cell.bg;
            ctx.fillRect(this.padX + c * this.cellW, y, this.cellW * w + 0.5, this.cellH);
          }
        }
      }

      // glyphs (per cell; wide glyphs span two columns)
      let curFont: string = '';
      let curFg: string = '';
      for (let c = 0; c < t.cols; c++) {
        const cell = line[c];
        if (cell === undefined || cell.cont) { continue; }
        const ch: string = cell.c;
        if (ch.length === 0 || ch === ' ') { continue; }
        const fam: string = this.fontFor(cell.bold);
        const f: string = (cell.italic ? 'italic ' : '') + this.fontSize + 'px ' + fam;
        if (f !== curFont) { ctx.font = f; curFont = f; }
        const fg: string = cell.inv ? cell.bg : cell.fg;
        if (fg !== curFg) { ctx.fillStyle = fg; curFg = fg; }
        ctx.globalAlpha = cell.dim ? 0.65 : 1.0;
        ctx.fillText(ch, this.padX + c * this.cellW, y);
        if (cell.ul || cell.strike) {
          const w: number = (cell.width > 0 ? cell.width : 1) * this.cellW;
          ctx.fillStyle = fg;
          if (cell.ul) { ctx.fillRect(this.padX + c * this.cellW, y + this.cellH - 2, w, 1); }
          if (cell.strike) { ctx.fillRect(this.padX + c * this.cellW, y + this.cellH / 2, w, 1); }
          curFg = '';
        }
      }
      ctx.globalAlpha = 1.0;
    }

    if (t.curVisible && t.viewOffset === 0 && this.blinkOn) {
      let cw: number = 1;
      const line = t.visibleLine(t.cy);
      if (line !== undefined) {
        const cell = line[t.cx];
        if (cell !== undefined && cell.width > 1) { cw = cell.width; }
      }
      const cx: number = this.padX + t.cx * this.cellW;
      const cy: number = this.padY + t.cy * this.cellH;
      ctx.fillStyle = T.cursor;
      if (this.cursorStyle === 'underline') {
        ctx.fillRect(cx, cy + this.cellH - 2, this.cellW * cw, 2);
      } else if (this.cursorStyle === 'bar') {
        ctx.fillRect(cx, cy, 2, this.cellH);
      } else {
        ctx.fillRect(cx, cy, this.cellW * cw, this.cellH);
      }
    }
  }

  private selContains(abs: number, col: number): boolean {
    let a: number = this.selStartAbs;
    let ca: number = this.selStartCol;
    let b: number = this.selEndAbs;
    let cb: number = this.selEndCol;
    if (a > b || (a === b && ca > cb)) {
      a = this.selEndAbs; ca = this.selEndCol; b = this.selStartAbs; cb = this.selStartCol;
    }
    if (abs < a || abs > b) { return false; }
    if (a === b) { return col >= ca && col <= cb; }
    if (abs === a) { return col >= ca; }
    if (abs === b) { return col <= cb; }
    return true;
  }

  // ---- tab strip (left aligned, horizontally scrollable) -------------------
  @Builder
  tabItem(t: TabInfo): void {
    Row() {
      Text(t.title)
        .layoutWeight(1)
        .maxLines(1)
        .textAlign(TextAlign.Start)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize(13)
        .fontColor(t.id === this.activeId ? this.th().tabTextActive : this.th().tabText)
        .onClick((): void => { this.activateTab(t.id); })
      if (t.id === this.activeId) {
        Text('×')
          .fontSize(15)
          .fontColor('#c9ced6')
          .padding({ left: 6, right: 2 })
          .onClick((): void => { this.closeTab(t.id); })
      }
    }
    .width(160)
    .height(30)
    .padding({ left: 12, right: 8 })
    .backgroundColor(t.id === this.activeId ? this.th().tabActive : this.th().tab)
    .borderRadius({ topLeft: 5, topRight: 5 })
    .margin({ left: 1, right: 1, top: 4 })
    .focusable(false)
  }

  // App chrome row.  The window frame itself (title bar, ▣─□✕, rounded
  // corners, shadow) is drawn by the **system** decoration -- see
  // EntryAbility.setupWindowChrome() for why setWindowDecorVisible(false) is
  // a no-op for a main window in window_scene.  This row therefore only
  // carries what the app owns: the tab strip, "设置" and "新建标签", placed
  // directly below the system title bar so it reads as part of the window.
  @Builder
  tabBarRow(): void {
    Row() {
      List({ space: 2 }) {
        ForEach(this.tabs, (t: TabInfo): void => {
          ListItem() {
            this.tabItem(t);
          }
        }, (t: TabInfo): string => t.id.toString() + ':' + t.title)
      }
      .listDirection(Axis.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .height(34)

      Text('设置')
        .height(30)
        .fontSize(13)
        .fontColor('#c9ced6')
        .padding({ left: 8, right: 8 })
        .textAlign(TextAlign.Center)
        .focusable(false)
        .margin({ left: 2 })
        .onClick((): void => { this.showSettings = true; })

      Text('+')
        .width(30)
        .height(30)
        .textAlign(TextAlign.Center)
        .fontSize(18)
        .fontColor('#c9ced6')
        .focusable(false)
        .margin({ left: 2 })
        .onClick((): void => { this.newTab(); })
    }
    .width('100%')
    .height(34)
    .backgroundColor(this.th().bar)
    .border({ width: { bottom: 1 }, color: this.th().border })
  }

  @Builder
  MenuBuilder(): void {
    Menu() {
      MenuItem({ content: '设置' })
        .onClick((): void => { this.showSettings = true; })
      MenuItem({ content: '复制' })
        .onClick((): void => { this.copySelection(); })
      MenuItem({ content: '粘贴' })
        .onClick((): void => { this.doPaste(); })
      MenuItem({ content: '清屏' })
        .onClick((): void => { this.sendInputStr('\x0c'); })
      MenuItem({ content: '新建标签' })
        .onClick((): void => { this.newTab(); })
      MenuItem({ content: '关闭标签' })
        .onClick((): void => { this.closeTab(this.activeId); })
      MenuItem({ content: '最小化' })
        .onClick((): void => { this.minimizeWindow(); })
      MenuItem({ content: this.windowMaximized ? '还原' : '最大化' })
        .onClick((): void => { this.toggleMaximize(); })
      MenuItem({ content: '关闭窗口' })
        .onClick((): void => { this.closeWindow(); })
    }
  }

  // ---- settings panel ------------------------------------------------------
  private applyChoice(kind: string, id: string): void {
    hilog.info(DOMAIN, TAG, 'applyChoice %{public}s=%{public}s', kind, id);
    if (kind === 'font') { this.setFontFamily(id); }
    else if (kind === 'theme') { this.setTheme(id); }
    else if (kind === 'cursor') { this.setCursorStyle(id); }
    else if (kind === 'scrollback') { this.setScrollbackLines(parseInt(id, 10)); }
    else if (kind === 'tab') { this.setTabWidth(parseInt(id, 10)); }
    else if (kind === 'lasttab') { this.setLastTabBehavior(id); }
  }

  setLastTabBehavior(id: string): void {
    if (id === this.lastTabBehavior) { return; }
    this.lastTabBehavior = id;
    this.saveSettings();
  }

  // Keyboard equivalents of the settings (same state as the panel chips),
  // handy on a physical keyboard and for scripted testing.
  toggleTheme(): void {
    const next: string = this.themeId === 'dark' ? 'light' : 'dark';
    this.setTheme(next);
    promptAction.showToast({ message: '主题: ' + themeById(next).label, duration: 1000 });
  }

  cycleCursor(): void {
    const ids: string[] = ['block', 'underline', 'bar'];
    const i: number = ids.indexOf(this.cursorStyle);
    const next: string = ids[(i < 0 ? 0 : i + 1) % ids.length];
    this.setCursorStyle(next);
    promptAction.showToast({ message: '光标: ' + next, duration: 1000 });
  }

  cycleFont(): void {
    const ids: string[] = ['Mono', 'MonoLight', 'MonoCond'];
    const i: number = ids.indexOf(this.fontFamily);
    const next: string = ids[(i < 0 ? 0 : i + 1) % ids.length];
    this.setFontFamily(next);
    promptAction.showToast({ message: '字体: ' + next, duration: 1000 });
  }

  @Builder
  settingsPanel(): void {
    Column() {
      Row() {
        Text('终端设置')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().panelText)
        Blank()
        Text('✕')
          .fontSize(16)
          .fontColor(this.th().panelSub)
          .padding(6)
          .onClick((): void => { this.showSettings = false; })
      }
      .width('100%')

      Divider().color(this.th().border).margin({ top: 4, bottom: 2 })

      Scroll() {
        Column() {
          Text('字体').fontSize(12).fontColor(this.th().panelSub).margin({ top: 10, bottom: 6 }).width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(FONT_OPTS, (o: Opt): void => {
              Text(o.label)
                .fontSize(13)
                .fontColor(this.fontFamily === o.id ? '#ffffff' : this.th().panelText)
                .backgroundColor(this.fontFamily === o.id ? this.th().accent : this.th().bar)
                .borderRadius(6)
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .margin({ right: 8, bottom: 8 })
                .onClick((): void => { this.applyChoice('font', o.id); })
            }, (o: Opt): string => o.id)
          }.width('100%')

          Row() {
            Text('字号').fontSize(13).fontColor(this.th().panelText).width(64)
            Slider({ value: this.fontSize, min: 8, max: 40, step: 1, style: SliderStyle.OutSet })
              .layoutWeight(1)
              .trackColor(this.th().border)
              .selectedColor(this.th().accent)
              .onChange((v: number, m: SliderChangeMode): void => { this.setFontSize(v); })
            Text('' + this.fontSize).fontSize(13).fontColor(this.th().panelText).width(30).textAlign(TextAlign.End)
          }
          .width('100%')
          .margin({ top: 6, bottom: 6 })

          Text('配色主题').fontSize(12).fontColor(this.th().panelSub).margin({ top: 6, bottom: 6 }).width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(THEMES, (tm: Theme): void => {
              Text(tm.label)
                .fontSize(13)
                .fontColor(this.themeId === tm.id ? '#ffffff' : this.th().panelText)
                .backgroundColor(this.themeId === tm.id ? this.th().accent : this.th().bar)
                .borderRadius(6)
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .margin({ right: 8, bottom: 8 })
                .onClick((): void => { this.applyChoice('theme', tm.id); })
            }, (tm: Theme): string => tm.id)
          }.width('100%')

          Text('光标样式').fontSize(12).fontColor(this.th().panelSub).margin({ top: 6, bottom: 6 }).width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(CURSOR_OPTS, (o: Opt): void => {
              Text(o.label)
                .fontSize(13)
                .fontColor(this.cursorStyle === o.id ? '#ffffff' : this.th().panelText)
                .backgroundColor(this.cursorStyle === o.id ? this.th().accent : this.th().bar)
                .borderRadius(6)
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .margin({ right: 8, bottom: 8 })
                .onClick((): void => { this.applyChoice('cursor', o.id); })
            }, (o: Opt): string => o.id)
          }.width('100%')

          Text('回滚行数').fontSize(12).fontColor(this.th().panelSub).margin({ top: 6, bottom: 6 }).width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(SCROLLBACK_OPTS, (o: Opt): void => {
              Text(o.label)
                .fontSize(13)
                .fontColor(('' + this.scrollbackLines) === o.id ? '#ffffff' : this.th().panelText)
                .backgroundColor(('' + this.scrollbackLines) === o.id ? this.th().accent : this.th().bar)
                .borderRadius(6)
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .margin({ right: 8, bottom: 8 })
                .onClick((): void => { this.applyChoice('scrollback', o.id); })
            }, (o: Opt): string => o.id)
          }.width('100%')

          Text('Tab 宽度').fontSize(12).fontColor(this.th().panelSub).margin({ top: 6, bottom: 6 }).width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(TABWIDTH_OPTS, (o: Opt): void => {
              Text(o.label)
                .fontSize(13)
                .fontColor(('' + this.tabWidth) === o.id ? '#ffffff' : this.th().panelText)
                .backgroundColor(('' + this.tabWidth) === o.id ? this.th().accent : this.th().bar)
                .borderRadius(6)
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .margin({ right: 8, bottom: 8 })
                .onClick((): void => { this.applyChoice('tab', o.id); })
            }, (o: Opt): string => o.id)
          }.width('100%')

          Text('退出最后一个标签').fontSize(12).fontColor(this.th().panelSub).margin({ top: 6, bottom: 6 }).width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(LASTTAB_OPTS, (o: Opt): void => {
              Text(o.label)
                .fontSize(13)
                .fontColor(this.lastTabBehavior === o.id ? '#ffffff' : this.th().panelText)
                .backgroundColor(this.lastTabBehavior === o.id ? this.th().accent : this.th().bar)
                .borderRadius(6)
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .margin({ right: 8, bottom: 8 })
                .onClick((): void => { this.applyChoice('lasttab', o.id); })
            }, (o: Opt): string => o.id)
          }.width('100%')
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('92%')
    .height('88%')
    .constraintSize({ maxWidth: 440 })
    .padding({ left: 18, right: 18, top: 10, bottom: 14 })
    .backgroundColor(this.th().panel)
    .borderRadius(14)
    .border({ width: 1, color: this.th().border })
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.35)', offsetX: 0, offsetY: 8 })
  }

  build() {
    Stack() {
      // main terminal surface, inset + rounded so it never paints over the
      // window decoration's rounded corners
      Column() {
        Column() {
          this.tabBarRow()

          Canvas(this.ctx)
            .id('termcanvas')
            .width('100%')
            .layoutWeight(1)
            .backgroundColor(this.th().bg)
            .onReady((): void => {
              this.applyFont();
              const s = this.activeSession();
              if (s) { this.computeSize(s); s.term.dirty = true; }
            })
            .onAreaChange((oldV: Area, newV: Area): void => {
              this.areaW = newV.width as number;
              this.areaH = newV.height as number;
              this.canvasGX = newV.globalPosition.x as number;
              this.canvasGY = newV.globalPosition.y as number;
              const s = this.activeSession();
              if (s) { this.computeSize(s); s.term.dirty = true; }
            })
            .bindContextMenu(this.MenuBuilder, ResponseType.RightClick)
            .onAxisEvent((ev: AxisEvent): void => {
              const s = this.activeSession();
              if (!s) { return; }
              const off: number = ev.getVerticalAxisValue();
              const col: number = clampInt(Math.floor((ev.x - this.canvasGX - this.padX) / this.cellW), 0, s.term.cols - 1);
              const row: number = clampInt(Math.floor((ev.y - this.canvasGY - this.padY) / this.cellH), 0, s.term.rows - 1);
              // OHOS reports a positive vertical axis when scrolling towards the
              // bottom (wheel down); an xterm reports wheel-up (SGR code 64) then.
              if (s.term.mouseReport) {
                if (off !== 0) { this.sendWheel(off < 0, col, row); }
                return;
              }
              this.wheelAcc += off;
              const lines: number = Math.trunc(this.wheelAcc / this.cellH);
              if (lines !== 0) {
                this.wheelAcc -= lines * this.cellH;
                s.term.scrollView(-lines);
                s.term.dirty = true;
              }
            })
            .onMouse((ev: MouseEvent): void => {
              const s = this.activeSession();
              if (!s) { return; }
              const lx: number = ev.displayX - this.canvasGX;
              const ly: number = ev.displayY - this.canvasGY;
              const rc: number[] = this.cellAt(lx, ly);
              const abs: number = s.term.topAbs() + rc[0];
              if (s.term.mouseReport) {
                if (ev.action === MouseAction.Press || ev.action === MouseAction.Release) {
                  this.sendMouseButton(this.mouseButtonCode(ev.button), rc[1], rc[0], ev.action === MouseAction.Release);
                } else if (ev.action === MouseAction.Move && s.term.mouseMode !== 1000) {
                  const pb = ev.pressedButtons;
                  const dragging: boolean = pb !== undefined && pb.includes(MouseButton.Left);
                  this.sendMouseButton(dragging ? 32 : 35, rc[1], rc[0], false);
                }
                return;
              }
              if (ev.action === MouseAction.Press) {
                this.mouseDown = true;
                this.selActive = false;
                this.selStartAbs = abs; this.selStartCol = rc[1];
                this.selEndAbs = abs; this.selEndCol = rc[1];
                s.term.dirty = true;
              } else if (ev.action === MouseAction.Move && this.mouseDown) {
                this.selActive = true;
                this.selEndAbs = abs; this.selEndCol = rc[1];
                s.term.dirty = true;
              } else if (ev.action === MouseAction.Release) {
                this.mouseDown = false;
                s.term.dirty = true;
              }
            })
            .onTouch((event: TouchEvent): void => {
              const s = this.activeSession();
              if (!s) { return; }
              const touches = event.touches;
              if (touches.length === 0) { return; }
              const tp = touches[0];
              const rc: number[] = this.cellAt(tp.x, tp.y);
              const abs: number = s.term.topAbs() + rc[0];
              if (event.type === TouchType.Down) {
                this.selActive = false;
                this.selStartAbs = abs; this.selStartCol = rc[1];
                this.selEndAbs = abs; this.selEndCol = rc[1];
                s.term.dirty = true;
              } else if (event.type === TouchType.Move) {
                this.selActive = true;
                this.selEndAbs = abs; this.selEndCol = rc[1];
                s.term.dirty = true;
              }
            })
            .focusable(true)
            .defaultFocus(true)
            .onKeyPreIme((e: KeyEvent): boolean => this.handleKey(e))
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.th().bg)
        .borderRadius(WIN_RADIUS)
        .clip(true)
      }
      .width('100%')
      .height('100%')
      .padding(OUTER_PAD)

      if (this.showSettings) {
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0,0,0,0.40)')
            .onClick((): void => { this.showSettings = false; })
          this.settingsPanel()
        }
        .width('100%')
        .height('100%')
        // The modal scrim must obey the same corner rule as the terminal
        // surface: a full-bleed opaque scrim would paint over the system
        // decoration's rounded corners.  Inset + clip keeps them intact.
        .margin(OUTER_PAD)
        .borderRadius(WIN_RADIUS)
        .clip(true)
        .alignContent(Alignment.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .focusable(true)
    .onKeyPreIme((e: KeyEvent): boolean => this.handleKey(e))
  }
}
