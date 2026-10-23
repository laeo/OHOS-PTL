// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 OpenHarmony PC Image Contributors

import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0011;
const TAG: string = 'OHOSTerm';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Open the terminal in a comfortable free window on 2in1/PC, clamped to
    // the actual display so it never opens larger than the screen.
    try {
      const win = windowStage.getMainWindowSync();
      let w = 1000;
      let h = 640;
      try {
        const d = display.getDefaultDisplaySync();
        w = Math.min(1000, Math.max(480, d.width - 60));
        h = Math.min(640, Math.max(360, d.height - 100));
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'display query failed: %{public}s', JSON.stringify(e));
      }
      win.resize(w, h);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'resize failed: %{public}s', JSON.stringify(e));
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent done');
      this.setupWindowChrome(windowStage);
    });
  }

  /* Window frame policy -- "let the system own the frame".
   *
   * A previous revision called setWindowDecorVisible(false) to get a frameless
   * window and drew its own title bar.  That silently does nothing in this
   * product: in the unified window_scene architecture the decor of a *main*
   * window is decided by
   *   foundation/window/window_manager/window_scene/session/host/src/
   *     scene_session.cpp:4612-4629  SceneSession::IsDecorEnable()
   * where `isValidWindow = isMainWindow || ((isSubWindow || isDialogWindow) &&
   * property->IsDecorEnable())` -- the per-window app flag is only consulted
   * for sub/dialog windows, and a main window additionally requires the
   * system-wide `systemConfig_.isSystemDecorEnable_`, which
   * vendor/ohemu/virt/window_config/window_manager_config.xml:18 keeps true
   * (`<decor enable="true">`, fed by
   * window_scene/session_manager/src/scene_session_manager.cpp:1283-1290).
   *
   * Custom system title-bar content (setTitleBarStyle / getTitleBarStyle) does
   * not exist in this SDK (26.0.0 @ohos.window.d.ts) nor in window_scene, so
   * there is no third option either.
   *
   * Therefore: keep the system decoration (it provides the title bar, the
   * minimize/maximize/close buttons, the rounded corners and the drop shadow),
   * and carry the app's own controls (tabs / 设置 / 新建标签) in the first row of
   * the page content, right below the system title bar.  See Index.ets
   * tabBarRow(). */
  private setupWindowChrome(windowStage: window.WindowStage): void {
    try {
      const win = windowStage.getMainWindowSync();
      // Explicit: the system decoration must stay on.  Calling this with the
      // *right* value keeps the call meaningful on products where the default
      // differs, and logs the effective state for on-device verification.
      win.setWindowDecorVisible(true);
      win.setWindowTitleButtonVisible(true, true, true);
      win.setWindowTitle('终端').catch((e: BusinessError): void => {
        hilog.warn(DOMAIN, TAG, 'setWindowTitle failed: %{public}s', JSON.stringify(e));
      });
      // Transparent window background so the decoration's rounded corners and
      // shadow are not painted over by an opaque square (ARKUI_UI_STANDARD.md
      // §10 "窗口圆角兼容性").  The page paints its own rounded, clipped
      // surface inside a uniform padding (Index.ets OUTER_PAD / WIN_RADIUS).
      win.setWindowBackgroundColor('#00000000');
      try {
        const p = win.getWindowProperties();
        hilog.info(DOMAIN, TAG,
          'window chrome: decor=%{public}s type=%{public}d rect=%{public}d x %{public}d',
          win.getWindowDecorVisible().toString(), p.type,
          p.windowRect.width, p.windowRect.height);
      } catch (e3) {
        hilog.warn(DOMAIN, TAG, 'getWindowProperties failed: %{public}s', JSON.stringify(e3));
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setupWindowChrome failed: %{public}s', JSON.stringify(e));
    }
  }

  onWindowStageDestroy(): void {
  }

  onDestroy(): void {
  }
}
