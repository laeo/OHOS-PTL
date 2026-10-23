// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 OpenHarmony PC Image Contributors

/*
 * Core of the Rime IME: owns the candidate panel, the librime session and all
 * physical-key handling.
 *
 * KEY HANDLING CONTRACT (must not regress, see fix_ime_input / fix_ime_indicator):
 *  - every modifier combination (Shift/Ctrl/Alt + any other key) is returned to the
 *    app untouched (`return false`) -- never fed to rime, never consumed;
 *  - digits 0-9 are passed through unless rime is composing, so they are never lost;
 *  - Shift is only a state marker while held; Chinese/English toggles on key-UP and
 *    only when Shift was pressed "cleanly" (no other key in between);
 *  - the `keyEvent` listener is read-only (CapsLock), it always returns false.
 */
import { Log } from './Log';
import { RimeBridge, RimeState } from './RimeBridge';
import { GetHardKeyValue } from './HardKeyUtils';
import inputMethodEngine from '@ohos.inputMethodEngine';
import { InputMethodExtensionContext } from '@kit.IMEKit';
import { KeyCode } from '@kit.InputKit';
import { KeyEvent as InputKeyEvent } from '@ohos.multimodalInput.keyEvent';
import { commonEventManager, BusinessError } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';

const TAG: string = 'RimeIme->';
const InputMethodAbilityObj: inputMethodEngine.InputMethodAbility = inputMethodEngine.getInputMethodAbility();
const CANDIDATE_PANEL_MAX_WIDTH: number = 1000;
const CANDIDATE_PANEL_HEIGHT: number = 56;
const STATE_EVENT: string = 'com.ohos.rimeime.STATE';
const SETTINGS_FILE: string = 'rime_settings.json';
const DEFAULT_SCHEMA: string = 'rime_ice_ohos';

/**
 * Runtime shape of the keyboard-delegate key event. The napi object carries the legacy
 * `keyCode` / `capsLock` fields, while compileSdk 26.0.0 documents `key.code`; both are read.
 */
type InputStartCallback = (kbController: inputMethodEngine.KeyboardController,
  inputClient: inputMethodEngine.InputClient) => void;
type InputStopCallback = () => void;
type KeyEventCallback = (event: inputMethodEngine.KeyEvent) => boolean;

interface RimePersistedOptions {
  punct?: boolean;
  ascii_punct?: boolean;
  emoji?: boolean;
  enable_sentence?: boolean;
  enable_completion?: boolean;
}

interface RimePersistedSettings {
  schema?: string;
  traditional?: boolean;
  pageSize?: number;
  options?: RimePersistedOptions;
}

export class ImeController {
  private panel: inputMethodEngine.Panel | undefined = undefined;
  private kbDelegate: inputMethodEngine.KeyboardDelegate | undefined = undefined;
  private kbController: inputMethodEngine.KeyboardController | undefined = undefined;
  private inputClient: inputMethodEngine.InputClient | undefined = undefined;
  private panelShown: boolean = false;
  private shiftDown: boolean = false;
  private shiftUsedAsModifier: boolean = false;
  private altDown: boolean = false;
  private lastComposing: boolean = false;
  private deployed: boolean = false;
  private asciiMode: boolean = false;
  private ctrlDown: boolean = false;
  private shiftCombo: boolean = false;
  private traditional: boolean = false;
  private capsLock: boolean = false;
  private schemaId: string = '';
  private schemaLabel: string = '';
  private pageSize: number = 7;
  private settingsLoaded: boolean = false;
  private settingsSchema: string = '';
  private lastBroadcast: string = '';
  // Engine switches written by the settings page; applied on every inputStart.
  private engineOptions: RimePersistedOptions = {
    punct: true,
    ascii_punct: false,
    emoji: false,
    enable_sentence: true,
    enable_completion: false
  };

  private inputStartCb: InputStartCallback =
    (kbController: inputMethodEngine.KeyboardController, inputClient: inputMethodEngine.InputClient): void => {};
  private inputStopCb: InputStopCallback = (): void => {};
  private keyDownCb: (event: inputMethodEngine.KeyEvent) => boolean = (): boolean => false;
  private keyUpCb: (event: inputMethodEngine.KeyEvent) => boolean = (): boolean => false;
  private keyEventCb: (event: InputKeyEvent) => boolean = (): boolean => false;

  private mContext: InputMethodExtensionContext;

  constructor(ctx: InputMethodExtensionContext) {
    this.mContext = ctx;
  }

  onCreate(): void {
    Log.showInfo('onCreate');
    this.createCandidatePanel();
    this.registerListener();
    this.loadSettings();
    this.deployed = RimeBridge.setup('/system/etc/rime', this.mContext.filesDir);
    Log.showInfo('rime deployed=' + this.deployed + ' version=' + RimeBridge.version());
    // after setup(): librime has created the user dir, so the custom patch can be written
    this.writeUserPatch();
    if (this.deployed) {
      this.applySettings();
      this.broadcastState(true);
    }
    this.startReadyWatch();
  }

  onDestroy(): void {
    Log.showInfo('onDestroy');
    this.unRegisterListener();
    if (this.panel !== undefined) {
      try {
        InputMethodAbilityObj.destroyPanel(this.panel);
      } catch (e) {
        Log.showError('destroyPanel error ' + JSON.stringify(e));
      }
      this.panel = undefined;
    }
  }

  /**
   * A FLAG_CANDIDATE panel is an independent floating candidate window: the IME service
   * never shows/hides it for us and it is NOT a soft keyboard panel, so no QWERTY ever
   * shows up on a machine with a physical keyboard.
   */
  createCandidatePanel(): void {
    if (this.mContext === undefined) {
      return;
    }
    const d = display.getDefaultDisplaySync();
    const w1 = Math.min(d.width, CANDIDATE_PANEL_MAX_WIDTH);
    InputMethodAbilityObj.createPanel(this.mContext, {
      type: inputMethodEngine.PanelType.SOFT_KEYBOARD,
      flag: inputMethodEngine.PanelFlag.FLAG_CANDIDATE
    }).then((panel: inputMethodEngine.Panel) => {
      this.panel = panel;
      panel.setUiContent('pages/Candidate');
      panel.resize(w1, CANDIDATE_PANEL_HEIGHT);
      panel.moveTo(d.width / 2 - w1 / 2, d.height - CANDIDATE_PANEL_HEIGHT - 48);
      // setUiContent resizes the window again, so place the bar once more below the fold
      setTimeout(() => {
        try {
          panel.moveTo(d.width / 2 - w1 / 2, d.height - CANDIDATE_PANEL_HEIGHT - 48);
        } catch (e) {
          Log.showWarn('reposition err ' + JSON.stringify(e));
        }
      }, 500);
      Log.showInfo('candidate panel created w=' + w1);
    }).catch((err: BusinessError) => {
      Log.showError('createPanel failed code=' + err.code + ' msg=' + err.message);
    });
  }

  updatePanel(composing: boolean): void {
    this.lastComposing = composing;
    if (this.panel === undefined) {
      return;
    }
    try {
      Log.showInfo('updatePanel composing=' + composing + ' panel=' + (this.panel !== undefined) +
        ' shown=' + this.panelShown);
      if (composing && !this.panelShown) {
        this.panelShown = true;
        Log.showInfo('candidate panel show');
        this.panel.show();
      } else if (!composing && this.panelShown) {
        this.panelShown = false;
        Log.showInfo('candidate panel hide');
        this.panel.hide();
      }
    } catch (e) {
      Log.showError('updatePanel err ' + JSON.stringify(e));
    }
  }

  publishState(state: RimeState): void {
    const cands = state.candidates === undefined ? [] : state.candidates;
    AppStorage.setOrCreate('rimeInput', state.input);
    AppStorage.setOrCreate('rimeCandidates', cands);
    AppStorage.setOrCreate('rimeComposing', state.composing);
  }

  syncSchema(state: RimeState): void {
    if (state.schema !== undefined && state.schema.length > 0) {
      this.schemaId = state.schema;
      this.schemaLabel = state.schemaLabel !== undefined && state.schemaLabel.length > 0 ?
        state.schemaLabel : state.schema;
    }
  }

  applyState(state: RimeState): void {
    let head: string = '';
    for (let i = 0; i < state.candidates.length && i < 3; i++) {
      head += (i > 0 ? '/' : '') + state.candidates[i].t;
    }
    Log.showInfo('applyState commit=[' + state.commit + '] input=[' + state.input + '] composing=' +
      state.composing + ' ascii=' + state.ascii + ' nCand=' + state.candidates.length +
      ' top=[' + head + ']');
    if (state.commit !== undefined && state.commit.length > 0) {
      this.commitText(state.commit);
    }
    this.publishState(state);
    this.syncSchema(state);
    this.updatePanel(state.composing);
    this.broadcastState(false);
  }

  /**
   * Publishes the IME state on the common event com.ohos.rimeime.STATE, which the PC
   * dock indicator (SceneBoard ImeIndicatorComponent) subscribes to.
   */
  broadcastState(force: boolean): void {
    const sig = this.schemaId + '|' + this.schemaLabel + '|' + this.asciiMode + '|' +
      this.traditional + '|' + this.capsLock;
    if (!force && this.lastBroadcast === sig) {
      return;
    }
    this.lastBroadcast = sig;
    try {
      commonEventManager.publish(STATE_EVENT, {
        parameters: {
          schema: this.schemaId,
          schemaLabel: this.schemaLabel,
          chinese: !this.asciiMode,
          traditional: this.traditional,
          capsLock: this.capsLock
        }
      }, (err: BusinessError) => {
        if (err !== undefined && err !== null) {
          Log.showWarn('publish STATE err ' + JSON.stringify(err));
        }
      });
      Log.showInfo('broadcast STATE schema=' + this.schemaId + ' chinese=' + (!this.asciiMode) +
        ' trad=' + this.traditional + ' caps=' + this.capsLock);
    } catch (e) {
      Log.showError('broadcastState error ' + JSON.stringify(e));
    }
  }

  commitText(text: string): void {
    if (this.inputClient !== undefined) {
      try {
        this.inputClient.insertText(text);
      } catch (e) {
        Log.showError('insertText error ' + JSON.stringify(e));
      }
    }
  }

  selectCandidate(index: number): void {
    Log.showInfo('selectCandidate ' + index);
    this.applyState(RimeBridge.select(index));
  }

  registerListener(): void {
    const self = this;
    this.inputStartCb = (kbController: inputMethodEngine.KeyboardController,
      inputClient: inputMethodEngine.InputClient): void => {
      Log.showInfo('onInputStart');
      self.kbController = kbController;
      self.inputClient = inputClient;
      self.loadSettings();
      self.applySettings();
      self.broadcastState(true);
    };
    this.inputStopCb = () => {
      Log.showInfo('onInputStop');
      self.applyState(RimeBridge.reset());
      self.kbController = undefined;
      self.inputClient = undefined;
    };
    this.keyDownCb = (event: inputMethodEngine.KeyEvent) => {
      if (event === undefined || event === null) {
        return false;
      }
      return self.onKeyDown(event);
    };
    this.keyUpCb = (event: inputMethodEngine.KeyEvent) => {
      if (event === undefined || event === null) {
        return false;
      }
      return self.onKeyUp(event);
    };
    // Read-only: CapsLock state comes from the full KeyEvent; never consume it.
    this.keyEventCb = (event: InputKeyEvent) => {
      try {
        if (event === undefined || event === null) {
          return false;
        }
        const caps = event.capsLock;
        if (caps !== this.capsLock) {
          this.capsLock = caps;
          Log.showInfo('capsLock=' + caps);
          this.broadcastState(false);
        }
      } catch (e) {
        Log.showWarn('keyEvent read error ' + JSON.stringify(e));
      }
      return false;
    };

    InputMethodAbilityObj.on('inputStart', this.inputStartCb);
    InputMethodAbilityObj.on('inputStop', this.inputStopCb);
    this.kbDelegate = inputMethodEngine.getKeyboardDelegate();
    this.kbDelegate.on('keyDown', this.keyDownCb);
    this.kbDelegate.on('keyUp', this.keyUpCb);
    this.kbDelegate.on('keyEvent', this.keyEventCb);
  }

  unRegisterListener(): void {
    try {
      InputMethodAbilityObj.off('inputStart', this.inputStartCb);
      InputMethodAbilityObj.off('inputStop', this.inputStopCb);
      if (this.kbDelegate !== undefined) {
        this.kbDelegate.off('keyDown');
        this.kbDelegate.off('keyUp');
        this.kbDelegate.off('keyEvent');
      }
    } catch (e) {
      Log.showError('unRegisterListener error ' + JSON.stringify(e));
    }
  }

  /** Keycode of a delegate event. */
  private keyCodeOf(event: inputMethodEngine.KeyEvent): number {
    return event.keyCode;
  }

  onKeyDown(event: inputMethodEngine.KeyEvent): boolean {
    const keyCode = this.keyCodeOf(event);
    Log.showInfo('onKeyDown keyCode=' + keyCode + ' ready=' + RimeBridge.isReady());

    // --- modifier bookkeeping, never consumed ---
    if (keyCode === KeyCode.KEYCODE_CTRL_LEFT || keyCode === KeyCode.KEYCODE_CTRL_RIGHT) {
      this.ctrlDown = true;
      return false;
    }
    if (keyCode === KeyCode.KEYCODE_ALT_LEFT || keyCode === KeyCode.KEYCODE_ALT_RIGHT) {
      this.altDown = true;
      return false;
    }
    if (keyCode === KeyCode.KEYCODE_SHIFT_LEFT || keyCode === KeyCode.KEYCODE_SHIFT_RIGHT) {
      this.shiftDown = true;
      this.shiftUsedAsModifier = false;
      return false;
    }

    // --- IME owned hot keys ---
    // Ctrl+Shift+4 : traditionalization (simplified / traditional)
    if ((this.ctrlDown || this.shiftDown) && keyCode === KeyCode.KEYCODE_4) {
      this.shiftCombo = true;
      this.shiftUsedAsModifier = true;
      this.traditional = !this.traditional;
      RimeBridge.setOption('traditionalization', this.traditional);
      Log.showInfo('traditionalization=' + this.traditional);
      this.broadcastState(false);
      return true;
    }
    // Ctrl+Shift+9 : cycle input schema
    if ((this.ctrlDown || this.shiftDown) && keyCode === KeyCode.KEYCODE_9) {
      this.shiftCombo = true;
      this.shiftUsedAsModifier = true;
      this.cycleSchema();
      return true;
    }

    // --- ANY modifier combination is passed through to the app untouched ---
    if (this.shiftDown || this.ctrlDown || this.altDown) {
      this.shiftUsedAsModifier = true;
      return false;
    }

    // --- plain keys ---
    const value = GetHardKeyValue(keyCode);
    if (value === '') {
      return false;
    }
    return this.handleValue(value);
  }

  onKeyUp(event: inputMethodEngine.KeyEvent): boolean {
    const keyCode = this.keyCodeOf(event);
    if (keyCode === KeyCode.KEYCODE_CTRL_LEFT || keyCode === KeyCode.KEYCODE_CTRL_RIGHT) {
      this.ctrlDown = false;
      return false;
    }
    if (keyCode === KeyCode.KEYCODE_ALT_LEFT || keyCode === KeyCode.KEYCODE_ALT_RIGHT) {
      this.altDown = false;
      return false;
    }
    if (keyCode === KeyCode.KEYCODE_SHIFT_LEFT || keyCode === KeyCode.KEYCODE_SHIFT_RIGHT) {
      this.shiftDown = false;
      if (this.shiftCombo) {
        this.shiftCombo = false;
        return false;
      }
      if (this.shiftUsedAsModifier) {
        return false;
      }
      // clean Shift tap -> toggle Chinese/English, key-up itself is never consumed
      this.asciiMode = !this.asciiMode;
      RimeBridge.setOption('ascii_mode', this.asciiMode);
      Log.showInfo('ascii_mode=' + this.asciiMode);
      this.broadcastState(false);
      return false;
    }
    return false;
  }

  /**
   * Maps a key value to rime. Digits are only consumed while composing (candidate
   * selection); outside composition they fall through to the app.
   */
  handleValue(value: string): boolean {
    Log.showInfo('handleValue=[' + value + '] ascii=' + this.asciiMode);
    if (!RimeBridge.isReady()) {
      return false;
    }
    if (this.asciiMode) {
      return false;
    }
    let index = 0;
    const composing = RimeBridge.current().composing;

    if (value === ' ') {
      if (composing) {
        this.applyState(RimeBridge.select(index));
        return true;
      }
      return false;
    }

    if (value.length === 1 && value >= '0' && value <= '9') {
      if (composing && value >= '1') {
        this.applyState(RimeBridge.select(parseInt(value) - 1));
        return true;
      }
      return false; // digits must reach the app
    }

    if (value === 'KEYCODE_DEL') {
      if (composing) {
        this.applyState(RimeBridge.processKey('\\b'));
        return true;
      }
      return false;
    }

    if (value === 'KEYCODE_FORWARD_DEL') {
      if (composing) {
        this.applyState(RimeBridge.processKey('\\b'));
        return true;
      }
      return false;
    }

    if (value === 'KEYCODE_ENTER') {
      if (composing) {
        this.applyState(RimeBridge.select(index));
        return true;
      }
      return false;
    }

    if (RimeBridge.isReady()) {
      this.applyState(RimeBridge.processKey(value));
      return true;
    }
    return false;
  }

  getUserDir(): string {
    return this.mContext.filesDir + '/rime';
  }

  loadSettings(): void {
    try {
      const text = fileIo.readTextSync(this.mContext.filesDir + '/' + SETTINGS_FILE);
      if (text !== undefined && text.length > 0) {
        const cfg = JSON.parse(text) as RimePersistedSettings;
        if (cfg.schema !== undefined && cfg.schema.length > 0) {
          this.settingsSchema = cfg.schema;
          this.settingsLoaded = true;
        }
        if (cfg.traditional !== undefined) {
          this.traditional = cfg.traditional;
        }
        if (cfg.pageSize !== undefined && cfg.pageSize >= 3 && cfg.pageSize <= 9) {
          this.pageSize = cfg.pageSize;
        }
        if (cfg.options !== undefined && cfg.options !== null) {
          this.engineOptions = cfg.options;
        }
      }
      Log.showInfo('settings loaded schema=' + this.settingsSchema + ' trad=' + this.traditional +
        ' page=' + this.pageSize);
    } catch (e) {
      Log.showInfo('no settings file yet');
    }
  }

  applySettings(): void {
    try {
      if (!RimeBridge.isReady()) {
        return;
      }
      let state = RimeBridge.getState();
      if ((this.settingsLoaded && this.settingsSchema.length > 0) && state.schema !== this.settingsSchema) {
        state = RimeBridge.selectSchema(this.settingsSchema);
        Log.showInfo('applied schema=' + this.settingsSchema);
      }
      this.syncSchema(state);
      if (this.schemaId.length === 0) {
        this.schemaId = DEFAULT_SCHEMA;
      }
      RimeBridge.setOption('traditionalization', this.traditional);
      // Options toggled by the settings page (setOption takes effect immediately).
      const o = this.engineOptions;
      RimeBridge.setOption('punct', o.punct === true);
      RimeBridge.setOption('ascii_punct', o.ascii_punct === true);
      RimeBridge.setOption('emoji', o.emoji === true);
      RimeBridge.setOption('enable_sentence', o.enable_sentence !== false);
      RimeBridge.setOption('enable_completion', o.enable_completion === true);
    } catch (e) {
      Log.showError('applySettings error ' + JSON.stringify(e));
    }
  }

  persistSettings(): void {
    try {
      const cfg: RimePersistedSettings = {
        schema: this.schemaId,
        traditional: this.traditional,
        pageSize: this.pageSize,
        options: this.engineOptions
      };
      const f = fileIo.openSync(this.mContext.filesDir + '/' + SETTINGS_FILE,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, JSON.stringify(cfg));
      fileIo.closeSync(f);
      this.settingsSchema = this.schemaId;
      this.settingsLoaded = true;
    } catch (e) {
      Log.showError('persistSettings error ' + JSON.stringify(e));
    }
  }

  /**
   * menu/page_size cannot be switched at runtime; it goes to the user patch file and
   * takes effect on the next engine deployment (i.e. after the IME restarts).
   */
  writeUserPatch(): void {
    try {
      const dir = this.getUserDir();
      try {
        fileIo.accessSync(dir);
      } catch (e) {
        fileIo.mkdirSync(dir, true);
      }
      const yaml = '# generated by ImeController (Rime menu page size)\npatch:\n  menu/page_size: ' +
        this.pageSize + '\n';
      const f = fileIo.openSync(dir + '/default.custom.yaml',
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, yaml);
      fileIo.closeSync(f);
      Log.showInfo('wrote user patch page_size=' + this.pageSize);
    } catch (e) {
      Log.showError('writeUserPatch error ' + JSON.stringify(e));
    }
  }

  cycleSchema(): void {
    if (!RimeBridge.isReady()) {
      return;
    }
    let idx = 0;
    const list = RimeBridge.getSchemaList();
    if (idx === list.length) {
      Log.showWarn('no schemas to cycle');
      return;
    }
    for (idx = 0; idx < list.length; idx++) {
      if (list[idx].id === this.schemaId) {
        break;
      }
    }
    idx = (idx + 1) % list.length;
    const next = list[idx];
    Log.showInfo('cycleSchema -> ' + next.id);
    const state = RimeBridge.selectSchema(next.id);
    this.syncSchema(state);
    this.persistSettings();
    this.broadcastState(false);
  }

  /** The engine deploys dictionaries asynchronously; poll until the session is live. */
  startReadyWatch(): void {
    const self = this;
    let c2 = 0;
    const d2 = setInterval(() => {
      c2++;
      if (RimeBridge.isReady()) {
        clearInterval(d2);
        self.applySettings();
        self.broadcastState(true);
        Log.showInfo('engine ready, state broadcast');
      } else if (c2 > 240) {
        clearInterval(d2);
        Log.showWarn('engine not ready after wait');
      }
    }, 500);
  }
}
