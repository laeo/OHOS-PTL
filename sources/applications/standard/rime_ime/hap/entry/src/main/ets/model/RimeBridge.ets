// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 OpenHarmony PC Image Contributors

/*
 * Thin ArkTS wrapper around the librime N-API module (liblibrime_napi.so).
 * All engine calls return the full state as a JSON string.
 */
import { Log } from './Log';
import rime from 'liblibrime_napi.so';
import { fileIo } from '@kit.CoreFileKit';

const TAG: string = 'RimeBridge->';

export interface RimeCandidate {
  t: string;
  c: string;
}

export interface RimeState {
  commit: string;
  input: string;
  composing: boolean;
  ascii: boolean;
  schema: string;
  schemaLabel: string;
  candidates: RimeCandidate[];
}

export interface RimeSchemaItem {
  id: string;
  name: string;
}

const EMPTY_STATE: RimeState = {
  commit: '',
  input: '',
  composing: false,
  ascii: false,
  schema: '',
  schemaLabel: '',
  candidates: []
};

export class RimeBridge {
  private static ready: boolean = false;
  private static last: RimeState = EMPTY_STATE;

  /**
   * Engine is deployed and a session exists -> key events may be fed to it.
   * NOTE: the local `ready` flag only records that init() succeeded; librime deploys the
   * dictionaries on a background thread, so the authoritative answer is the native isReady().
   */
  static isReady(): boolean {
    if (!RimeBridge.ready) {
      return false;
    }
    try {
      return rime.isReady();
    } catch (e) {
      Log.showError('isReady error: ' + JSON.stringify(e));
      return false;
    }
  }

  /** sharedDataDir=/system/etc/rime, userDataDir=<filesDir> (rime subdir is appended). */
  static setup(sharedDir: string, userDir: string): boolean {
    try {
      const user = userDir + '/rime';
      if (!fsExists(user)) {
        fsMkdir(user);
      }
      const rc: number = rime.init(sharedDir, user);
      Log.showInfo('rime.init rc=' + rc + ' userDir=' + user);
      RimeBridge.ready = rc >= 0;
    } catch (e) {
      Log.showError('setup error: ' + JSON.stringify(e));
      RimeBridge.ready = false;
    }
    return RimeBridge.ready;
  }

  static setOption(name: string, value: boolean): void {
    if (!RimeBridge.ready) {
      return;
    }
    try {
      rime.setOption(name, value);
    } catch (e) {
      Log.showError('setOption error: ' + JSON.stringify(e));
    }
  }

  static getOption(name: string): boolean {
    try {
      return rime.getOption(name);
    } catch (e) {
      Log.showError('getOption error: ' + JSON.stringify(e));
      return false;
    }
  }

  private static parse(json: string): RimeState {
    try {
      RimeBridge.last = JSON.parse(json) as RimeState;
    } catch (e) {
      Log.showError('parse error: ' + json);
    }
    if (RimeBridge.last === undefined || RimeBridge.last.candidates === undefined) {
      RimeBridge.last = EMPTY_STATE;
    }
    return RimeBridge.last;
  }

  static processKey(key: string, mask: number = 0): RimeState {
    if (!RimeBridge.ready) {
      return RimeBridge.last;
    }
    try {
      return RimeBridge.parse(rime.processKey(key, mask));
    } catch (e) {
      Log.showError('processKey error: ' + JSON.stringify(e));
      return RimeBridge.last;
    }
  }

  static select(index: number): RimeState {
    if (!RimeBridge.ready) {
      return RimeBridge.last;
    }
    try {
      return RimeBridge.parse(rime.selectCandidate(index));
    } catch (e) {
      Log.showError('select error: ' + JSON.stringify(e));
      return RimeBridge.last;
    }
  }

  static reset(): RimeState {
    if (!RimeBridge.ready) {
      return RimeBridge.last;
    }
    try {
      return RimeBridge.parse(rime.reset());
    } catch (e) {
      return RimeBridge.last;
    }
  }

  static current(): RimeState {
    return RimeBridge.last;
  }

  static getState(): RimeState {
    if (!RimeBridge.ready) {
      return RimeBridge.last;
    }
    try {
      return RimeBridge.parse(rime.getState());
    } catch (e) {
      return RimeBridge.last;
    }
  }

  static getSchemaList(): RimeSchemaItem[] {
    try {
      const list = JSON.parse(rime.getSchemaList()) as RimeSchemaItem[];
      if (list === undefined || list === null) {
        return [];
      }
      return list;
    } catch (e) {
      Log.showError('getSchemaList error: ' + JSON.stringify(e));
      return [];
    }
  }

  static selectSchema(id: string): RimeState {
    if (!RimeBridge.ready) {
      return RimeBridge.last;
    }
    try {
      return RimeBridge.parse(rime.selectSchema(id));
    } catch (e) {
      Log.showError('selectSchema error: ' + JSON.stringify(e));
      return RimeBridge.last;
    }
  }

  static getSchema(): string {
    try {
      return rime.getSchema();
    } catch (e) {
      return '';
    }
  }

  static version(): string {
    try {
      return rime.getVersion();
    } catch (e) {
      return 'unknown';
    }
  }
}

// Local fs helpers kept private to avoid an extra module.
function fsExists(path: string): boolean {
  try {
    return fileIo.accessSync(path);
  } catch (e) {
    return false;
  }
}

function fsMkdir(path: string): void {
  fileIo.mkdirSync(path, true);
}
