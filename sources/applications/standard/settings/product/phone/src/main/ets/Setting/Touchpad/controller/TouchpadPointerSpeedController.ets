/*
 * Copyright (c) Huawei Technologies Co., Ltd. 2024-2025. All rights reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import pointer from '@ohos.multimodalInput.pointer';
import { BusinessError } from '@ohos.base';
import { LogUtil } from '@ohos/settings.common/src/main/ets/utils/LogUtil';
import { TouchPadConstants } from '../utils/Constants';

const APP_STORAGE_KEY: string = 'touchpad_speed';

/*
 * Touchpad pointer-speed controller.
 *
 * The touchpad pointer speed is *authoritative* in the MMI server
 * (MousePreferenceAccessor), exposed through the system API
 * pointer.getTouchpadPointerSpeed()/setTouchpadPointerSpeed() (range [1,11]).
 *
 * IMPORTANT: no synchronous IPC is performed on the UI thread here.
 *   - The slider's local value is kept in AppStorage (pure memory).
 *   - MMI is read/written exclusively through the async pointer API with
 *     explicit promise rejection handling (BusinessError 202/401 or a missing
 *     SA must never crash or block the Settings app).
 * This is what prevents the touchpad page from stalling the app's main thread
 * (which previously left the MMI input-event socket undrained and produced
 * INPUT_EVENT_SOCKET_TIMEOUT / APPLICATION_BLOCK_INPUT).
 */
export class TouchpadPointerSpeedController {
  private tag: string = 'TouchpadPointerSpeedController: ';

  private normalize(value: number): number {
    if (value === undefined || value === null || isNaN(value)) {
      return TouchPadConstants.DEFAULT_SPEED;
    }
    let speed: number = Math.round(value);
    if (speed < TouchPadConstants.POINTER_MIN_SPEED) {
      speed = TouchPadConstants.POINTER_MIN_SPEED;
    }
    if (speed > TouchPadConstants.POINTER_MAX_SPEED) {
      speed = TouchPadConstants.POINTER_MAX_SPEED;
    }
    return speed;
  }

  private updateCache(speed: number): void {
    try {
      AppStorage.setOrCreate(APP_STORAGE_KEY, speed);
    } catch (e) {
      LogUtil.error(`${this.tag} cache AppStorage failed`);
    }
  }

  // Local UI cache only; no IPC, never blocks the caller.
  public getPointerSpeed(): number {
    try {
      let cached: number | undefined = AppStorage.get<number>(APP_STORAGE_KEY);
      if (cached !== undefined && cached !== null && !isNaN(cached)) {
        return this.normalize(cached);
      }
    } catch (e) {
      LogUtil.error(`${this.tag} getPointerSpeed error`);
    }
    return TouchPadConstants.DEFAULT_SPEED;
  }

  // Read the authoritative value from MMI (async, never throws).
  public syncPointerSpeed(): void {
    pointer.getTouchpadPointerSpeed().then((speed: number) => {
      let normalized: number = this.normalize(speed);
      this.updateCache(normalized);
      LogUtil.info(`${this.tag} syncPointerSpeed ${normalized}`);
    }).catch((err: BusinessError) => {
      LogUtil.error(`${this.tag} getTouchpadPointerSpeed failed, code:${err?.code}`);
    });
  }

  public onSliderChange(value: number, mode: SliderChangeMode): void {
    if (mode !== SliderChangeMode.End) {
      return;
    }
    let speed: number = this.normalize(value);
    // Update the in-memory UI cache first (no IPC) so the UI stays responsive.
    this.updateCache(speed);
    // Persist to MMI asynchronously; never block the UI thread, never throw.
    pointer.setTouchpadPointerSpeed(speed).then(() => {
      LogUtil.info(`${this.tag} setTouchpadPointerSpeed ${speed} ok`);
    }).catch((err: BusinessError) => {
      LogUtil.error(`${this.tag} setTouchpadPointerSpeed failed, code:${err?.code}`);
    });
  }
}
