// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 OpenHarmony PC Image Contributors

/*
 * hilog + file wrapper for the Rime IME.
 *
 * hilog from this (unsigned, non-system-app) HAP is dropped for the reserved domain, so
 * every line is additionally appended to <filesDir>/rime_ime.log, which can be read back
 * with `hdc file recv /data/app/el2/100/base/com.ohos.rimeime/haps/entry/files/rime_ime.log`.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';

const DOMAIN: number = 0xA0300;
const TAG: string = 'RimeIme->';
const LOG_FILE: string = 'rime_ime.log';
const MAX_BYTES: number = 512 * 1024;

let logPath: string = '';

export function setLogFile(path: string): void {
  logPath = path;
}

function stamp(): string {
  const d: Date = new Date();
  const p: (n: number, w: number) => string =
    (v: number, w: number): string => (v < 10 ? '0' + v : '' + v);
  return p(d.getHours(), 2) + ':' + p(d.getMinutes(), 2) + ':' + p(d.getSeconds(), 2) +
    '.' + p(d.getMilliseconds(), 3);
}

function toFile(msg: string): void {
  if (logPath.length === 0) {
    return;
  }
  try {
    const stat = fileIo.statSync(logPath);
    if (stat.size > MAX_BYTES) {
      fileIo.truncateSync(logPath, 0);
    }
  } catch (e) {
  }
  try {
    const f = fileIo.openSync(logPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE |
      fileIo.OpenMode.APPEND);
    fileIo.writeSync(f.fd, '[' + stamp() + '] ' + msg + '\n');
    fileIo.closeSync(f);
  } catch (e) {
  }
}

export class Log {
  static showDebug(...msg: Object[]): void {
    hilog.debug(DOMAIN, TAG, '%{public}s', ...msg);
    toFile('D ' + msg.join(' '));
  }

  static showInfo(...msg: Object[]): void {
    hilog.info(DOMAIN, TAG, '%{public}s', ...msg);
    toFile('I ' + msg.join(' '));
  }

  static showWarn(...msg: Object[]): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', ...msg);
    toFile('W ' + msg.join(' '));
  }

  static showError(...msg: Object[]): void {
    hilog.error(DOMAIN, TAG, '%{public}s', ...msg);
    toFile('E ' + msg.join(' '));
  }
}

export { TAG };