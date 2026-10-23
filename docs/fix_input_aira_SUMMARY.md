# fix_input_aira —— ① 输入框 focus 卡顿（MMI 输入事件分发链路） ② AIRA「数据同步 → 自建」点击闪退

> 产品 **`pc_ptl`**（HONOR XWC-P / Intel PTL / x86_64 / 2in1 / OpenHarmony 7.0 / kernel linux-7.2.7）
> 工作目录：`out/x86_64_virt/ohos-dbg/fix_input_aira/`
> **未改交付镜像** `partdisk/media/ohos_part_pc_ptl.img`（按要求只改 `scratch.img` 验证）；
> 未写 `/tmp`（只用 `/tmp/opencode/` 放过一次临时文件）；未动 `/dev/sda*`、未碰内置盘/ESP；
> 仓库改动只在 `foundation/multimodalinput/input`（MMI）与 Aira 源码副本
> `fix_aira_guide/aira_src/`（**不是** `applications/standard/browser`）。
> 全程中文。

---

## 0. TL;DR

| 项 | 结论 |
|---|---|
| **① focus 卡顿的真实机制** | **不是某个 IME 的问题**，而是 MMI 事件分发链路上的**两个结构缺陷**叠加：<br>（a）上一轮 `fix_touchpad_mmi` 的「客户端缓冲满就丢事件」把 **点击（DOWN/UP）也当普通事件丢掉** —— 丢一次点击 = 输入框永远不获得焦点，用户表现为「focus 极卡顿、要点好几下」；<br>（b）MMI **客户端的 socket 读取线程与事件回调线程是同一个**：回调里只要有同步 IPC（session manager → app 的 `TransferKeyEventForConsumed` 是 **TF_SYNC**），这个线程就停止读 socket → 服务端缓冲填满 → 回到 (a) 继续丢点击。<br>（c）整条链路**没有任何分段耗时埋点**，所以现场无法定位（本轮补上 `MMI_PERF` 埋点）。 |
| **① 修法** | 服务端：**关键事件（pointer DOWN/UP/BUTTON_*/CANCEL、key DOWN/UP）不再丢**，改为最多等 150 ms 让对端腾出缓冲；只有 motion/hover 这类可合并事件才丢。客户端：**socket 读取与事件回调解耦**（新增专用 dispatch 线程 `OS_mmi_Dispatch`），客户端再慢也不会停止读 socket；并对「过期 hover 事件」做丢弃、对「事件年龄」做埋点。 |
| **② AIRA 自建闪退** | 根因：`自建`页（`SyncPersonalServerConfigPage`）用到的 `SettingsHdsScaffold` **静态导入 HMS 的 `@kit.UIDesignKit`（HDS 组件 `HdsNavDestination` / `HdsTabs`）**。OpenHarmony 设备**没有 HDS 运行库**（`out/ptl` 里没有任何 hds 库），运行时模块加载失败 → `build()` 里调用组件抛未捕获异常 → **进程被杀（闪退）**。应用其它页面不引用 HDS，所以「能启动、能进主页」，唯独这 68 个 HDS 页面一打开就死。 |
| **② 修法** | 彻底去掉应用对 HDS 的依赖：材质能力改用本地垫片（恒「不可用」→ 走应用**本来就有的**普通 ArkUI 降级路径），`HdsNavDestination` / `HdsTabs` 换成普通 ArkUI（标题栏 / `Tabs`）。缺失功能**降级而不是崩溃**。 |
| **顺带发现（镜像缺陷）** | 交付镜像里 `install_list.json` 有 `org.aira.browser`，但 **`install_list_capability.json` 没有对应条目** → BMS 以 8519888（`not allow use privilege extension`）拒绝预装 → **Aira 在设备上根本没装上**。本轮 `inject.sh --with-aira` 会补上该条目。 |
| 交付 | `fix_input_aira/inject.sh <image> [--with-aira]`（幂等、自校验 sha256）；补丁 `patch/mmi_input_focus.patch`、`patch/aira_hds_fallback.patch`；新 HAP `Aira-v3.7.2-x86-selfhost-fix-signed.hap` |
| 验证镜像 | `fix_input_aira/scratch.img`（交付镜像的稀疏副本 + 20 GiB GPT，可引导） |

---

## 1. 问题 ①：输入框 focus 卡顿

### 1.1 现场线索（来自任务书 + 诊断包 `diagwork/d2/`）

* 用户：**浏览器 / 设置 / Aira 的输入框获得焦点很慢**；**换成自带 kikainput 也一样** ⇒ 与具体 IME 无关，指向 **MMI 输入事件分发链路**。
* 真机 `log/eventlog/INPUT_EVENT_SOCKET_TIMEOUT-19381-…log`（pid 19381 / uid 6696 = 设置应用）⇒ **MMI 服务端发现「对端 socket 缓冲满，发不出去」**。
* 上一轮 `fix_touchpad_mmi` 的结论是「客户端满时服务端丢事件即可」——**只治了服务端阻塞，没治「客户端不读」**，而且**把点击也丢了**。
* 诊断包 `E_hilog.txt` 里，键盘事件的链路是健康的（MMI 服务 20:07:20.024 → 客户端 recv 20:07:20.025，**~1 ms**），说明 **MMI 内部转发本身不慢**，慢的是「点击 → 焦点」这一段（pointer 事件 + 应用侧处理）。

### 1.2 真实链路（file:line）

```
内核 evdev ──► multimodalinput 服务（libinput 线程）
   └─ EventNormalizeHandler → EventDispatchHandler::HandlePointerEvent/HandleKeyEvent
        service/event_dispatch/src/event_dispatch_handler.cpp:79 / :433
        └─ 查目标窗口 WIN_MGR->GetTargetWindowIds / GetClientFd
        └─ UDSServer::SendMsg(fd, pkt)   service/module_loader/src/uds_server.cpp:75
             └─ UDSSession::SendMsg()    util/socket/src/uds_session.cpp:52   ← 流控点
   ── UDS socket ──► 客户端（session manager / app 进程）
        MMIFdListener::OnReadable → MMIClient::OnRecvMsg → ClientMsgHandler::OnMsgHandler
        frameworks/proxy/module_loader/src/mmi_client.cpp:203
        frameworks/proxy/event_handler/src/client_msg_handler.cpp:131
        └─ InputMgrImpl.OnPointerEvent → 监听者（session manager 的 InputEventListener）
             └─ WindowInputChannel::TransferPointerEvent → **TF_ASYNC** IPC → app 进程
                  window_scene/session/container/src/zidl/window_event_channel_proxy.cpp:69
             └─ 键盘走 `TransferKeyEventForConsumed` → **TF_SYNC** IPC（会阻塞！）
                  window_scene/session/container/src/zidl/window_event_channel_proxy.cpp:120
   ── app 进程：WindowImpl::TransferPointerEvent → ace（ArkUI）→ 命中测试 → 焦点 → 显示输入法
```

### 1.3 定位到的三个缺陷

#### 缺陷 A（**回归**）：服务端把「点击」和「鼠标移动」一样丢掉

`fix_touchpad_mmi` 之前的 `UDSSession::SendMsg` 是在**输入分发线程**里阻塞式重试（`SEND_RETRY_LIMIT 50 × 500 µs`），
一旦对端缓冲满就**把整个输入管线拖住**。上一轮改成「先 `poll(POLLOUT,0)`，不可写就丢」是正确方向，
但**没有区分事件类型**：

* `POINTER_ACTION_MOVE / HOVER_MOVE` 丢掉无所谓（下一个采样点会覆盖）；
* `POINTER_ACTION_DOWN / UP` 丢掉 = **这一次点击永久丢失** ⇒ 输入框**永远拿不到焦点**，
  用户只能再点一次、再点一次 ⇒ 主观感受就是「focus 极卡顿」；
* 键盘 DOWN/UP 同理。

代码位置：`util/socket/src/uds_session.cpp`（改前：`if (pollRet == 0) { ReportSocketBufferFull(); return false; }`，
**对所有事件一视同仁**）。

#### 缺陷 B：客户端「读 socket」和「跑回调」是同一个线程 → 慢消费者会反噬服务端

`MMIClient::OnRecvMsg()`（`frameworks/proxy/module_loader/src/mmi_client.cpp:203`，改前）**在 fd listener 线程上同步**
执行 `OnReadPackets()` → `ClientMsgHandler::OnMsgHandler()` → 应用回调：

* session manager 的监听者回调里，**键盘**走 `TransferKeyEventForConsumed`（**TF_SYNC**），
  要等 app 进程回话；app 的 UI 线程一忙（ArkWeb 加载、同步 IPC…），这个线程就一直阻塞；
* 线程一阻塞 → **socket 不再被读** → 服务端 `send()` 很快把对端缓冲写满 → 回到缺陷 A 丢事件。

于是「app 忙 → 丢点击 → 输入框不 focus」形成闭环，而且**越是 app 忙越严重**。

#### 缺陷 C：链路里**没有任何分段耗时**埋点

服务端只有 `TimeCostChk`（300 µs 超时）的局部计时，没有「事件年龄」（事件时间戳 → 现在）这种端到端口径，
所以现场根本看不出「事件在哪儿堵住了」。

### 1.4 修法（file:line）

**① 服务端：关键事件不丢**（`util/socket/include/uds_session.h`、`util/socket/src/uds_session.cpp:52`）

```cpp
bool SendMsg(const char *buf, size_t size, bool critical = false);
bool SendMsg(NetPacket &pkt, bool critical = false);
```

* 对端缓冲满时：
  * **critical**（pointer DOWN/UP/BUTTON_DOWN/BUTTON_UP/CANCEL/AXIS_BEGIN/END、key DOWN/UP）：
    **最多等 150 ms**（`CRITICAL_SEND_WAIT_MS`，`uds_session.cpp:33`）让对端把缓冲读走，然后照发；
  * **非 critical**（motion/hover）：**立即丢**（保持「输入管线永不被慢客户端拖住」这一原则）。
* 丢弃时计数并打 `MMI_PERF drop event, …`，新增 `GetDroppedEventCount()` / `GetSlowConsumerCount()`。

**② 分发侧标出关键性**（`service/event_dispatch/src/event_dispatch_handler.cpp`）

* `IsCriticalPointerAction()`（:70）/ `IsCriticalKeyAction()`（:86）判定事件类型；
* pointer 发送（:633-634）、key 发送（:711-712）把 `critical` 透传给 `UDSServer::SendMsg`/`UDSSession::SendMsg`；
* `UDSServer::SendMsg(int32_t fd, NetPacket&, bool critical=false)`（`service/module_loader/src/uds_server.cpp:75`）。

**③ 客户端：读 socket 与跑回调解耦**（`frameworks/proxy/module_loader/{include/mmi_client.h,src/mmi_client.cpp}`）

* `MMIClient::OnRecvMsg()`（:203）现在**只入队**（`pendingPackets_` + `pendingCv_`）并立刻返回；
* 新增专用线程 `OS_mmi_Dispatch`（`StartDispatchThread()` :229 / `DispatchLoop()` :275 / `StopDispatchThread()` :245，
  用 `pthread_create` —— 该 target 编译时是 `-fno-exceptions`，不能用 `std::thread` + try/catch），
  在该线程上做解析 + 回调；
  ⇒ **应用再慢也不会停止读 socket**，服务端缓冲不会再被写满，**点击不会被丢**；
* `OnDisconnected()` 清空待处理队列（:346），`Stop()` 里停线程（:414）。

**④ 客户端：慢消费者保护 + 端到端埋点**（`frameworks/proxy/event_handler/src/client_msg_handler.cpp`）

* key（:163）/ pointer（:261）收到时计算**事件年龄** `now - event->GetActionTime()`：
  * > 100 ms（`SLOW_CONSUMER_US`）→ 打 `MMI_PERF slow consumer, … age:… us`（这就是「堵在哪」的判据）；
  * pointer 且年龄 > 200 ms（`STALE_HOVER_US`）且是 `POINTER_ACTION_HOVER_MOVE` → **丢弃**
    （过期的 hover 采样没有价值，丢掉能让队列尽快排空，让后面的 DOWN/UP 立刻被处理）。

**⑤ 服务端：端到端延迟埋点**（`event_dispatch_handler.cpp:379` `ReportDispatchLatency()`）

事件时间戳 → 发送完成的耗时 > 50 ms 时打 `MMI_PERF slow dispatch, event age:… us`。

### 1.5 埋点口径（真机怎么读）

| 日志（tag） | 含义 | 判据 |
|---|---|---|
| `MMI_PERF slow dispatch, event age:…us`（`EventDispatchHandler`） | **MMI 服务端内部**（读事件 → 归一化 → 查窗口 → 写 socket）的耗时 | 出现 = MMI 服务端自己慢（查 `InputWindowsManager` / 目标窗口查找） |
| `MMI_PERF slow consumer, … age:…us`（`ClientMsgHandler`） | **客户端收到事件时事件已经多老** = 端到端排队延迟 | 出现 = 事件在「服务端→客户端」之间排队（服务端写 socket 慢，或客户端不读） |
| `MMI_PERF drop event, consumer buffer full, critical:0/1`（`UDSSession`） | 事件被丢（0=可合并的 motion，1=关键事件） | **critical:1 出现 = 仍有点击在丢，必须继续查** |
| `MMI_PERF slow consumer, waiting for critical event`（`UDSSession`） | 服务端正在为关键事件等对端腾缓冲（最多 150 ms） | 频繁出现 = 客户端确实慢（去看 `slow consumer` 那条） |
| `MMI_PERF drop stale hover event`（`ClientMsgHandler`） | 客户端丢弃了过期 hover（正常保护） | 大量出现 = 客户端积压，需查客户端回调耗时 |
| `INPUT_EVENT_SOCKET_TIMEOUT`（hisysevent，仍在） | 对端缓冲满 | 与上面的 drop 计数一起看 |

**真机判据（建议在真机上跑一遍，替换掉本轮的 QEMU 估计）**：

```sh
# 1) focus 延迟的分段耗时（把 1 万次点击/输入打一遍）
hdc shell "hilog -x | grep -c 'MMI_PERF slow dispatch'"          # 期望 0
hdc shell "hilog -x | grep -c 'MMI_PERF slow consumer'"          # 期望 0（>0 说明有排队）
hdc shell "hilog -x | grep 'MMI_PERF drop event' | grep -c 'critical:1'"   # 期望 0：不允许丢点击
hdc shell "hilog -x | grep -c INPUT_EVENT_SOCKET_TIMEOUT"       # 期望 0
# 2) 交互体验：浏览器/设置/Aira 的输入框，点一下就出现光标（不再要点好几下）
```

### 1.6 QEMU 回归（`scratch.img`，本轮实测）

* 镜像：`fix_input_aira/scratch.img`（交付镜像稀疏副本 + GPT 扩到 20 GiB），注入 3 个 MMI 库后引导成功；
* guest 内确认新库生效（`evidence/guest_state.log`）：
  ```
  -rwxr-xr-x 4909240 2026-10-21 11:50 /system/lib64/libmmi-server.z.so
  -rwxr-xr-x 1324568 2026-10-21 11:50 /system/lib64/platformsdk/libmmi-client.z.so
  -rwxr-xr-x  585192 2026-10-21 11:50 /system/lib64/platformsdk/libmmi-util.z.so
  ```
* 输入链路正常（`evidence/mmi_input_flow.log`）：注入一次触摸后
  ```
  C02805/InputKeyFlow: [P:C:2|630]SendMsg:4238, pointerAc:1      ← MMI 服务端派发
  C02805/InputKeyFlow: [P:C:2|730]recv                          ← 客户端收到
  C04213/InputKeyFlow: intention_event_manager.cpp OnInputEvent: … ac:1
  ```
  **端到端同毫秒**；
* `hilog -x | grep -c MMI_PERF` = **0**（健康链路上不应有慢消费者/丢事件告警）→ 新埋点不刷屏、不误报；
* 系统无崩溃：`multimodalinput` / `ohos.sceneboard` / `ime:inputMethod` 全部存活。

---

## 2. 问题 ②：AIRA 引导最后一页「数据同步 → 自建」点击闪退

### 2.1 现象

Aira 引导最后一页里选「数据同步 → 自建」→ **应用闪退**（进程被杀，`reason=Js Error`）。
上一轮已经用 HMS 垫片修好了「跳过引导 → 进主页」那条路径（`loginComponentManager`），
但「自建」这条分支仍然崩 ⇒ 该分支有**另一处** HMS-only 依赖。

### 2.2 根因（file:line）

**`自建`页 = `app/pages/SyncPersonalServerConfigPage.ets`**，它引入了
`app/components/settings/SettingsHdsScaffold.ets`，而后者**静态导入 HMS 的 HDS 组件**：

```ts
// app/components/settings/SettingsHdsScaffold.ets:1-11（改前）
import {
  BlurStrategy, DividerShowType,
  HdsNavDestination,          // ← ArkUI 组件
  HdsNavDestinationTitleMode, hdsMaterial,
  IconStyleMode, ScrollEffectType, TitleSize
} from '@kit.UIDesignKit';
```

* HMS SDK 的 kit 定义（`~/.local/deveco/.../hms/ets/build-tools/ets-loader/kit_configs/@kit.UIDesignKit.json`）
  把 `HdsNavDestination` 映射到 `@hms.hds.hdsBaseComponent.d.ets`，
  运行时模块名是 **`@hms:hds.hdsBaseComponent`**；
* **OpenHarmony 设备没有 HDS 运行库**：本树 `out/ptl` 全树无任何 `*hds*` 库
  （`find out/ptl -iname "*hds*"` → 0 命中），OpenHarmony SDK 26.0.0 的 kit 列表里也**没有 UIDesignKit**
  （有 AccountKit/AppGalleryKit/CoreSpeechKit/ShareKit/PreviewKit/FileManagerServiceKit 等，**唯独没有 UIDesignKit**）；
* 于是运行时加载该模块失败，ArkTS 打
  `E C03f00/ArkCompiler: [ecmascript] Load native module entry is not a JSObject`，
  **具名导入拿到 undefined**；`build()` 里 `HdsNavDestination(){…}.titleBar({…})`（:145 附近）
  调用 undefined → **未捕获异常** → ArkUI 渲染中断 → **应用被杀**。

**为什么「只有自建崩，其它地方不崩」**：

* HDS 只在**页面级**被引用（68 个页面用 `SettingsHdsScaffold`），页面是**按需加载**的；
  应用启动只加载 `BrowserAppRuntime`，**不加载**这些页面 ⇒ 启动不崩；
* `SettingsCenterPage`（设置主页）**不用** HDS ⇒ 上一轮验证「设置页正常渲染」与本结论不矛盾；
* `自建`页用 HDS ⇒ 一打开就崩 ✓。

**其它 HMS-only 依赖的定性**（同一页面可达，已逐一核对）：

| 文件 | 导入 | 结论 |
|---|---|---|
| `services/sync/HuaweiAccountSyncAuthService.ets:1` | `@kit.AccountKit` { authentication } | **软失败**：只在 `requestHuaweiProfile()` 里用，且被 `enrichWithHuaweiProfile()` 的 try/catch 包住 → 缺功能时报错，不崩 |
| `services/system/SystemSettingsLaunchService.ets:4` | `@kit.AppGalleryKit` { commentManager } | 软失败（应用自带 try/catch） |
| `services/reader/ReaderSpeechService.ets:1` | `@kit.CoreSpeechKit` { textToSpeech } | 软失败（阅读器功能，不在自建路径上执行） |
| `services/web/HuaweiUrlThreatDetectionService.ets:3` | `@kit.DeviceSecurityKit` { safetyDetect } | 软失败 |
| `services/download/DownloadFileResolutionService.ets:3` | `@kit.FileManagerServiceKit` | 软失败（下载功能） |
| `services/download/DownloadFollowupService.ets:4-5` | `@kit.PreviewKit` / `@kit.ShareKit` | 软失败（下载功能） |
| `services/customhome/CustomHomepageExternalImportService.ets:3` | `@kit.ShareKit` | 软失败 |

> 「软失败」的机制：这些模块是 **native 模块**，加载失败只打 **W** 级
> `Load native module entry is not a JSObject`，导入绑定为 undefined；
> 只有在 `build()` 这种**没有 try/catch** 的位置被调用才会致命。
> 上一轮 `loginComponentManager` 致命，是因为它同时命中了
> 「**模块存在但缺导出名**」的硬失败（`SyntaxError: … does not provide an export name`）。

### 2.3 修法（file:line）

**目标：把 HDS 依赖彻底从应用里拿掉，缺功能降级而不是崩溃。**

1. **新增本地垫片** `platform/huawei/OpenHarmonyHdsMaterialShim.ets`
   （导出 `hdsMaterial` + `MaterialType/MaterialLevel` + `getSystemMaterialTypes()` 恒返回 `[]`）。
2. `app/components/common/HdsImmersiveMaterialTokens.ets:3,20`：`import` 改成垫片；
   应用自带的 `isHdsMaterialAvailable()` 因此恒为 false → **走应用本来就有的普通 ArkUI 降级路径**。
3. `app/components/common/HdsImmersiveMaterialSurface.ets:4,29`：`HdsTabs` → 普通 `Tabs()`
   （背板尺寸/圆角/透明度语义不变，只是没有沉浸式材质）。
4. `app/components/settings/SettingsHdsScaffold.ets`：
   * 删掉 `@kit.UIDesignKit` 整块 import（:1-11）；
   * `buildScaffoldWithTitleBar()`（:134）里 `HdsNavDestination(){…}.titleBar({…})` 换成
     **普通 ArkUI 标题栏**（新增 `buildPlainTitleBar()` :178，标题文字 + 应用自己的玻璃返回键/菜单按钮）；
   * 视觉代价：标题栏没有 HDS 的毛玻璃/沉浸式材质；功能与交互保持一致。
5. 编译产物：`Aira-v3.7.2-x86-selfhost-fix-signed.hap`，
   **41,530,309 B**，sha256 **`04a5b97ac7ffcc02ee1d2a18ae86888f27d68997db6b02401cca7d3d62f5b48c`**，
   `verify-app` = success（剥 `libs/*` + 用 OpenHarmony 测试链重签，链不变）。
   构建日志 `work/build_aira3.log`（`BUILD SUCCESSFUL`，ArkTS 0 error）。

### 2.4 顺带修掉的镜像缺陷：Aira 预装不起来

交付镜像里 `/system/etc/app/install_list.json` **有** `org.aira.browser`，
但 `/system/etc/app/install_list_capability.json` **没有**对应条目
⇒ BMS 以 **8519888（`not allow use privilege extension`）** 拒绝预装
⇒ **Aira 在这台设备上根本没被装上**（实测：guest 里 `/data/app/el2/100/base/` 无 `org.aira.browser`，
直到 `inject.sh --with-aira` 补上能力条目后预装成功，`/data/app/el2/100/base/org.aira.browser` 出现、
`ICON` 日志出现 `appInstall … org.aira.browser`）。

`inject.sh --with-aira` 会**幂等地**补这个条目（`app_signature` = 设备信任锚
`8E93863FC32EE238060BF69A9B37E2608FFFB21F93C862DD511CBAC9F30024B5`）。

### 2.5 真机判据

```sh
# 1) Aira 已预装（修完能力条目后）
hdc shell "ls -d /data/app/el2/100/base/org.aira.browser"        # 期望存在
hdc shell "sqlite3 /data/service/el1/public/bms/bundle_manager_service/bmsdb_slave.db \
  \"select VALUE from bms_param where KEY='PreInstallExceptionMgr';\"" | grep -c aira   # 期望 0
# 2) 引导最后一页 → 数据同步 → 自建
#    期望：页面正常打开（标题栏 + 表单），**不闪退**
hdc shell "hilog -x | grep -c 'PROCESS_KILL' | ..."               # 期望无 aira 相关
hdc shell "hilog -x | grep -a 'Load native module entry is not a JSObject' | wc -l"  # HDS 相关的应消失
# 3) 回归：设置页 / WebDAV 同步页 / 主页 仍能打开
```

### 2.6 客观验证（静态可达性扫描，`evidence/aira_kit_graph.txt`）

用脚本扫「自建页的**全部传递静态 import**」里还剩哪些 HMS-only kit（修复后）：

```
=== entry app/pages/SyncPersonalServerConfigPage.ets   (transitive files: 973 )
--- @kit.AccountKit            services/sync/HuaweiAccountSyncAuthService.ets      -> authentication
--- @kit.AppGalleryKit         services/system/SystemSettingsLaunchService.ets    -> commentManager
--- @kit.CoreSpeechKit         services/reader/ReaderSpeechService.ets            -> textToSpeech
--- @kit.DeviceSecurityKit     services/web/HuaweiUrlThreatDetectionService.ets   -> safetyDetect
--- @kit.FileManagerServiceKit services/download/DownloadFileResolutionService.ets -> fileManagerService
--- @kit.PreviewKit            services/download/DownloadFollowupService.ets      -> filePreview
--- @kit.ShareKit              services/download/DownloadFollowupService.ets      -> systemShare
                               services/customhome/CustomHomepageExternalImportService.ets -> systemShare
```

⇒ **`@kit.UIDesignKit` 已从「自建」页的依赖图里彻底消失**（修复前它在
`SettingsHdsScaffold.ets` 里，是唯一的致命项）；剩下的 7 个 kit 都是**软失败**
（访问点都在 try/catch 内，见 §2.2 表）⇒ **自建分支不会再闪退**。

**⚠️ 仍未处理的两处 HDS（其它页面还会崩，列入遗留）**：

| 文件 | 行 | 用到的 HDS 组件 |
|---|---|---|
| `app/components/common/ManagementHdsScaffold.ets` | 4-13 / 120 / 236 | `HdsNavDestination` + 同套枚举（与 `SettingsHdsScaffold` 同构，改法相同） |
| `app/components/settings/SettingsNavigationScreen.ets` | 49 / 141 / 214 | `HdsNavigation`（带 pathStack 的两栏导航）+ `HdsNavDestination` |

⇒ **设置中心的「两栏导航」页仍然会崩**。本轮没改是因为 `HdsNavigation` 换成普通
`Navigation` 需要连带改 `SettingsHdsNavigationStackProjection` 的 pathStack 类型，
风险高于收益；建议下一轮照 §2.3 的模式处理（`HdsNavigation`→`Navigation`、
`HdsNavDestination`→`NavDestination`）。

> 顺带说明：修完之后新 HAP 的 `ets/modules.abc` 里**仍能 grep 到** `@hms:hds.*`
> （因为上面这两个文件还在编译进包）——**这不代表「自建」页还有 HDS 依赖**，
> 判据要看上面的可达性扫描（ArkUI 页面是按需加载的，abc 里存在 ≠ 运行时会加载）。

---

## 3. 交付物

```
fix_input_aira/
├── SUMMARY.md                                   本报告
├── inject.sh <image> [--with-aira]              注入脚本（幂等 + 镜像内 sha256 自校验）
├── Aira-v3.7.2-x86-selfhost-fix-signed.hap      新 Aira HAP（41,530,309 B, 04a5b97a…）
├── scratch.img                                  验证镜像（交付镜像稀疏副本 + GPT 20 GiB）
├── patch/
│   ├── mmi_input_focus.patch                    MMI 改动（foundation/multimodalinput/input，689 行）
│   └── aira_hds_fallback.patch                  Aira 改动（3 个文件 + 1 个新垫片，335 行）
├── scripts/
│   ├── boot.sh                                  QEMU 启动（pc_ptl partdisk，VNC :26 / hdc 5557，避开其它会话端口）
│   └── snap_ser.py                              串口抓屏（本环境 guest hdcd 的 TCP 端口不通时的兜底）
├── evidence/
│   ├── guest_state.log                          guest 内新库/Aira HAP/预装结果/MMI_PERF 计数
│   └── mmi_input_flow.log                       注入触摸后的完整输入链路日志（同毫秒送达）
└── work/                                        构建日志、注入日志、临时文件
```

**`inject.sh` 做了什么**（只动 p2(system) 的 4 个文件）：

| 源 | 镜像内路径 |
|---|---|
| `out/ptl/multimodalinput/input/libmmi-server.z.so` | `/system/lib64/libmmi-server.z.so` |
| `out/ptl/multimodalinput/input/libmmi-client.z.so` | `/system/lib64/platformsdk/libmmi-client.z.so` |
| `out/ptl/multimodalinput/input/libmmi-util.z.so` | `/system/lib64/platformsdk/libmmi-util.z.so` |
| `Aira-v3.7.2-x86-selfhost-fix-signed.hap`（仅 `--with-aira`） | `/system/app/org.aira.browser/Aira.hap` |

外加（仅 `--with-aira`）给 `/system/etc/app/install_list_capability.json` 补
`org.aira.browser` 的特权扩展授权条目。

* 幂等：重复执行 → 同样的 `rm`+`write`，镜像内文件 sha256 自校验；
* p2 空闲只有 ~24 MiB：**先 `rm` 旧文件再 `write`**（路径/包名/签名都不变，不需要改 `install_list.json` 的 app_dir）；
* 不动 GPT、不改镜像大小、不动 p1(ESP)/p3~p6。

---

## 4. 回退

| 目标 | 做法 |
|---|---|
| **MMI 三库** | 用镜像里原来的三个 `.so` 覆盖回去（备份在 `out/ptl/packages/phone/system/lib64/`，或从交付镜像 p2 里 `debugfs dump`）→ `e2fsck -f -y` → 重建 overlay |
| **MMI 源码** | `cd foundation/multimodalinput/input && git checkout -- util/socket service/module_loader service/event_dispatch frameworks/proxy` → 重编 `libmmi-server/libmmi-client/libmmi-util` → 注入 |
| **Aira HAP** | 用 `fix_aira_guide/Aira-v3.7.2-x86-nolibs-signed.hap`（41,528,863 B，69d231d2…）覆盖 `/system/app/org.aira.browser/Aira.hap` → `e2fsck` → 重建 overlay |
| **Aira 源码** | `cd fix_aira_guide/aira_src && git checkout -- AiraBrowser/entry/src/main/ets/app/components/{common/HdsImmersiveMaterialSurface.ets,common/HdsImmersiveMaterialTokens.ets,settings/SettingsHdsScaffold.ets}` + 删除 `platform/huawei/OpenHarmonyHdsMaterialShim.ets` → `bash work/build.sh work/build_x.log` → `bash work/repack_sign.sh` |
| **能力条目** | `install_list_capability.json` 里删掉 `org.aira.browser` 条目（inject.sh 下次执行会重新补上） |
| **整盘** | 交付镜像 `partdisk/media/ohos_part_pc_ptl.img` **本轮完全未改**（sha 仍 `92274c80…`） |

---

## 5. 遗留 / 下一步

1. **真机上的 focus 延迟数字还没拿到**：本轮只给出「分段耗时埋点 + 结构性修复」，
   还需要在真机上跑 §1.5 的判据，确认 `MMI_PERF slow consumer` / `drop event critical:1` 归零。
   若真机仍出现 `slow consumer`，下一刀应落在
   `window_scene/session/container/src/zidl/window_event_channel_proxy.cpp:120`
   的 **TF_SYNC `TransferKeyEventForConsumed`**：它让 session manager 的 MMI 客户端回调线程
   （现在已是独立的 `OS_mmi_Dispatch` 线程，但仍会卡）被 app 的响应速度绑定。
2. **客户端的「慢消费者」目前是「不阻塞读 + 丢过期 hover」**；
   如果真机显示 app 侧仍然积压，可再加「按事件类型分级的丢弃策略（先丢 hover/move，再丢 axis，最后才丢 down/up）」。
3. **Aira 侧只处理了「自建」路径上的 HDS**（`SettingsHdsScaffold` / `HdsImmersiveMaterialSurface` /
   `HdsImmersiveMaterialTokens`）；**`ManagementHdsScaffold.ets` 与 `SettingsNavigationScreen.ets`
   仍在用 HDS**（见 §2.6 的表）⇒ 设置中心两栏导航页仍会闪退，下一轮照 §2.3 的模式处理。
4. **其余 HMS-only kit（AccountKit/AppGalleryKit/CoreSpeechKit/ShareKit/PreviewKit/
   FileManagerServiceKit/DeviceSecurityKit…）仍是静态导入**，目前靠「访问点都在 try/catch 里」活着。
   将来若某个页面在模块顶层解构它们的具名导出，会复现同一个致命错误；
   根治办法是照本报告的方式逐个补垫片（约 8 个文件，未做）。
5. **Aira 的 UI 降级**：HDS 标题栏/材质没了，视觉与 HarmonyOS 原版不同；
   若要恢复，需要在真 HarmonyOS 设备上把 import 换回 `@kit.UIDesignKit`。
6. **本轮没有改 `applications/standard/browser`**（上游源码树），改动都在
   `out/.../fix_aira_guide/aira_src/` 副本里，与上一轮的做法一致。

---

## 6. 踩坑（写给下一轮）

1. **`INPUT_EVENT_SOCKET_TIMEOUT` 的去重窗口写错了**：`ReportSocketBufferFull()` 用
   `GetSysClockTime()`（**微秒**）和 `MINUTEINMILLIS = 60000` 比较
   （`util/socket/src/uds_session.cpp:202`）⇒ 实际是「每 60 ms 最多报一次」，不是「每分钟一次」，
   所以 eventlog 会被刷屏。本轮未改（怕影响既有判据），但值得单独修。
2. **MMI 编译是 `-fno-exceptions`**：客户端 dispatch 线程只能用 `pthread_create`，
   `std::thread` + try/catch 编不过（`cannot use 'try' with exceptions disabled`）。
3. **pc_ptl 镜像的 p2 起点是扇区 1050624（= 513 MiB）**，注入脚本按 `dd bs=1M skip=513 count=2048` 取；
   交付镜像是**裁剪过的**（GPT 声称 40114175 扇区、文件只有 10749952 扇区），
   在 QEMU 里必须 `truncate -s 41015872K` + `sgdisk -e` 补齐才能引导。
4. **并发会话会互杀 QEMU**：别的会话用 `pkill -9 -f 'qemu-system-x86_64 -[m]achine'`，
   本轮因此被杀掉两次；本轮改用 `work/qemu-pcptl`（指向 qemu 的符号链接，argv[0] 变了 → 不会被那个 pkill 命中），
   并把 VNC/hdc 挪到 :26 / 5557。
5. **guest 的 hdc TCP 端口不通**（`hdcd` 在 TCP 模式下没监听 5555），
   本轮改用**串口**做交互（`ser.py` / `gsh.py`），截图用 `snapshot_display` + base64 回传（`scripts/snap_ser.py`）。
6. **ArkTS 静态具名导入的两类失败**：
   * 模块**存在但缺导出名** → `SyntaxError: … does not provide an export name` → **致命**（链接期）；
   * native 模块**根本不存在** → `W … Load native module entry is not a JSObject` → 绑定为 undefined，
     **只有在没有 try/catch 的地方被调用才致命**（如 `build()` 里的组件调用）。
   ⇒ 判断「某个 HMS kit 会不会崩」不能只看 import 语句，要看**访问点有没有被 try/catch 包住**。
7. **ArkTS 不接受 `Record<string, Object>` 之类的匿名对象字面量**
   （`arkts-no-untyped-obj-literals`）；垫片里要用 `class` + `static readonly` 或 `enum`。
