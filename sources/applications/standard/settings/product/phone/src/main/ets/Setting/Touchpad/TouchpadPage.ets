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

/*
 * PC/2in1 touchpad settings page.
 * The menu entry (pad_touchpad_settings_entry) pointed at this missing page.
 * Self-contained custom page reusing the existing touchpad components.
 */
import { NavEntryKey } from '@ohos/settings.common/src/main/ets/utils/Consts';
import { PageLoader } from '@ohos/settings.common/src/main/ets/framework/common/PageLoader';
import { PageType, SettingPageModel } from '@ohos/settings.common/src/main/ets/framework/model/SettingPageModel';
import { TouchpadPointerSpeedComponent } from './view/TouchpadPointerSpeedComponent';

@Component
struct TouchpadSettingsPage {
  build() {
    NavDestination() {
      Scroll() {
        Column() {
          Row() {
            Text($r('app.string.cursor_tracking_speed'))
              .fontSize($r('sys.float.Body_L'))
              .fontColor($r('sys.color.font_primary'))
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 8 })

          TouchpadPointerSpeedComponent()
        }
        .width('100%')
        .padding({ bottom: 16 })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
    }
    .title($r('app.string.touchpad'))
    .hideTitleBar(false)
    .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
  }
}

@Builder
function touchpadSettingsPageBuilder(param: object): void {
  TouchpadSettingsPage();
}

function customPage(): SettingPageModel {
  return {
    id: 'Touchpad',
    url: NavEntryKey.PAD_TOUCHPAD_SETTINGS_ENTRY,
    type: PageType.PAGE_TYPE_CUSTOM,
    title: $r('app.string.touchpad')
  };
}

PageLoader.load(NavEntryKey.PAD_TOUCHPAD_SETTINGS_ENTRY, {
  configGenerator: customPage,
  pageBuilder: wrapBuilder(touchpadSettingsPageBuilder)
});
