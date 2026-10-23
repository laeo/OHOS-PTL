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
 * PC/2in1 mouse settings page.
 * The menu entry (phone_mouse_settings) previously pointed at this page but it
 * was missing from the open-source tree, so tapping "鼠标" did nothing (and
 * could crash on some runtimes).  This is a self-contained custom page that
 * reuses the existing mouse settings components.
 */
import { NavEntryKey } from '@ohos/settings.common/src/main/ets/utils/Consts';
import { PageLoader } from '@ohos/settings.common/src/main/ets/framework/common/PageLoader';
import { PageType, SettingPageModel } from '@ohos/settings.common/src/main/ets/framework/model/SettingPageModel';
import {
  MouseImageComponent,
  MouseStyleRadioComponent,
  SplitMouseRadioComponent,
  SplitMouseSliderComponent
} from './view/MouseSettingsComponent';
import { MouseSliderType, MouseStyleType } from './utils/Constants';
import { MouseSettingsManager } from './MouseSettingsManager';

@Component
struct MouseSettingsPage {
  @State isCircleStyle: boolean = false;

  aboutToAppear(): void {
    this.isCircleStyle = MouseSettingsManager.getInstance().isCircleStyle();
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {
          MouseImageComponent()

          Row() {
            Text($r('app.string.mouse_pointer_style'))
              .fontSize($r('sys.float.Body_L'))
              .fontColor($r('sys.color.font_primary'))
              .layoutWeight(1)
            MouseStyleRadioComponent({
              mouseStyleType: MouseStyleType.MouseDotCursor,
              isChecked: this.isCircleStyle
            })
            MouseStyleRadioComponent({
              mouseStyleType: MouseStyleType.MouseArrowCursor,
              isChecked: !this.isCircleStyle
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .alignItems(VerticalAlign.Center)

          Divider()

          SplitMouseRadioComponent()

          Divider()

          SplitMouseSliderComponent({
            sliderValue: MouseSettingsManager.getInstance().getMousePointSize(),
            sliderType: MouseSliderType.MousePointerSize,
            title: $r('app.string.mouse_pointer_size')
          })

          Divider()

          SplitMouseSliderComponent({
            sliderValue: MouseSettingsManager.getInstance().getPointerSpeed(),
            sliderType: MouseSliderType.MousePointerSpeed,
            title: $r('app.string.cursor_tracking_speed')
          })
        }
        .width('100%')
        .padding({ bottom: 16 })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
    }
    .title($r('app.string.mouse_settings_title'))
    .hideTitleBar(false)
    .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
  }
}

@Builder
function mouseSettingsPageBuilder(param: object): void {
  MouseSettingsPage();
}

function customPage(): SettingPageModel {
  return {
    id: 'Mouse',
    url: NavEntryKey.PHONE_MOUSE_SETTINGS,
    type: PageType.PAGE_TYPE_CUSTOM,
    title: $r('app.string.mouse_settings_title')
  };
}

PageLoader.load(NavEntryKey.PHONE_MOUSE_SETTINGS, {
  configGenerator: customPage,
  pageBuilder: wrapBuilder(mouseSettingsPageBuilder)
});
