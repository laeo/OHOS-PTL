// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 OpenHarmony PC Image Contributors

// xterm-compatible VT100/ECMA-48 terminal model for ArkUI (pc_ptl / x86_64).
//
// Implements the escape sequences used by interactive shells and full screen
// TUI programs: colour SGR (16/256/truecolour), cursor motion, erase, insert/
// delete, scroll regions, tab stops, save/restore cursor, alt screen, OSC
// window title, bracketed paste, application cursor keys, DEC origin mode and
// DSR/DA query replies.  Rendering and selection are handled by the page, which
// reads the cell grid through the accessors at the bottom of this file.

import { Theme, THEME_DARK } from './theme';

export const DEFAULT_FG: string = '#dcdfe4';
export const DEFAULT_BG: string = '#1e1e1e';
const DEFAULT_SCROLLBACK: number = 5000;

function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : (v > hi ? hi : v);
}

// East-Asian wide / fullwidth / emoji take two terminal cells so that CJK
// stays column-aligned with monospace Latin text.
export function codePointWidth(cp: number): number {
  if (cp >= 0x1100 && cp <= 0x115f) { return 2; }
  if (cp >= 0x2e80 && cp <= 0x303e) { return 2; }
  if (cp >= 0x3041 && cp <= 0x33ff) { return 2; }
  if (cp >= 0x3400 && cp <= 0x4dbf) { return 2; }
  if (cp >= 0x4e00 && cp <= 0x9fff) { return 2; }
  if (cp >= 0xa000 && cp <= 0xa4cf) { return 2; }
  if (cp >= 0xac00 && cp <= 0xd7a3) { return 2; }
  if (cp >= 0xf900 && cp <= 0xfaff) { return 2; }
  if (cp >= 0xfe10 && cp <= 0xfe19) { return 2; }
  if (cp >= 0xfe30 && cp <= 0xfe6f) { return 2; }
  if (cp >= 0xff00 && cp <= 0xff60) { return 2; }
  if (cp >= 0xffe0 && cp <= 0xffe6) { return 2; }
  if (cp >= 0x1f300 && cp <= 0x1faff) { return 2; }
  if (cp >= 0x20000 && cp <= 0x3fffd) { return 2; }
  return 1;
}
function rgb(r: number, g: number, b: number): string {
  return 'rgb(' + r + ',' + g + ',' + b + ')';
}

const PALETTE: string[] = buildPalette();
function buildPalette(): string[] {
  const p: string[] = [
    '#000000', '#cd0000', '#00cd00', '#cdcd00', '#0000ee', '#cd00cd', '#00cdcd', '#e5e5e5',
    '#7f7f7f', '#ff0000', '#00ff00', '#ffff00', '#5c5cff', '#ff00ff', '#00ffff', '#ffffff'
  ];
  const lv: number[] = [0, 95, 135, 175, 215, 255];
  for (let r = 0; r < 6; r++) {
    for (let g = 0; g < 6; g++) {
      for (let b = 0; b < 6; b++) {
        p.push(rgb(lv[r], lv[g], lv[b]));
      }
    }
  }
  for (let i = 0; i < 24; i++) {
    const v = 8 + i * 10;
    p.push(rgb(v, v, v));
  }
  return p;
}

export function paletteColor(i: number): string {
  return PALETTE[clamp(i, 0, 255)];
}

export class Cell {
  c: string = ' ';
  fg: string = DEFAULT_FG;
  bg: string = DEFAULT_BG;
  bold: boolean = false;
  dim: boolean = false;
  italic: boolean = false;
  ul: boolean = false;
  strike: boolean = false;
  inv: boolean = false;
  width: number = 1;   // 1 = narrow, 2 = wide (CJK)
  cont: boolean = false; // true = trailing half of a wide glyph (renders nothing)
}

export class Terminal {
  cols: number = 80;
  rows: number = 24;
  screen: Cell[][] = [];
  alt: Cell[][] | undefined = undefined;
  altActive: boolean = false;
  scrollback: Cell[][] = [];
  viewOffset: number = 0; // 0 = bottom (live), >0 = scrolled up
  cx: number = 0;
  cy: number = 0;
  savedX: number = 0;
  savedY: number = 0;
  savedState: SavedCursor | undefined = undefined;
  top: number = 0;
  bottom: number = 23;
  curVisible: boolean = true;
  appCursor: boolean = false;
  bracketPaste: boolean = false;
  originMode: boolean = false;
  insertMode: boolean = false;
  autoWrap: boolean = true;
  mouseReport: boolean = false;   // DECSET ?1000 / ?1002 / ?1003 (button / drag / any-motion)
  mouseMode: number = 0;          // 0 = off, else 1000 / 1002 / 1003
  mouseSgr: boolean = false;      // DECSET ?1006 / ?1015 (SGR extended coordinates)
  focusReport: boolean = false;   // DECSET ?1004
  wrapPending: boolean = false;
  curFg: string = DEFAULT_FG;
  curBg: string = DEFAULT_BG;
  curBold: boolean = false;
  curDim: boolean = false;
  curItalic: boolean = false;
  curUl: boolean = false;
  curStrike: boolean = false;
  curInv: boolean = false;
  dirty: boolean = true;
  title: string = 'Terminal';
  // settings-driven state
  theme: Theme = THEME_DARK;
  scrollbackMax: number = DEFAULT_SCROLLBACK;
  tabWidth: number = 8;
  cursorStyle: string = 'block';
  lastChar: string = ' ';
  lastCharWidth: number = 1;
  tabStops: boolean[] = [];
  respond: ((s: string) => void) | undefined = undefined;
  onTitle: (() => void) | undefined = undefined;

  // parser state
  private st: number = 0; // 0 ground, 1 esc, 2 csi, 3 osc, 4 osc-esc, 5 dcs, 6 eol-after-esc
  private priv: string = '';
  private paramStr: string = '';
  private oscBuf: string = '';

  constructor(cols: number, rows: number) {
    this.cols = cols;
    this.rows = rows;
    this.reset();
  }

  newCell(): Cell {
    const cl = new Cell();
    cl.fg = this.curFg;
    cl.bg = this.curBg;
    cl.bold = this.curBold;
    cl.dim = this.curDim;
    cl.italic = this.curItalic;
    cl.ul = this.curUl;
    cl.strike = this.curStrike;
    cl.inv = this.curInv;
    return cl;
  }

  newRow(): Cell[] {
    const row: Cell[] = [];
    for (let i = 0; i < this.cols; i++) {
      const cl = new Cell();
      cl.fg = this.theme.fg;
      cl.bg = this.theme.bg;
      row.push(cl);
    }
    return row;
  }

  reset(): void {
    const r: Cell[][] = [];
    for (let i = 0; i < this.rows; i++) { r.push(this.newRow()); }
    this.screen = r;
    this.altActive = false;
    this.alt = undefined;
    this.scrollback = [];
    this.viewOffset = 0;
    this.cx = 0; this.cy = 0; this.savedX = 0; this.savedY = 0;
    this.savedState = undefined;
    this.top = 0; this.bottom = this.rows - 1;
    this.curVisible = true; this.appCursor = false; this.bracketPaste = false;
    this.mouseReport = false; this.mouseMode = 0; this.mouseSgr = false;
    this.focusReport = false;
    this.originMode = false; this.insertMode = false; this.autoWrap = true;
    this.curFg = this.theme.fg; this.curBg = this.theme.bg;
    this.curBold = false; this.curDim = false; this.curItalic = false;
    this.curUl = false; this.curStrike = false; this.curInv = false;
    this.wrapPending = false;
    this.tabStops = [];
    for (let i = 0; i < this.cols; i++) { this.tabStops.push((i % this.tabWidth) === 0); }
    this.dirty = true;
  }

  resize(cols: number, rows: number, viewHeight: number): void {
    if (cols === this.cols && rows === this.rows) { return; }
    const oldRows = this.rows;
    const old = this.screen;
    // When the viewport shrinks, push the top lines into scrollback so that
    // content is not silently lost (matches xterm behaviour).
    if (rows < oldRows && !this.altActive) {
      const drop = oldRows - rows;
      for (let i = 0; i < drop; i++) {
        const removed = old.shift();
        if (removed !== undefined) {
          this.scrollback.push(removed);
        }
      }
      if (this.scrollback.length > this.scrollbackMax) {
        this.scrollback.splice(0, this.scrollback.length - this.scrollbackMax);
      }
      this.cy = clamp(this.cy - drop, 0, rows - 1);
    }
    this.cols = cols; this.rows = rows;
    const nl: Cell[][] = [];
    for (let i = 0; i < rows; i++) {
      const row = (i < old.length) ? old[i] : this.newRow();
      while (row.length < cols) {
        const cl = new Cell();
        row.push(cl);
      }
      while (row.length > cols) { row.pop(); }
      nl.push(row);
    }
    this.screen = nl;
    if (this.alt !== undefined) {
      const al: Cell[][] = [];
      for (let i = 0; i < rows; i++) {
        const row = (i < this.alt.length) ? this.alt[i] : this.newRow();
        while (row.length < cols) { row.push(new Cell()); }
        while (row.length > cols) { row.pop(); }
        al.push(row);
      }
      this.alt = al;
    }
    this.top = 0; this.bottom = rows - 1;
    this.cx = clamp(this.cx, 0, cols - 1);
    this.cy = clamp(this.cy, 0, rows - 1);
    this.tabStops = [];
    for (let i = 0; i < cols; i++) { this.tabStops.push((i % this.tabWidth) === 0); }
    if (this.viewOffset > this.scrollback.length) { this.viewOffset = this.scrollback.length; }
    this.dirty = true;
  }

  scrollUp(): void {
    const removed = this.screen.splice(this.top, 1)[0];
    if (!this.altActive && this.top === 0 && removed !== undefined) {
      this.scrollback.push(removed);
      if (this.scrollback.length > this.scrollbackMax) {
        this.scrollback.splice(0, this.scrollback.length - this.scrollbackMax);
      }
      if (this.viewOffset > 0) { this.viewOffset++; }
      if (this.viewOffset > this.scrollback.length) { this.viewOffset = this.scrollback.length; }
    }
    this.screen.splice(this.bottom, 0, this.newRow());
  }

  scrollDown(): void {
    this.screen.splice(this.bottom, 1);
    this.screen.splice(this.top, 0, this.newRow());
  }

  private putChar(ch: string, w: number): void {
    if (w < 1) { w = 1; }
    if (w > 2) { w = 2; }
    if (this.wrapPending && this.autoWrap) {
      this.wrapPending = false;
      this.cx = 0;
      if (this.cy === this.bottom) { this.scrollUp(); } else { this.cy++; }
    }
    // A wide glyph needs two free cells; wrap early if it would straddle the
    // right margin (matches xterm's behaviour for CJK).
    if (this.cx + w > this.cols) {
      if (this.autoWrap && this.cx > 0) {
        this.cx = 0;
        if (this.cy === this.bottom) { this.scrollUp(); } else { this.cy++; }
      } else {
        this.cx = this.cols - w;
        if (this.cx < 0) { this.cx = 0; }
      }
    }
    const row = this.screen[this.cy];
    if (row === undefined) { return; }
    if (this.insertMode) {
      for (let k = 0; k < w; k++) { row.splice(this.cx, 0, this.newCell()); row.pop(); }
    }
    const cl = row[this.cx];
    if (cl !== undefined) {
      cl.c = ch; cl.width = w; cl.cont = false;
      cl.fg = this.curFg; cl.bg = this.curBg;
      cl.bold = this.curBold; cl.dim = this.curDim; cl.italic = this.curItalic;
      cl.ul = this.curUl; cl.strike = this.curStrike; cl.inv = this.curInv;
    }
    for (let k = 1; k < w; k++) {
      const c2 = row[this.cx + k];
      if (c2 !== undefined) {
        c2.c = ''; c2.width = 0; c2.cont = true;
        c2.fg = this.curFg; c2.bg = this.curBg;
        c2.bold = this.curBold; c2.dim = this.curDim; c2.italic = this.curItalic;
        c2.ul = this.curUl; c2.strike = this.curStrike; c2.inv = this.curInv;
      }
    }
    this.lastChar = ch;
    this.lastCharWidth = w;
    this.cx += w;
    if (this.cx >= this.cols) { this.cx = this.cols - 1; this.wrapPending = true; }
    this.dirty = true;
  }

  private repeatLast(n: number): void {
    for (let i = 0; i < n; i++) { this.putChar(this.lastChar, this.lastCharWidth); }
  }

  // ---- SGR --------------------------------------------------------------
  private sgr(p: number[]): void {
    if (p.length === 0) { p = [0]; }
    let i = 0;
    while (i < p.length) {
      const n = p[i];
      if (n === 0) {
        this.curFg = this.theme.fg; this.curBg = this.theme.bg;
        this.curBold = false; this.curDim = false; this.curItalic = false;
        this.curUl = false; this.curStrike = false; this.curInv = false;
      } else if (n === 1) { this.curBold = true; }
      else if (n === 2) { this.curDim = true; }
      else if (n === 3) { this.curItalic = true; }
      else if (n === 4) { this.curUl = true; }
      else if (n === 7) { this.curInv = true; }
      else if (n === 9) { this.curStrike = true; }
      else if (n === 21 || n === 22) { this.curBold = false; this.curDim = false; }
      else if (n === 23) { this.curItalic = false; }
      else if (n === 24) { this.curUl = false; }
      else if (n === 27) { this.curInv = false; }
      else if (n === 29) { this.curStrike = false; }
      else if (n >= 30 && n <= 37) { this.curFg = this.colorAt(n - 30); }
      else if (n === 38) {
        if (p[i + 1] === 5 && i + 2 < p.length) { this.curFg = this.colorAt(clamp(p[i + 2], 0, 255)); i += 2; }
        else if (p[i + 1] === 2 && i + 4 < p.length) { this.curFg = rgb(p[i + 2] & 255, p[i + 3] & 255, p[i + 4] & 255); i += 4; }
      }
      else if (n === 39) { this.curFg = this.theme.fg; }
      else if (n >= 40 && n <= 47) { this.curBg = this.colorAt(n - 40); }
      else if (n === 48) {
        if (p[i + 1] === 5 && i + 2 < p.length) { this.curBg = this.colorAt(clamp(p[i + 2], 0, 255)); i += 2; }
        else if (p[i + 1] === 2 && i + 4 < p.length) { this.curBg = rgb(p[i + 2] & 255, p[i + 3] & 255, p[i + 4] & 255); i += 4; }
      }
      else if (n === 49) { this.curBg = this.theme.bg; }
      else if (n >= 90 && n <= 97) { this.curFg = this.colorAt(n - 90 + 8); }
      else if (n >= 100 && n <= 107) { this.curBg = this.colorAt(n - 100 + 8); }
      i++;
    }
  }

  // ---- settings-driven behaviour ---------------------------------------
  // Resolve a palette index: 0..15 come from the active theme, 16..255 from the
  // fixed xterm 256-colour cube (theme-independent).
  colorAt(i: number): string {
    if (i >= 0 && i < 16) { return this.theme.palette[i]; }
    return PALETTE[clamp(i, 0, 255)];
  }

  // Recolour every already-rendered cell when the theme changes so the whole
  // screen updates at once (not only newly written output).
  applyTheme(t: Theme): void {
    if (t.id === this.theme.id) { return; }
    const old: Theme = this.theme;
    const map: Map<string, string> = new Map<string, string>();
    for (let i = 0; i < 16; i++) { map.set(old.palette[i], t.palette[i]); }
    map.set(old.fg, t.fg);
    map.set(old.bg, t.bg);
    this.theme = t;
    this.remapGrid(this.screen, map);
    if (this.alt !== undefined) { this.remapGrid(this.alt, map); }
    this.remapGrid(this.scrollback, map);
    const nf = map.get(this.curFg);
    if (nf !== undefined) { this.curFg = nf; }
    const nb = map.get(this.curBg);
    if (nb !== undefined) { this.curBg = nb; }
    this.dirty = true;
  }

  private remapGrid(grid: Cell[][], map: Map<string, string>): void {
    for (let r = 0; r < grid.length; r++) {
      const row: Cell[] = grid[r];
      for (let c = 0; c < row.length; c++) {
        const cell: Cell = row[c];
        const nf: string | undefined = map.get(cell.fg);
        if (nf !== undefined && nf !== cell.fg) { cell.fg = nf; }
        const nb: string | undefined = map.get(cell.bg);
        if (nb !== undefined && nb !== cell.bg) { cell.bg = nb; }
      }
    }
  }

  setScrollback(n: number): void {
    this.scrollbackMax = n > 0 ? n : DEFAULT_SCROLLBACK;
    if (this.scrollback.length > this.scrollbackMax) {
      this.scrollback.splice(0, this.scrollback.length - this.scrollbackMax);
    }
    if (this.viewOffset > this.scrollback.length) { this.viewOffset = this.scrollback.length; }
    this.dirty = true;
  }

  setTabWidth(n: number): void {
    this.tabWidth = n >= 1 ? n : 8;
    this.tabStops = [];
    for (let i = 0; i < this.cols; i++) { this.tabStops.push((i % this.tabWidth) === 0); }
    this.dirty = true;
  }

  setCursorStyle(s: string): void {
    this.cursorStyle = s;
    this.dirty = true;
  }

  // ---- CSI dispatch -----------------------------------------------------
  private csiFinal(finalCh: string): void {
    const p: number[] = this.parseParams();
    const p0: number = p.length > 0 ? p[0] : 0;
    const p1: number = p.length > 1 ? p[1] : 0;
    const isPriv: boolean = this.priv === '?';
    switch (finalCh) {
      case 'A': this.cy = clamp(this.cy - Math.max(1, p0), this.top, this.bottom); this.wrapPending = false; break;
      case 'B': this.cy = clamp(this.cy + Math.max(1, p0), this.top, this.bottom); this.wrapPending = false; break;
      case 'C': this.cx = clamp(this.cx + Math.max(1, p0), 0, this.cols - 1); this.wrapPending = false; break;
      case 'D': this.cx = clamp(this.cx - Math.max(1, p0), 0, this.cols - 1); this.wrapPending = false; break;
      case 'E': this.cy = clamp(this.cy + Math.max(1, p0), this.top, this.bottom); this.cx = 0; this.wrapPending = false; break;
      case 'F': this.cy = clamp(this.cy - Math.max(1, p0), this.top, this.bottom); this.cx = 0; this.wrapPending = false; break;
      case 'G': case '`': this.cx = clamp(Math.max(1, p0) - 1, 0, this.cols - 1); this.wrapPending = false; break;
      case 'd': this.cy = clamp(Math.max(1, p0) - 1, this.top, this.bottom); this.wrapPending = false; break;
      case 'e': this.cy = clamp(this.cy + Math.max(1, p0), this.top, this.bottom); break;
      case 'a': this.cx = clamp(this.cx + Math.max(1, p0), 0, this.cols - 1); break;
      case 'H': case 'f': {
        const r = (p.length > 0) ? Math.max(1, p0) - 1 : 0;
        const c = (p.length > 1) ? Math.max(1, p1) - 1 : 0;
        if (this.originMode) {
          this.cy = clamp(this.top + r, this.top, this.bottom);
        } else {
          this.cy = clamp(r, 0, this.rows - 1);
        }
        this.cx = clamp(c, 0, this.cols - 1);
        this.wrapPending = false;
        break;
      }
      case 'I': for (let i = 0; i < Math.max(1, p0); i++) { this.tabForward(); } break;
      case 'Z': for (let i = 0; i < Math.max(1, p0); i++) { this.tabBackward(); } break;
      case 'J': this.eraseDisplay(p0); break;
      case 'K': this.eraseLine(p0); break;
      case 'L': this.insertLines(Math.max(1, p0)); break;
      case 'M': this.deleteLines(Math.max(1, p0)); break;
      case 'P': this.deleteChars(Math.max(1, p0)); break;
      case '@': this.insertChars(Math.max(1, p0)); break;
      case 'X': this.eraseChars(Math.max(1, p0)); break;
      case 'b': this.repeatLast(Math.min(Math.max(1, p0), this.cols)); break;
      case 'm': this.sgr(p); break;
      case 'g': this.clearTabStops(p0); break;
      case 'r': {
        const t = (p.length > 0) ? Math.max(1, p0) - 1 : 0;
        const b = (p.length > 1) ? Math.max(1, p1) - 1 : this.rows - 1;
        this.top = clamp(t, 0, this.rows - 1);
        this.bottom = clamp(b, this.top, this.rows - 1);
        this.cx = 0; this.cy = this.top; this.wrapPending = false;
        break;
      }
      case 's': this.saveCursor(); break;
      case 'u': this.restoreCursor(); break;
      case 'S': for (let i = 0; i < Math.max(1, p0); i++) { this.scrollUp(); } break;
      case 'T': for (let i = 0; i < Math.max(1, p0); i++) { this.scrollDown(); } break;
      case 'h': this.setMode(p, true, isPriv); break;
      case 'l': this.setMode(p, false, isPriv); break;
      case 'n': this.deviceStatus(p0, isPriv); break;
      case 'c': if (this.respond !== undefined) { this.respond('\x1b[?1;2c'); } break;
      case 't': break; // window manipulation - ignore
      default: break;
    }
    this.dirty = true;
  }

  private deviceStatus(p0: number, priv: boolean): void {
    if (this.respond === undefined) { return; }
    if (priv) {
      if (p0 === 6) {
        this.respond('\x1b[?' + (this.cy + 1) + ';' + (this.cx + 1) + 'R');
      }
    } else if (p0 === 6) {
      this.respond('\x1b[' + (this.cy + 1) + ';' + (this.cx + 1) + 'R');
    } else if (p0 === 5) {
      this.respond('\x1b[0n');
    }
  }

  private setMode(p: number[], on: boolean, priv: boolean): void {
    for (let i = 0; i < p.length; i++) {
      const n = p[i];
      if (priv) {
        if (n === 25) { this.curVisible = on; }
        else if (n === 1) { this.appCursor = on; }
        else if (n === 6) { this.originMode = on; this.cx = 0; this.cy = on ? this.top : 0; }
        else if (n === 7) { this.autoWrap = on; }
        else if (n === 12) { /* cursor blink */ }
        else if (n === 2004) { this.bracketPaste = on; }
        else if (n === 1049 || n === 1047 || n === 47) { this.altScreen(on, n !== 47); }
        else if (n === 1048) { if (on) { this.saveCursor(); } else { this.restoreCursor(); } }
        else if (n === 1000 || n === 1002 || n === 1003) {
          this.mouseReport = on;
          this.mouseMode = on ? n : 0;
        }
        else if (n === 1006 || n === 1015) { this.mouseSgr = on; }
        else if (n === 1004) { this.focusReport = on; }
      } else {
        if (n === 4) { this.insertMode = on; }
        else if (n === 20) { /* LNM */ }
      }
    }
  }

  private altScreen(on: boolean, save: boolean): void {
    if (on && !this.altActive) {
      if (save) { this.saveCursor(); }
      this.alt = this.screen;
      const r: Cell[][] = [];
      for (let i = 0; i < this.rows; i++) { r.push(this.newRow()); }
      this.screen = r;
      this.altActive = true;
      this.cx = 0; this.cy = 0; this.wrapPending = false;
      this.top = 0; this.bottom = this.rows - 1;
    } else if (!on && this.altActive) {
      if (this.alt !== undefined) { this.screen = this.alt; }
      this.alt = undefined;
      this.altActive = false;
      this.top = 0; this.bottom = this.rows - 1;
      if (save) { this.restoreCursor(); }
    }
  }

  private saveCursor(): void {
    this.savedState = new SavedCursor(this.cx, this.cy, this.curFg, this.curBg,
      this.curBold, this.curDim, this.curItalic, this.curUl, this.curStrike, this.curInv);
  }

  private restoreCursor(): void {
    const s = this.savedState;
    if (s === undefined) { this.cx = this.savedX; this.cy = this.savedY; return; }
    this.cx = s.cx; this.cy = s.cy;
    this.curFg = s.fg; this.curBg = s.bg;
    this.curBold = s.bold; this.curDim = s.dim; this.curItalic = s.italic;
    this.curUl = s.ul; this.curStrike = s.strike; this.curInv = s.inv;
  }

  private tabForward(): void {
    if (this.cx >= this.cols - 1) { return; }
    let x = this.cx + 1;
    while (x < this.cols - 1 && !this.tabStops[x]) { x++; }
    this.cx = x;
    this.wrapPending = false;
  }

  private tabBackward(): void {
    let x = this.cx - 1;
    while (x > 0 && !this.tabStops[x]) { x--; }
    this.cx = clamp(x, 0, this.cols - 1);
    this.wrapPending = false;
  }

  private clearTabStops(mode: number): void {
    if (mode === 0) { this.tabStops[this.cx] = false; }
    else if (mode === 3) { for (let i = 0; i < this.cols; i++) { this.tabStops[i] = false; } }
  }

  private eraseDisplay(mode: number): void {
    if (mode === 2 || mode === 3) {
      for (let r = 0; r < this.rows; r++) { this.screen[r] = this.newRow(); }
      if (mode === 3) { this.scrollback = []; this.viewOffset = 0; }
    } else if (mode === 1) {
      for (let r = 0; r < this.cy; r++) { this.screen[r] = this.newRow(); }
      const row = this.screen[this.cy];
      for (let c = 0; c <= this.cx && c < this.cols; c++) { row[c] = this.newCell(); }
    } else {
      const row = this.screen[this.cy];
      for (let c = this.cx; c < this.cols; c++) { row[c] = this.newCell(); }
      for (let r = this.cy + 1; r < this.rows; r++) { this.screen[r] = this.newRow(); }
    }
  }

  private eraseLine(mode: number): void {
    const row = this.screen[this.cy];
    if (mode === 2) { this.screen[this.cy] = this.newRow(); }
    else if (mode === 1) { for (let c = 0; c <= this.cx && c < this.cols; c++) { row[c] = this.newCell(); } }
    else { for (let c = this.cx; c < this.cols; c++) { row[c] = this.newCell(); } }
  }

  private insertLines(n: number): void {
    if (this.cy < this.top || this.cy > this.bottom) { return; }
    for (let i = 0; i < n; i++) {
      this.screen.splice(this.cy, 0, this.newRow());
      this.screen.splice(this.bottom + 1, 1);
    }
  }

  private deleteLines(n: number): void {
    if (this.cy < this.top || this.cy > this.bottom) { return; }
    for (let i = 0; i < n; i++) {
      if (this.cy < this.screen.length) { this.screen.splice(this.cy, 1); }
      this.screen.splice(this.bottom, 0, this.newRow());
    }
  }

  private deleteChars(n: number): void {
    const row = this.screen[this.cy];
    for (let i = 0; i < n; i++) { row.splice(this.cx, 1); row.push(this.newCell()); }
  }

  private insertChars(n: number): void {
    const row = this.screen[this.cy];
    for (let i = 0; i < n; i++) { row.splice(this.cx, 0, this.newCell()); row.pop(); }
  }

  private eraseChars(n: number): void {
    const row = this.screen[this.cy];
    for (let i = 0; i < n && this.cx + i < this.cols; i++) { row[this.cx + i] = this.newCell(); }
  }

  private parseParams(): number[] {
    const out: number[] = [];
    const s = this.paramStr.replace(/:/g, ';');
    if (s.length === 0) { return out; }
    const parts = s.split(';');
    for (let i = 0; i < parts.length; i++) {
      const t = parts[i];
      if (t.length === 0) { out.push(0); }
      else { const v = parseInt(t, 10); out.push(isNaN(v) ? 0 : v); }
    }
    return out;
  }

  // ---- main parser ------------------------------------------------------
  write(data: string): void {
    for (let i = 0; i < data.length; i++) {
      const code = data.charCodeAt(i);
      const ch = data.charAt(i);
      if (this.st === 0) {
        if (code === 0x1b) { this.st = 1; continue; }
        if (code === 0x07) { /* bell */ continue; }
        if (code === 0x08) { if (this.cx > 0) { this.cx--; } this.wrapPending = false; continue; }
        if (code === 0x09) { this.tabForward(); continue; }
        if (code === 0x0a || code === 0x0b || code === 0x0c) { this.lineFeed(); continue; }
        if (code === 0x0d) { this.cx = 0; this.wrapPending = false; continue; }
        if (code === 0x0e || code === 0x0f) { continue; }
        if (code < 0x20 || code === 0x7f) { continue; }
        // Combine a UTF-16 surrogate pair (emoji, rare CJK ext) into one code
        // point so wide-character handling sees the real glyph.
        let cp: number = code;
        let glyph: string = ch;
        if (code >= 0xd800 && code <= 0xdbff && i + 1 < data.length) {
          const lo: number = data.charCodeAt(i + 1);
          if (lo >= 0xdc00 && lo <= 0xdfff) {
            cp = 0x10000 + ((code - 0xd800) << 10) + (lo - 0xdc00);
            glyph = String.fromCharCode(code, lo);
            i++;
          }
        }
        this.putChar(glyph, codePointWidth(cp));
        continue;
      }
      if (this.st === 1) {
        if (code === 0x5b) { this.st = 2; this.priv = ''; this.paramStr = ''; }
        else if (code === 0x5d) { this.st = 3; this.oscBuf = ''; }
        else if (code === 0x50 || code === 0x58 || code === 0x5e || code === 0x5f) { this.st = 5; }
        else if (code === 0x28 || code === 0x29 || code === 0x2a || code === 0x2b) { this.st = 6; }
        else if (code === 0x23) { this.st = 6; }
        else if (code === 0x20) { this.st = 6; }
        else if (code === 0x37) { this.saveCursor(); this.st = 0; }
        else if (code === 0x38) { this.restoreCursor(); this.st = 0; }
        else if (code === 0x44) { this.lineFeed(); this.st = 0; }
        else if (code === 0x45) { this.cx = 0; this.lineFeed(); this.st = 0; }
        else if (code === 0x4d) { // RI
          this.wrapPending = false;
          if (this.cy === this.top) { this.scrollDown(); } else { this.cy = clamp(this.cy - 1, this.top, this.bottom); }
          this.st = 0;
        }
        else if (code === 0x48) { this.tabStops[this.cx] = true; this.st = 0; }
        else if (code === 0x63) { this.reset(); this.st = 0; }
        else if (code === 0x3d || code === 0x3e) { this.st = 0; }
        else { this.st = 0; }
        continue;
      }
      if (this.st === 2) {
        if (code >= 0x30 && code <= 0x39) { this.paramStr += ch; }
        else if (code === 0x3b || code === 0x3a) { this.paramStr += ch; }
        else if ((code === 0x3f || code === 0x3c || code === 0x3d || code === 0x3e) && this.paramStr.length === 0 && this.priv.length === 0) { this.priv = ch; }
        else if (code >= 0x20 && code <= 0x2f) { /* intermediate */ }
        else if (code >= 0x40 && code <= 0x7e) { this.csiFinal(ch); this.st = 0; }
        else { this.st = 0; }
        continue;
      }
      if (this.st === 3) {
        if (code === 0x07) { this.finishOsc(); this.st = 0; }
        else if (code === 0x1b) { this.st = 4; }
        else { this.oscBuf += ch; }
        continue;
      }
      if (this.st === 4) {
        if (code === 0x5c) { this.finishOsc(); this.st = 0; }
        else { this.oscBuf += ch; this.st = 3; }
        continue;
      }
      if (this.st === 5) { // DCS/PM/APC - consume until ST
        if (code === 0x1b) { this.st = 6; }
        continue;
      }
      if (this.st === 6) { // single char after ESC intermediates, or end of DCS
        if (code === 0x5c) { this.st = 0; }
        else { this.st = 0; }
        continue;
      }
    }
    this.dirty = true;
  }

  private finishOsc(): void {
    // OSC 0 ; title   OSC 2 ; title  OSC 1 ; icon
    let i = 0;
    while (i < this.oscBuf.length && this.oscBuf.charAt(i) !== ';') { i++; }
    if (i >= this.oscBuf.length) { return; }
    const num = parseInt(this.oscBuf.substring(0, i), 10);
    const rest = this.oscBuf.substring(i + 1);
    if (num === 0 || num === 2) {
      if (rest.length > 0) {
        this.title = rest;
        if (this.onTitle !== undefined) { this.onTitle(); }
      }
    }
  }

  private lineFeed(): void {
    this.wrapPending = false;
    if (this.cy === this.bottom) { this.scrollUp(); } else { this.cy = clamp(this.cy + 1, 0, this.rows - 1); }
  }

  // ---- accessors used by the renderer -----------------------------------
  // Absolute line index ranges over scrollback (0..sb-1) then screen (sb..sb+rows-1).
  get scrollbackLen(): number {
    return this.scrollback.length;
  }

  // Absolute index of the top visible line for the current view offset.
  topAbs(): number {
    return this.scrollback.length - this.viewOffset;
  }

  lineAt(abs: number): Cell[] | undefined {
    if (abs < 0) { return undefined; }
    if (abs < this.scrollback.length) { return this.scrollback[abs]; }
    const i = abs - this.scrollback.length;
    if (i < this.screen.length) { return this.screen[i]; }
    return undefined;
  }

  // Backwards compatible helper: visible row -> cells.
  visibleLine(r: number): Cell[] {
    const abs = this.topAbs() + r;
    const l = this.lineAt(abs);
    if (l !== undefined) { return l; }
    return this.screen[clamp(r, 0, this.screen.length - 1)];
  }

  scrollView(delta: number): void {
    const want = this.viewOffset + delta;
    this.viewOffset = clamp(want, 0, this.scrollback.length);
    this.dirty = true;
  }

  scrollToBottom(): void {
    if (this.viewOffset !== 0) { this.viewOffset = 0; this.dirty = true; }
  }

  rowText(abs: number, trim: boolean): string {
    const line = this.lineAt(abs);
    if (line === undefined) { return ''; }
    let s = '';
    for (let c = 0; c < this.cols; c++) { s += line[c].c; }
    if (trim) { s = s.replace(/\s+$/, ''); }
    return s;
  }

  selectionText(abs1: number, col1: number, abs2: number, col2: number): string {
    let a = abs1, b = abs2, ca = col1, cb = col2;
    if (a > b || (a === b && ca > cb)) { a = abs2; b = abs1; ca = col2; cb = col1; }
    let out = '';
    for (let r = a; r <= b; r++) {
      const line = this.lineAt(r);
      if (line === undefined) { continue; }
      const start = (r === a) ? ca : 0;
      const end = (r === b) ? cb : this.cols - 1;
      let s = '';
      for (let c = start; c <= end && c < this.cols; c++) { s += line[c].c; }
      out += (r === b) ? s : s.replace(/\s+$/, '') + '\n';
    }
    return out;
  }
}

export class SavedCursor {
  cx: number;
  cy: number;
  fg: string;
  bg: string;
  bold: boolean;
  dim: boolean;
  italic: boolean;
  ul: boolean;
  strike: boolean;
  inv: boolean;
  constructor(cx: number, cy: number, fg: string, bg: string, bold: boolean,
    dim: boolean, italic: boolean, ul: boolean, strike: boolean, inv: boolean) {
    this.cx = cx; this.cy = cy; this.fg = fg; this.bg = bg;
    this.bold = bold; this.dim = dim; this.italic = italic;
    this.ul = ul; this.strike = strike; this.inv = inv;
  }
}

// Selection describes a range over absolute line indices (see Terminal.lineAt).
export class Selection {
  active: boolean = false;
  startAbs: number = 0;
  startCol: number = 0;
  endAbs: number = 0;
  endCol: number = 0;

  begin(abs: number, col: number): void {
    this.active = true;
    this.startAbs = abs; this.startCol = col;
    this.endAbs = abs; this.endCol = col;
  }
  extend(abs: number, col: number): void {
    this.endAbs = abs; this.endCol = col;
  }
  clear(): void { this.active = false; }
  normalized(): number[] {
    let a = this.startAbs, b = this.endAbs, ca = this.startCol, cb = this.endCol;
    if (a > b || (a === b && ca > cb)) { a = this.endAbs; b = this.startAbs; ca = this.endCol; cb = this.startCol; }
    return [a, ca, b, cb];
  }
  contains(abs: number, col: number): boolean {
    const n = this.normalized();
    const a = n[0], ca = n[1], b = n[2], cb = n[3];
    if (abs < a || abs > b) { return false; }
    if (a === b) { return col >= ca && col <= cb; }
    if (abs === a) { return col >= ca; }
    if (abs === b) { return col <= cb; }
    return true;
  }
}
