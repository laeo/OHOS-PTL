# aira — OpenHarmony 兼容垫片

本目录**不包含 Aira 浏览器源码**，只保存我们为在纯 OpenHarmony（非 HarmonyOS）SDK 上
运行 Aira 而做的**兼容层**，以及把它接到上游的补丁。

| 目录 | 内容 |
|---|---|
| `shim/OpenHarmonyLoginComponentShim.ets` | HMS `loginComponentManager` 的 OpenHarmony 落地替身（新增文件） |
| `patches/0001-openhms-login-component-shim.patch` | 把 10 处 `@kit.AccountKit` 静态导入改指垫片 + 构建配置调整 |
| `tools/env.sh`、`tools/build.sh` | hvigor 构建 + 剥 `libs/` + 重签 |

上游：`https://github.com/mason173/aira-browser.git`（**GPL-3.0**）。

## 根因

Aira 的 `app/pages/BrowserShellPage.ets` 等 10 个文件里有

```ts
import { loginComponentManager } from '@kit.AccountKit';
```

`@kit.AccountKit` 在 **HarmonyOS SDK** 里额外再导出 HMS 的 `loginComponentManager`；
**OpenHarmony 没有这个导出**。ArkCompiler 在**模块链接期**直接抛错：

```
SyntaxError: the requested module '@hms:core.account.LoginComponent'
  does not provide an export name 'loginComponentManager'
  which imported by '&entry/src/main/ets/app/pages/BrowserShellPage&'
→ AMS: PROCESS_KILL … reason=Js Error
```

这不是「软失败」——缺*导出名*走的是硬失败；而同一份日志里 `systemShare` /
`hdsMaterial` / `safetyDetect` / `iap` / `appInfoManager` 等 HMS 模块只是
`Load native module entry is not a JSObject`，被应用自己的 `try/catch` 吃掉，不影响运行。

现象：新用户引导页点「跳过 → 进入主页」后 `router.replaceUrl` reject（被 `.catch`
静默吞掉），页面退回引导页第一帧卡死；冷启动直接进主页则进程被 AMS 杀掉。

## 垫片做了什么

`OpenHarmonyLoginComponentShim.ets`（约 160 行）镜像 HMS `loginComponentManager`
用到的全部成员，**签名与枚举值与 HMS 一致**：

- `HuaweiIDCredential`、`AgreementStatus`、`Style`、`LoginType`、`ClickEvent`
- `LoginWithHuaweiIDButtonController`：`onClickLoginWithHuaweiIDButton` /
  `onClickEvent` / `setAgreementStatus` / `setEnabled` / `setLocale`，
  全部 `return this`（链式调用点无需改）
- `notifyUnavailable()`：兜底按钮点击时回调 `BusinessError{code: 1001502009}`，
  走应用既有错误路径（toast + 关面板），**不挂起**
- 导出常量 `IS_HUAWEI_LOGIN_COMPONENT_AVAILABLE = false`

唯一的真 UI 依赖 `LoginWithHuaweiIDButton`（HMS ArkUI 组件）替换成等尺寸的
ArkUI `Button`（红色圆角、未同意协议时灰显），`.onClick` 走 `notifyUnavailable()`；
未勾选协议时仍由上层透明按钮拦截并提示「请先同意协议」，交互不变。

## 用法

```sh
# 上游 clone（不在本树内）
git clone https://github.com/mason173/aira-browser.git aira_src

# 构建 + 剥 libs + 重签
cd third_party/aira
AIRA_SRC=$PWD/../../out/.../aira_src/AiraBrowser bash tools/build.sh --apply-patches
```

`AIRA_SRC` / `AIRA_SIGN_DIR` / `DEVECO_HMS_SDK` 等见 `tools/env.sh`。

## 安装位置

HAP 放 **`/system/app/org.aira.browser/Aira.hap`**，并在
`vendor/ohemu/virt/preinstall-config/install_list.json` 增加：

```json
{ "app_dir": "/system/app/org.aira.browser", "removable": true }
```

- `/vendor/app/...` **不行**（实测）：预装能成功，但 app 沙箱 mount namespace 里没有
  `/vendor`，AMS 传给进程的 HAP 源路径打不开 → `failed to create js obj` → LIFECYCLE_TIMEOUT。
- 必须**剥掉 `libs/`**：`EnforceCodeSignForAppWithPluginId` 对任何带 `.so` 的第三方预装
  HAP 返回 `statx EINVAL` → `-256 (CS_ERR_FILE_INVALID)`。这与引导页卡死**无因果关系**
  （带全部 5 个 x86_64 原生库的 HAP 崩溃一模一样），但预装必须做。
- ArkTS 源码仍会 `import('libaira_*.so')`，靠 `arkOptions.runtimeOnly.packages`
  提供的 d.ts 解析；运行期模块加载失败被应用自己的 `try/catch` 吃掉（懒加载 + 降级）。

## 许可（重要）

- **上游 Aira：GPL-3.0**。
- 本目录的垫片与脚本：**GPL-3.0-or-later**（必须与上游兼容，故不能用 Apache-2.0），
  见各文件 SPDX 头。
- 再分发时需同时提供上游 Aira 的完整源码（GPL-3.0 要求）。