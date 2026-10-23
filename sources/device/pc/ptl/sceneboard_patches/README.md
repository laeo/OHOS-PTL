# sceneboard_patches — 对上游 window_scene_board 的 PC 桌面适配补丁

上游 `window_scene_board` 仓（`https://gitcode.com/openharmony/window_scene_board.git`）
**不在 OpenHarmony 开源 manifest 里**（`grep -c window_scene_board .repo/manifests/ohos/ohos.xml` = 0，
合入它的 PR #2660 / #2661 尚未落地）。因此它是按源码方式单独 clone 到树外构建的：

- 分支：**`OpenHarmony-7.0-Release`**（`build-profile.json5` 的 `compileSdkVersion 26.0.0`
  与本树 `prebuilts/ohos-sdk/linux/26.0.0` 匹配；`master` 分支要 API 23，本地没装）。
- 目标模块：`product/pc`（module **`pc_sceneboard`**，bundle `com.ohos.sceneboard`）。
- 开源 release 只发**手机产品版**预编译 HAP（module `phone_sceneboard`，不含
  `feature/smartdock` 任务栏 / `feature/pcmode` / `product/pcbase`），所以 PC 桌面必须自建。

> 这里**只放补丁**。上游源码树由 clone 产生，不入库。

## 补丁清单

| 文件 | 内容 |
|---|---|
| `patches/0001-pc-ptl-desktop-adaptation.patch` | 全部适配改动（13 个修改 + 3 个新增），见下 |

改动摘要：

| 主题 | 文件 |
|---|---|
| 桌面预置布局（24 个图标）与空布局回退 | `feature/pcbase/.../rawfile/layoutInfo.json`、新增 `layoutInfo_pc_mode.json`、`product/pcbase/.../PcPageDesktopLayoutConfig.ets` |
| 任务栏（Dock）扩展：输入法指示器 | `feature/smartdock/pcsmartdock/.../FixedLayout.ets`、`DockStatusBarComponent.ets`、新增 `ImeIndicatorComponent.ets`、中英文 `string.json` |
| 状态栏电源/音量图标 | `feature/statusbarcomponent/.../LocalVisibleControl.ets`、`pc_dark_syskey.svg`、`pc_light_syskey.svg`、`system_ring_*.svg` |
| 主窗口装饰：焦点描边跟随圆角 | `product/pcbase/.../SCBScene.ets` |
| `product/pc` 缺失的 `icon.png`（开源分支未带） | 新增 `product/pc/src/main/resources/base/media/icon.png` |

## 用法

```sh
# 1. clone 上游（浅克隆即可）
git clone --depth 1 -b OpenHarmony-7.0-Release \
  https://gitcode.com/openharmony/window_scene_board.git  window_scene_board
cd window_scene_board

# 2. 打补丁
git apply --stat   <repo>/device/pc/ptl/sceneboard_patches/patches/0001-pc-ptl-desktop-adaptation.patch
git apply         <repo>/device/pc/ptl/sceneboard_patches/patches/0001-pc-ptl-desktop-adaptation.patch

# 3. hvigor 独立构建（不能用 ./build.sh：上游 BUILD.gn 依赖 //vendor/binary 的
#    华为内部工具链；DevEco CLI 的 hvigor 可以）
node hvigor/update-sdk-interface.js <sdkRoot>/26.0.0   # 把仓里自带的接口 d.ts 打桩进 SDK
# 依赖：85 个模块目录，逐个 ohpm install --all
# 缺依赖会报 $media:icon / $color:scb_intent_start_window_background 未定义
hvigorw assembleHap --mode module -p module=pc_sceneboard --no-daemon \
  -p debuggable=false -p build_mode=release -p hvigor-obfuscation=true
# → product/pc/build/default/outputs/default/pc_sceneboard-default-signed.hap
```

构建配方与历史踩坑详见本仓库 `out/x86_64_virt/ohos-dbg/PC_DESKTOP_STATUS.md`
与 `out/x86_64_virt/ohos-dbg/AGENTS.md` 第 16 节。

## 安装

产物替换 `/system/app/SceneBoard/SceneBoard.hap`，签名证书与 profile 的
distribution 证书需与 `vendor/ohemu/virt/preinstall-config/install_list_capability.json`
中 `com.ohos.sceneboard` 条目的 `app_signature` 一致。

## 许可

本目录的补丁为 Apache-2.0（见 `LICENSE`），**但应用它得到的产物受上游
window_scene_board 的 Apache-2.0 约束**。补丁不改变上游许可证。