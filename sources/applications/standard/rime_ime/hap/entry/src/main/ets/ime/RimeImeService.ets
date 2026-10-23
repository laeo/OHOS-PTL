// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 OpenHarmony PC Image Contributors

/*
 * Standard IME entry point (InputMethodExtensionAbility, type=inputMethod).
 */
import { InputMethodExtensionAbility } from '@kit.IMEKit';
import { Want } from '@kit.AbilityKit';
import { ImeController } from '../model/ImeController';
import { setImeController } from '../model/ImeSingleton';
import { Log, setLogFile } from '../model/Log';

export class RimeImeService extends InputMethodExtensionAbility {
  private controller: ImeController | undefined = undefined;

  onCreate(want: Want): void {
    setLogFile(this.context.filesDir + '/rime_ime.log');
    Log.showInfo('onCreate want=' + want.abilityName + ' filesDir=' + this.context.filesDir);
    this.controller = new ImeController(this.context);
    setImeController(this.controller);
    this.controller.onCreate();
  }

  onDestroy(): void {
    Log.showInfo('onDestroy');
    if (this.controller !== undefined) {
      this.controller.onDestroy();
    }
    this.controller = undefined;
  }
}
