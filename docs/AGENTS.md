# OHOS x86_64_virt 图形/输入调试记录

> 本文件是跨会话交接资料。会话上下文压缩后，先读本文件再动手，避免重复分析。
>
> **📌 现状总览（2026-09-22 最终）请看 `out/x86_64_virt/ohos-dbg/PC_DESKTOP_STATUS.md`**
> （怎么用 / 镜像里有什么 / 已解决什么 / 已知限制 / 怎么回退）。
>
> **新会话先看这里**：**任务栏式 PC 桌面已达成**（2026-09-22 晚，见 **第 16 节**）。
> 关键：预装的 SceneBoard 是**手机产品版**（`phone_sceneboard`），PC 桌面要用
> **PC 产品版 `pc_sceneboard`** —— 它不在开源 manifest（PR #2660/#2661 未合入）、也没有
> 预编译 HAP，**必须自己用 hvigor 从 `window_scene_board`（7.0-Release 分支）源码构建**后注入。
> 效果：任务栏（应用中心/运行应用/时间/通知）+ 自由窗口（最大化/最小化/关闭）+ 桌面图标，
> `pcService` / `isDragFromSideBar` / `pc_mode_gridlayout` 等报错**全部 0 次**。
> 体验用 **`scripts/run_gl_vnc.sh`**（VNC `127.0.0.1:24`，**1280x800**，鼠标用相对设备才动，见 **16.5**）；
> `run_gl_gtk.sh` 是本地 GTK 窗口但只有 640x480。
> 前置仍需：① 两处 RS 平台修复（**12.1**）；② Mesa 25.0.1 + image loader（**13/14**）；
> ③ virgl 回传 + 行序翻转（**14/15**）；④ 防休眠注入 + 触摸解锁（**13**）；
> ⑤ QEMU 必须 `virtio-gpu-gl-pci`（3D）。
> 上一阶段**分离架构 + 2in1 + 移植社区 pad/pc HAP**（平板式 UI）见 **第 11 节**。
> 操作硬性约定（**禁止写 /tmp**、~290s 超时、长任务后台+日志、
> **不要在 QEMU 运行时跑全量构建**、**对话必须用中文**）见 **第 0 节**。

## 0. 操作约定（Agent 必须遵守）

这些是用户明确要求的硬性约定，违反会造成内存占用或任务中断：

0. **必须说中文**（用户 2026-09-21 明确要求）。所有回复、提问、以及选项文字一律用中文，
   禁止英文（代码/命令/日志/文件路径除外）。

1. **禁止把工作文件写到 `/tmp`**。`/tmp` 是 tmpfs（占内存）。
   所有临时/调试产物（日志、脚本、overlay 镜像、截图）统一写到项目 `out` 目录下：
   - 统一目录：`out/x86_64_virt/ohos-dbg/`（`scripts/`、`evidence/`、`dbg/`、`run/`）
   - 构建日志：`out/x86_64_virt/ohos-dbg/<name>.log`
   - `/tmp/opencode/` **已清空**（3.1G → ~0.5M，仅剩无关历史 config）。
     所有脚本/overlay/截图已迁到 `out/x86_64_virt/ohos-dbg/`，新文件一律写 `out`。

2. **不要在 QEMU 运行时跑 `--jobs 16` 全量构建**（2026-09-20 踩坑：同时开 QEMU(4GB)+
   `--jobs 16` 全量重建，把 30GB 内存/CPU 打满，导致桌面卡死、opencode 崩溃、构建中断）。
   全量重建请先 `pkill -f qemu-system-x86_64`，并用 **`--jobs 8`**。
3. **单条命令有 ~300 秒超时限制**。任何可能超过 300s 的命令（全量/大增量构建、
   e2fsck、长时间抓日志、QEMU 启动等待）**不要直接前台跑**，二选一：
   - **起后台进程 + 日志落盘**，让用户自己 `tail -f` 监控：
     ```sh
     nohup <cmd> >> out/x86_64_virt/<name>.log 2>&1 &
     echo "pid $!"
     ```
     然后分段 `sleep` + `tail` 检查，不要一次 `sleep` 超过 300s。
   - 或**直接告诉用户手动执行**，并给出完整命令。

4. 简短命令（编译单库、debugfs 注入、grep、截图）可照常前台执行。

## 1. 环境与目标

- 源码根：`/home/katax/Public/OHOS`（OpenHarmony 源码树，非 git 根；各子仓独立 git）
- 产品：`x86_64_virt`，设备 `device/qemu/x86_64_virt`，product path `vendor/ohemu/qemu_x86_64_linux_full`
- 架构：`window_manager_use_sceneboard = false`（**分离架构**：`wmserver/` + `dmserver/`，不是 window_scene 合一架构）
- 运行：QEMU x86_64，KVM，VNC `:24`（端口 5924），串口 unix socket，QMP unix socket
- `sceneboard.config` 未安装（因为 use_sceneboard=false），SELinux 为 permissive
- 目标：让 QEMU guest 图形桌面可用 + 输入（鼠标/触摸）可用

## 2. 构建

主机 Ruby 4 移除了旧 ERB 签名，必须加 RUBYOPT 包装。
另外 HAP 打包（Hvigor）需要 Java，**当前主机 `JAVA_HOME` 指向已失效的
`/snap/android-studio/236/jbr`**（snap 已升级到 242），会导致
`hvigor ERROR: spawn java ENOENT`、所有 `*_hap.stamp` 失败。构建前必须覆盖：

```sh
cd /home/katax/Public/OHOS
export RUBYOPT="-r$PWD/build/compat/erb_compat.rb"
export JAVA_HOME=/home/katax/.gradle/jdks/jetbrains_s_r_o_-17-amd64-linux.2
export PATH="$JAVA_HOME/bin:$PATH"   # java -version 应为 17.x

# 全量/目标构建（增量，已确认可用）
./build.sh --product-name x86_64_virt --ccache --jobs 16 --keep-ninja-going \
  --gn-args linux_kernel_version='"linux-6.18"' --deps-guard=false \
  --build-target libwms --build-target libmmi-server --build-target libmmi-client

# PC(2in1) 全量构建：额外加 --device-type 2in1
# nohup ./build.sh --product-name x86_64_virt --ccache --jobs 16 --keep-ninja-going \
#   --device-type 2in1 --deps-guard=false \
#   --gn-args linux_kernel_version='"linux-6.18"' \
#   > out/x86_64_virt/ohos-dbg/build-pc2in1.log 2>&1 &
```

- 直接用 `prebuilts/build-tools/linux-x86/bin/ninja -C out/x86_64_virt <target>` 会报
  `multiple rules generate ...Contacts_DataAbility.stamp`，**必须走 build.sh**。
- 三个库产物：
  - `out/x86_64_virt/window/window_manager/libwms.z.so`
  - `out/x86_64_virt/multimodalinput/input/libmmi-server.z.so`
  - `out/x86_64_virt/multimodalinput/input/libmmi-client.z.so`
- 增量单个 target 约 45s~3min。
- `libwms` = 窗口服务（含 `MultimodalInputConnectManager` 客户端连接的消费方）
- `libmmi-server` = MMI 服务端（`ServerMsgHandler`、`InputWindowsManager`）
- `libmmi-client` = MMI 客户端代理层（`InputManagerImpl`、`MultimodalEventHandler`、`MultimodalInputConnectManager`）

## 3. 把改动的 .so 注入镜像（关键工作流）

镜像：`out/x86_64_virt/packages/phone/images/system.img`（ext4，库在 `/system/lib64/`）。
`libwms.z.so`/`libmmi-server.z.so`/`libmmi-client.z.so` 都在 `/system/lib64/`。

脚本 `out/x86_64_virt/ohos-dbg/scripts/inject_libs.sh`（内容：`rm` 再 `write`，因为 debugfs 不允许覆盖）：

```sh
IMG=/home/katax/Public/OHOS/out/x86_64_virt/packages/phone/images/system.img
OUT=/home/katax/Public/OHOS/out/x86_64_virt
{
  echo "rm /system/lib64/libwms.z.so"
  echo "write $OUT/window/window_manager/libwms.z.so /system/lib64/libwms.z.so"
  echo "rm /system/lib64/libmmi-server.z.so"
  echo "write $OUT/multimodalinput/input/libmmi-server.z.so /system/lib64/libmmi-server.z.so"
  echo "rm /system/lib64/libmmi-client.z.so"
  echo "write $OUT/multimodalinput/input/libmmi-client.z.so /system/lib64/libmmi-client.z.so"
} | debugfs -w "$IMG"
```

注意：`write` 到已存在文件会报 `Ext2 file already exists` 且**静默不写入**，必须 `rm` 先行（脚本已处理）。

注入后必须 fsck + 重建 qcow2 overlay：

```sh
cd out/x86_64_virt/packages/phone/images && e2fsck -f -y system.img   # ~40-60s（起后台或告知用户）
rm -f out/x86_64_virt/ohos-dbg/dbg/system.qcow2
qemu-img create -f qcow2 -b /home/katax/Public/OHOS/out/x86_64_virt/packages/phone/images/system.img -F raw out/x86_64_virt/ohos-dbg/dbg/system.qcow2
```

> qcow2 overlay **会遮蔽 backing file 的新改动**。每次改 system.img 后必须重建 overlay，否则跑的还是旧库。

## 4. 运行 QEMU

脚本 `out/x86_64_virt/ohos-dbg/scripts/launch_diag.sh`：
- machine q35, accel kvm, smp 4, mem 4096
- `-device virtio-gpu-pci`、`-device virtio-multitouch-pci`、`-device virtio-keyboard-pci`
- **`-device qemu-xhci -device usb-tablet`**（关键：给 VNC 提供绝对定位指针设备）
- `-vnc 127.0.0.1:24`
- 串口/QMP socket 在 `out/x86_64_virt/ohos-dbg/run/`（`ser.sock`、`qmp.sock`）
- 磁盘用 `out/x86_64_virt/ohos-dbg/dbg/{updater,system,vendor,sys_prod,chip_prod,userdata}.qcow2`
- 内核参数 `linux_kernel_version=linux-6.18`，root=/dev/ram0，各 mount 到 /usr /vendor /sys_prod /chip_prod /data

启动：

```sh
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
rm -f $BASE/run/ser.sock $BASE/run/qmp.sock
setsid bash -c "$BASE/scripts/launch_diag.sh" > $BASE/qemu.log 2>&1 < /dev/null & disown
# 约 90~120s 出现串口 shell 提示符 "\n# "
```

注意：`bash tool` 里带 `&` 前后台经常会触发 120s 超时；用 `setsid ... & disown` + `sleep` 分段更稳。

## 5. 串口/HILOG 取证（坑很多）

- 串口是 **kernel console + shell 共用**，输出里混着大量 `audit:`、`LoopEvent`、`APPSPAWN`、`access_token` 噪声。
- 用 `out/x86_64_virt/ohos-dbg/scripts/ser_cmd.py "命令" [等待秒]` 发单条命令；复杂多命令会被 shell 折行打断（终端宽度），
  **技巧：把脚本 base64 后 `echo <b64> | base64 -d > /data/x.sh; sh /data/x.sh`**。
- hilog 环形缓冲约 5000 行，**启动 2 分钟后早期 DIAG 就被冲掉**。取早期日志要在 shell 一出现就 `hilog -x > /data/x`。
- 可用 `hilog -r` 清缓冲；`hilog -b I/D` 调级别（调 D 会刷屏，慎用）。
- 日志标签：
  - `C04200/InputMonitor`：WMS 的 `InputWindowMonitor`
  - `C02800/InputManagerImpl`、`C02800/MMIClient`、`C02801/MultimodalEventHandler`：MMI 客户端
  - `C02801/ServerMsgHandler`：MMI 服务端收包
  - `C02803/InputWindowsManager`：MMI 窗口/坐标管理
  - `C02801/MMIService`：MMI 服务主流程
- 输入测试：VNC 只发 PS/2 相对鼠标（event4），**不驱动 virtio-multitouch**。触摸需另走 QMP/evdev。
  `out/x86_64_virt/ohos-dbg/scripts/` 下有现成 `vnc_swipe.py`、`input_test.py`、`boot_capture.py`。
- 截图：`qmp screendump`（脚本内已有），PPM 存 `out/x86_64_virt/ohos-dbg/`；比对像素变化判断 UI 是否响应。

## 6. 输入链路与已确认根因

链路：`display_manager(3308) → DMS(4607) → WMS(4606) → IPC DISPLAY_INFO → MMI(3101)`。
WMS 通过 `MMI::InputManager::GetInstance()->UpdateDisplayInfo(userScreenInfo)` 把屏幕信息发给 MMI，
MMI 用它在 `InputWindowsManager` 里做坐标映射，`DisplaysInfo` 为空则丢事件（日志 `DisplaysInfo is empty` / `MouseTransformProcessor: No display`）。

### 6.1 真正根因（已修复）

不是 WMS 不推，而是 **WMS 进程内的 MMI 连接管理器启动竞态一次性建连失败后永不重试**：

- `MultimodalInputConnectManager` 单例在构造时调用一次 `ConnectMultimodalInputService()`
- 它用 `CheckSystemAbility(3101)`（**非阻塞**），display CREATE 早于 MMI SA 发布 → 拿 null
- 之后每次 `MMIClient::Socket() → AllocSocketPair()` 都在 `CHKPR(multimodalInputConnectService_)` 返回 -1
- 原有唯一重连循环 `NotifyDeath()` 只在“已连接后服务死亡”时触发，**初始失败不会重试**

修复前证据：
```
InputMonitor: displayInfos size:1                                   ← WMS 数据正常
InputManagerImpl: Failed to initialize MMI client                   ← 断点
MultimodalInputConnectManager: is null, return value is -1
MMIClient: Call AllocSocketPair return -1 / Client startup failed
MultimodalEventHandler: The client fails to start
```
→ MMI `ServerMsgHandler::OnDisplayInfo` 从未被调用 → `DisplaysInfo` 永远空。

### 6.2 已实施的修复（当前工作区改动）

**Fix A — MMI 连接管理器懒重连**（`foundation/multimodalinput/input`）：
- `service/connect_manager/include/multimodal_input_connect_manager.h`
  新增 `bool ConnectMultimodalInputServiceLocked();`
- `service/connect_manager/src/multimodal_input_connect_manager.cpp`
  - `AllocSocketPair()`（约 line 62）：若 `multimodalInputConnectService_ == nullptr` 则先
    调 `ConnectMultimodalInputServiceLocked()` 重连，日志 `Connect service not ready, retry`
  - `ConnectMultimodalInputService()`（约 line 735）拆成加锁薄封装 + `...Locked()` 实现
  - `...Locked()` 里 `iface_cast` 失败时回滚 death recipient，保证状态一致

**Fix B — WMS 在 MMI SA 上线时重推 display info**（`foundation/window/window_manager`）：
- `wmserver/src/window_manager_service.cpp::OnAddSystemAbility()`
  `case MULTIMODAL_INPUT_SERVICE_ID:` 在 `windowRoot_->NotifyMMIServiceOnline()` 后，
  遍历 `DisplayGroupInfo::GetInstance().GetAllDisplayIds()` 调
  `inputWindowMonitor_->UpdateInputWindowByDisplayId(displayId)` 重推
- 新增 include `"display_group_info.h"`

所有临时 DIAG 日志已回退。最终 diff：
- MMI：`multimodal_input_connect_manager.{h,cpp}`（24 insertions, 4 deletions）
- WMS：`wmserver/src/window_manager_service.cpp`（11 insertions）

### 6.3 修复验证（已通过）

干净重建 + 注入 + 启动后：
```
DISPLAY_EMPTY=0   # 无 "DisplaysInfo is empty"
CLIENT_FAIL=0     # 无 "The client fails to start"
INIT_FAIL=0       # 无 "Failed to initialize MMI client"
```
杀 MMI 让它重启后，WMS 重推成功，MMI server 侧确认收到：
```
ServerMsgHandler: OnDisplayInfo RECEIVED
ServerMsgHandler: parsed screens:1 groups:1
ServerMsgHandler: groupId:0 displays:1
```

## 7. 进行中的任务 / 未完成

### 7.1 【已修复】WMS 未给 MMI WindowInfo 填 displayId（分离架构专有 bug）

**根因**：分离架构下 WMS 构造 `MMI::WindowInfo` 时**没有设置 `displayId`**，该字段默认 `-1`
（`DEFAULT_DISPLAY_ID`）。MMI 收到后凡是按 `windowInfo.displayId` 查物理屏的地方都拿到 -1，
于是 `GetPhysicalDisplay(-1)` 返回 null：
```
C02803/InputWindowsManager: [|9180]Failed to obtain physical(-1) display
C02803/InputWindowsManager: [|1548]CHKPR(displayInfo) is null, return value is 0
```
调用点：`event_dispatch_handler.cpp:255`（`HandleMultiWindowPointerEvent` 里
`WIN_MGR->GetPhysicalDisplay(windowInfo->displayId)`）。这会让坐标变换走空路径、事件无法正确投递。

对比：合一架构 `window_scene/session_manager/src/scene_session_dirty_manager.cpp:988`
是显式 `.displayId = displayId, .groupId = ...`，所以 sceneboard 路径没这个问题。

**修复**：`foundation/window/window_manager/wmserver/src/input_window_monitor.cpp`
`TraverseWindowNodes()` 里的 `MMI::WindowInfo` 初始化列表补
`.displayId = static_cast<int32_t>(windowNode->GetDisplayId()),`
（`groupId` 默认 0 = `DEFAULT_GROUP_ID`，本就是单组，无需改）。

**验证**：重编 libwms、注入、启动后：
```
PHYS_FAIL=0     # 无 "Failed to obtain physical"
DISP_EMPTY=0    # 无 "DisplaysInfo is empty"
CHKPR_NULL=0    # 无 "CHKPR(displayInfo) is null"
```
另外鼠标移动现在真的驱动了光标：两张截图（鼠标移到左上 vs 右下）差异 258 像素，
而静止基线噪声为 0，说明光标随输入重绘并移动。

### 7.2 【已完成】端到端输入验证通过（触摸注入解锁成功）

**结论：输入链路彻底打通**。用 guest 内 `/system/bin/sendevent` 直接写
`/dev/input/event1`（QEMU Virtio MultiTouch）注入多点触摸协议 B 手势，成功把锁屏
“上滑解锁”划开，进入桌面/Launcher（截图确认：相机/备忘录/软件更新/计算器/音乐/时钟 + Dock）。

关键日志（一次完整滑动）：
```
C02805/InputKeyFlow: [P:D:17|6568]PA:down,Pid:1035,TWI:4,FWI:4,EID:17, ... WI:4
C02805/InputKeyFlow: [P:D:17|584]SendMsg:1035, pointerAc:2       ← POINTER_ACTION_DOWN
  1035  1035 C02805/InputKeyFlow: [P:D:17|730]recv
  1035  1035 C04213/InputKeyFlow: input_transfer_station.cpp HandleInputEvent: wid:4,ac:2
A0002a/ScreenLock_Default: SlideScreenLockViewModel --> Touch Event 0 at Point 640, 780
... 连续 Touch Event 2 直到 Point 640, 101 ...
C02805/InputKeyFlow: [P:U:55|584]SendMsg:1035, pointerAc:4       ← POINTER_ACTION_UP
A0002a/ScreenLock_Default: SlideScreenLockViewModel --> Touch Event slidingLength: 150
```
- `1035` 是 `com.ohos.systemui`（锁屏所属进程）。
- `WI:4` 表示窗口 id=4 被命中（锁屏窗口），不再是无窗口的 -1 路径。

**触摸注入脚本**：`out/x86_64_virt/ohos-dbg/scripts/touch_swipe.sh`（首版，坐标未缩放）和
`touch_swipe2.sh`（正确缩放）。用法：base64 后写入 guest 再 `sh`。

**坐标缩放（关键坑）**：`/dev/input/event1` 的 ABS 轴量程约 **30720**（不是像素数）。
- 观察到 `sendevent 3 53/54 <raw>` 时，raw=640 被换算成 26.67px ⇒ 比例约 `30720/1280 = 24`。
- 所以 `raw_x = px_x * 24`，`raw_y = px_y * 24`（1280x800 屏）。
- 首次按像素直接写 raw 值，导致触点只有 (26,18)，锁屏几乎不响应（slidingLength 仅 150 但起点极偏）。

**多点触摸协议 B 序列**（Virtio MultiTouch）：
```
sendevent /dev/input/event1 3 47 0        # ABS_MT_SLOT 0
sendevent ... 3 57 1                      # ABS_MT_TRACKING_ID 1
sendevent ... 3 53 <x_raw>                # ABS_MT_POSITION_X
sendevent ... 3 54 <y_raw>                # ABS_MT_POSITION_Y
sendevent ... 1 330 1                     # BTN_TOUCH down
sendevent ... 0 0 0                       # SYN_REPORT
# 循环改 3 54 并 SYN_REPORT 实现滑动
sendevent ... 3 57 -1                     # TRACKING_ID -1
sendevent ... 1 330 0                     # BTN_TOUCH up
sendevent ... 0 0 0
```

**注意**：
- VNC 只发 PS/2 相对鼠标（`event4`），点击/拖动可以驱动光标，但**锁屏要触摸手势**，
  所以鼠标点按不解锁；解锁必须走触摸注入。
- `qemu-system-x86_64 10.2.1` 的 QMP `input-send-event` 带 `device` 参数会触发
  QEMU 崩溃（`Property 'qemu-fixed-text-console.device' not found`），**不要用**。
  触摸验证一律走 guest 内 `sendevent`。
- guest 输入设备（`/proc/bus/input/devices`）：
  - `event0` Power Button
  - `event1` QEMU Virtio MultiTouch  ← 触摸注入目标
  - `event2` QEMU Virtio Keyboard
  - `event3` AT Translated Set 2 keyboard
  - `event4` **QEMU QEMU USB Tablet**（`mouse0 js0`）← VNC 鼠标用这个（绝对定位）
  - `event5` ImExPS/2 Generic Explorer Mouse（旧的相对鼠标，加 usb-tablet 后为 event5）
- **VNC 鼠标漂移/滚轮失效的根因与修复**：只有 PS/2 相对鼠标时，VNC 发的是相对位移，
  指针会累积漂移、与主机光标对不上，滚轮也不通。修复是给 QEMU 加
  `-device qemu-xhci -device usb-tablet`（绝对定位，1:1 映射）。内核
  `CONFIG_USB_XHCI_HCD/CONFIG_USB_HID/CONFIG_INPUT_TABLET` 都已 =y，无需改内核。
  加完后 guest 多出 `QEMU QEMU USB Tablet` 设备。
- 注意：OHOS 光标走独立硬件光标层，`qmp screendump` **截不到光标**，
  不能用截图验证指针位置（会误判为“光标不动”）。
- 触摸注入待尝试手段：
  1. 在 guest 内直接写 `/dev/input/event1`（需要个小工具/uinput，可能受 SELinux permissive 放行）；
  2. QMP `input-send-event` + `abs`（上次报 `Input handler not found for event type abs`，
     因为没给该 device 指定 handler，可能需要 `-device usb-tablet` 或 set 默认 handler）；
  3. 确认 PS/2 鼠标点击（左键）是否能驱动锁屏/SystemUI（点“上滑解锁”或直接点按钮）。
- 采集 MMI 派发日志的可靠姿势（本轮踩坑）：串口 shell 里 `nohup hilog -x > /data/x 2>&1 &`
  经常随 shell 退出而死，只剩 1 行。改用 `setsid`，或用前台 `hilog -x > file` 配长等待，
  或改用 hilog 落盘后 `hilog -x` 一次性 dump（注意 5000 行环形缓冲会冲掉早期日志）。

### 7.3 【进行中】PC 桌面 —— 关键根因已定位：需要切到 SceneBoard（合一架构）

**⚠️ 重大结论（2026-09-19 定位）**：用户想要“别人那种 PC 桌面”，
**不是窗口模式问题，而是桌面 shell/架构不同**。之前做的
`--device-type 2in1` + `FreeFormMultiWindow` 只让**应用窗口**可浮窗，
**桌面 shell 仍是手机版 Launcher**，所以看起来还是手机样。

**仓库里的两套架构（由 `window_manager_use_sceneboard` GN arg 决定）**：

| | 当前 x86_64_virt | PC 桌面（别人编译的） |
|---|---|---|
| 架构 | `window_manager_use_sceneboard = false`（**分离架构** wmserver/dmserver） | `true`（**合一架构** window_scene） |
| 桌面 shell | `Launcher.hap`（`applications/standard/launcher/product/{phone,pad}`，**无 PC 变体**） | `SceneBoard.hap`（PC 桌面，含任务栏/锁屏扩展/状态栏扩展） |
| syscap | 无 `Window.SessionManager` | `SystemCapability.Window.SessionManager = true` |

**证据链**：
- 预编译 PC 桌面 HAP 就在仓库里：`applications/standard/hap/sceneboard/SceneBoard.hap`
  （**101MB**，bundleName `com.ohos.sceneboard`，module name `phone_sceneboard`，
  deviceTypes `["default","tablet"]`）。它是 PC 桌面本体。
- `applications/standard/hap/BUILD.gn:17` `if (window_manager_use_sceneboard) { hap_src_dir = "sceneboard/" ... }`；
  `:470` 同条件才把 `sceneboard_hap`、`sceneboard_notificationManagement_hap` 等加进依赖。
  **sceneboard=false 时这些 HAP 根本不安装**，系统用的是手机 Launcher。
- Launcher 只有 `product/phone` 和 `product/pad`，仓库里**没有** PC/2in1 launcher 变体。
- 全仓库**只有** `vendor/revoview/wukong100/config.json:496` 一个产品设了
  `window_manager_use_sceneboard = true`，可作参考模板。
- QEMU 产品的 window 子系统继承自 `productdefine/common/inherit/rich.json:587`
  （`features: []`），所以用 build 默认 `false`（`build/ohos_var.gni:319`）。

**切换到 PC 桌面（SceneBoard）——已执行，SceneBoard 成功安装并运行（2026-09-20）**

已完成：
1. `vendor/ohemu/qemu_x86_64_linux_full/config.json` 加 window 子系统覆盖（见下），
   全量重建成功（含 sceneboard HAP 与 window_scene 合一架构库）。
2. **SceneBoard 预装失败链（3 层，全部已修）**——这是切换后最关键的坑：
   - **① `install_list.json` 缺 `/system/app/SceneBoard`** → BMS 不安装（已加）。
   - **② `install_list_capability.json` 缺 `com.ohos.sceneboard`** → 它有
     `sys/commonUI`、`sysDialog/common` 等特权扩展，BMS 报
     `not allow use privilege extension` → `errCode 8519888`
     (`ERR_APPEXECFWK_PARSE_PROFILE_PROP_CHECK_ERROR`)。已加授权条目。
     **签名坑**：`app_signature` 要填 **provision profile 的 distribution-certificate**
     的 SHA256（`8E93863FC32EE238060BF69A9B37E2608FFFB21F93C862DD511CBAC9F30024B5`），
     不是 HAP 签名证书（SceneBoard 的是 `0716E4E8...`）。最稳妥两个都填。
   - **③ 真正硬阻塞：SceneBoard.hap 只打包 ARM 原生库**
     （`libs/arm64-v8a/{libmultimodalinput,libeffectrender}.so` + `armeabi-v7a`），
     而设备 ABI 是 `x86_64`（`const.product.cpu.abilist=x86_64`）。x86 build 在
     `build/config/BUILDCONFIG.gn:416` 置 `is_emulator=true`，进而
     `bundle_framework/services/bundlemgr/BUILD.gn:231` 定义 `X86_EMULATOR_MODE`；
     `services/bundlemgr/src/module_profile.cpp:3315` 在 `X86_EMULATOR_MODE` 下把
     native-SO ABI 不匹配**升级为致命错误** → `errCode 8519891`
     (`ERR_APPEXECFWK_PARSE_NATIVE_SO_FAILED`)。
     **修复**：去掉 `ParserNativeSo` / `ParserArkNativeFilePath` 两处
     `#ifdef X86_EMULATOR_MODE ... return ERR_...` 致命分支，降级为警告
     （与非 emulator 真机行为一致）。重编 `libbms`（target `libbms`），注入
     `/system/lib64/libbms.z.so`。
3. 改动文件：
   - `foundation/bundlemanager/bundle_framework/services/bundlemgr/src/module_profile.cpp`
     （去掉两处 `#ifdef X86_EMULATOR_MODE` 致命返回）
   - `vendor/ohemu/virt/preinstall-config/install_list.json`（加 `/system/app/SceneBoard`）
   - `vendor/ohemu/virt/preinstall-config/install_list_capability.json`
     （加 `com.ohos.sceneboard` 特权扩展授权 + 两个签名）

**验证结果（已确认）**：
- `/data/app/el1/bundle/public/com.ohos.sceneboard` 存在（安装成功）。
- `ps` 显示 `com.ohos.sceneboard` 进程存活，日志显示它在做真实工作
  （AceResource 加载、ScreenLockForm、RSScreen power/backlight、DMS screen_session）。

**遗留问题（下一步）**：
- **QEMU 仍显示 "Display output is not active"**（guest 未设置 scanout framebuffer），
  即 SceneBoard 在跑但屏幕无输出（之前分离架构下用 wmserver 时是有画面的）。
  日志有可疑点：`RSRenderServiceConnectHub::SetOnRenderProcessDiedCallback
  tokenMaskId is not find ClientToRenderConnection`；`SetDisplayBacklight fail`。
  待查：合一路径下 screen_session 是否成功建连/出帧；QEMU 是否需要
  `-display`/scanout 相关调整；是否因为 SceneBoard 的 `libeffectrender.so`/
  `libmultimodalinput.so` 为 ARM 而在 x86_64 上加载失败影响渲染（需查 hilog
  `dlopen`/`napi` 失败）。
- 装机后**必须用全新 userdata overlay**（BMS 的 `SPreInstallExceptionMgr`
  异常记录写在 userdata 的 bmsdb 里，旧 overlay 会一直跳过 SceneBoard）。

**### 当前状态（2026-09-20 续）—— 做到哪、下一步**

已完成：
- `vendor/ohemu/qemu_x86_64_linux_full/config.json` **三处改动**：
  1. `graphic` 子系统补 `graphic_2d` 组件，features =
     `ace_enable_gpu=true`、`rs_enable_eglimage=true`、`use_texgine=true`、
     **`rs_enable_uni_render=true`**（关键，见下）。
  2. `window` 子系统 `window_manager_use_sceneboard=true` +
     `SystemCapability.Window.SessionManager=true`。
- 全量重建成功（`out/x86_64_virt/ohos-dbg/build-uni.log`，2026-09-20 12:13，1h06m）。
  **验证宏已生效**：`grep -c DRS_ENABLE_UNI_RENDER
  out/x86_64_virt/obj/foundation/graphic/graphic_2d/rosen/modules/render_service/librender_service.ninja` = 1。
- 镜像内 SceneBoard + `install_list.json`/`install_list_capability.json` 均在。
- 已重建全部 overlay（含全新 userdata）并启动。

**⚠️ 2026-09-20 二次排查重大进展（本轮）**：

**uni_render 修复已确认生效**（不再是问题）：
```
C01406/skia: RSUniRenderThread Power On First Frame finish, processNode:0
C01406/RSRenderComposer: CommitAndReleaseLayers report load event ... SurfaceName: [ScreenNode]
C01406/RSMainThread: RSMainThread Power On First Frame finish, node:23
```
即 RS 已创建 unified composer adapter、收到 ScreenNode 并出帧；**没有** `not uni render`。

**真正剩余根因（决定性，已抓到内核栈）**：
`composer_host`（guest pid 493，进程名 `hdf_devhost`）的线程 **TID 512 卡在 D 状态**，
wchan = `virtio_gpu_queue_fenced_ctrl_buffer`，调用栈：
```
virtio_gpu_queue_fenced_ctrl_buffer   ← 等待 ctrlq ack_queue（命令从未完成）
virtio_gpu_primary_plane_update
drm_atomic_helper_commit_planes / commit_tail / drm_atomic_commit
drm_atomic_connector_commit_dpms   ← 来自 drm_connector_property_set_ioctl（DPMS on）
```
即 **HDF display host 发起的 DRM atomic commit（DPMS on / primary plane update）
在 virtio-gpu 队列上永远等不到 host 的 ACK**，导致 scanout 从未真正 enable。
佐证：
- `SetDisplayPowerStatus: devId:0, status:0, vdi return 0`（HDF 层报成功）
- 但 `SetDisplayBacklight fail devId:0, ec=-1`（背光也走同一 host，失败）
- `RSUniRenderComposerAdapter::SetBufferColorSpace set color space fail`
- `eglQuerySurface / eglSetDamageRegionKHR failed`（EGL surface 未真正 attach 到 scanout）
- suspend 时内核报 `Freezing user space processes failed ... task:OS_IPC_1_512 state:D`，
  即这条 D 状态线程阻止了冻结，说明它**真的永久挂住**。
- QEMU 侧反复打印 `virtio_input_hid_handle_status: unknown type 20`（多触摸设备），
  与 virtio-gpu 无关，但说明 guest 仍在跑。

**症状**：QEMU 从 ~15s 起显示 "Display output is not active"（PPM extrema 恒为
`((0,170),(0,170),(0,170))` = 灰底提示）；guest 约 19~21s 自动 `PM: suspend entry (deep)`
（因为屏幕没亮，PowerMgr 判定 SLEEP→auto-suspend），串口随之静默。
**这只是"没出帧"的次生现象；出帧失败的根因是上面的 DRM/virtio-gpu commit 挂死。**

**⚠️ 重要更正（本轮用 `-trace enable=virtio_gpu_*` 抓 QEMU 侧，推翻了上面的
「host 不 ACK」结论）**：
QEMU **确实在正常处理 virtio-gpu 命令**，trace 输出（`out/x86_64_virt/ohos-dbg/qemu-trace.log`）：
```
virtio_gpu_cmd_get_display_info
virtio_gpu_cmd_res_create_2d res 0x2, fmt 0x2, w 1280, h 800
virtio_gpu_cmd_set_scanout id 0, res 0x2, w 1280, h 800, x 0, y 0
virtio_gpu_cmd_res_xfer_toh_2d res 0x2
virtio_gpu_cmd_res_flush res 0x2, w 1280, h 800, x 0, y 0
... (res 0x3..0xc 陆续 create/xfer/set_scanout/flush)
virtio_gpu_cmd_set_scanout id 0, res 0x0, w 0, h 0, x 0, y 0   ← 这是关机/挂起时关 scanout
```
即 **资源创建、上传、SET_SCANOUT、RESOURCE_FLUSH 都被 QEMU 完成了**，scanout 通路是通的。
t=12s 截图 `extrema=((0,0),(0,0),(0,0))`（纯黑）时 scanout 已 active，但**内容是黑的**；
t=15s 起变灰（170）= QEMU 的 "Display output is not active"，对应 guest 关 scanout（进 suspend）。
所以真正的现象是 **"RS 出帧但内容是黑的 / 没合成到显示"**，而不是 host 死锁。
之前 QMP 看到 ctrlq 停在 60 且 guest 线程 D 状态，很可能是 **进入 suspend 后 virtio 队列
desync 造成的次生假象**（`x-query-virtio-queue-status` 在 suspend 后读，avail/used 归 0）。
**下一步应聚焦"为什么 scanout 的 buffer 是黑的"**（RS 合成结果/EGL surface 未清成可见内容、
SceneBoard 是否提交 layer、或 backend buffer 格式问题），而不是查 QEMU 卡死。

**⚠️ 第三轮更正（突发截图 + 关闭 uni_render 复测，推翻上面"scanout 已 active"的说法）**：
- 新增 `scripts/burst.py`：启动后每 0.25s `screendump` 一次，覆盖 0~30s。结果
  （`burst_out.txt` / `burst_dis.txt`）：
  - 前 ~7~14s 恒为**纯黑**（1 种颜色，1024000 像素全 0）；
  - 之后变为黑底 + 684 个灰(170)像素 = QEMU 的 "Display output is not active" 占位字。
  - **全程没有任何一帧出现 UI/锁屏/开机 logo**。
- **关键实验：把 `/system/etc/unirender.config` 写成 `DISABLED`（RS 运行时读
  `/etc/unirender.config`，见 `rs_uni_render_judgement.cpp:60-79`；`/etc`→`/system/etc`），
  重建 overlay 后复测，结果完全一样（前段纯黑 → QEMU 占位灰字）。**
  → **uni_render 不是黑屏的原因**；开/关都一样黑。
- 结合 QEMU trace（命令确实被处理但内容黑），当前最合理的结论是：
  **guest 侧根本没有可显示的合成内容**（不是 virtio-gpu 卡死，也不是 uni_render），
  但这也**不能**解释为什么连内核/开机 logo 都没有（先前的分离架构镜像是能看到
  锁屏的，见 `evidence/pc2in1_boot.png`，2026-09-18）。
- **重要实验方法（本会话验证可用）**：
  - `/etc/unirender.config` 内容 `DISABLED` / `ENABLED_FOR_ALL` 可运行时切换 uni_render，
    **无需重编**；改完必须 `debugfs` 注入 + `e2fsck -f -y system.img` + 重建
    `dbg/system.qcow2` overlay。
  - 注：本轮已把该文件**删除**、镜像恢复默认（= 编译期 `RS_ENABLE_UNI_RENDER`，
    即 ENABLED_FOR_ALL）。
  - **不要再轻易改 system.img**：频繁注入/fsck 后 guest 反复 suspend/resume，
    约 4~5 分钟后 init 会重启服务（watchdog），交互彻底不稳。
- **`pkill -f qemu-system-x86_64` 会匹配到自身 shell 导致命令挂起**；用
  `pkill -9 -f 'qemu-system-x86_64 -[m]achine'`（方括号技巧）避免自杀。

**补充（本轮 QMP `x-query-virtio-queue-status` 实测，注意读到的值可能已受 suspend 影响）**：
- `virtio-gpu` ctrl 队列 `last-avail-idx`/`used-idx` 从 58→60 后停在 60；但结合上面的
  trace，这更可能是 suspend 后的 desync，而非 host 卡死。
- QEMU `x-query-virtio-status` 报 `broken:false`、`isr:0`；host-features 只有
  `VIRTIO_GPU_F_EDID`（无 virgl/blob），与 guest 内核 `[drm] features: -virgl +edid
  -resource_blob -host_visible` 一致。
- **第二条独立挂死路径**：内核 fbdev `drm_fb_helper_damage_work ->
  drm_atomic_helper_dirtyfb -> drm_atomic_helper_commit_planes ->
  virtio_gpu_primary_plane_update -> virtio_gpu_queue_fenced_ctrl_buffer` 同样 D 状态
  （即 HDF display host 的 ioctl 路径与内核 fbdev 路径**双双**卡在同一 ctrlq）。
- 用 `qemu -trace help | grep virtio_gpu` 可见可跟踪事件：
  `virtio_gpu_cmd_set_scanout / _res_flush / _res_create_2d / fence_ctrl / fence_resp /
  cmd_suspended` 等。**下一步用 `-trace enable=...` 抓"最后一条被 QEMU 完成的命令"**，
  定位是 SET_SCANOUT / RESOURCE_FLUSH / RES_CREATE_2D 哪一条开始不再回包。
- 复现命令（完整）：`pkill -9 -f 'qemu-system-x86_64 -machine q35'` 后
  `(setsid bash out/x86_64_virt/ohos-dbg/scripts/launch_diag_sock.sh > out/x86_64_virt/ohos-dbg/qemu-sock.log 2>&1 &)`，
  再用 `scripts/gpu_poll.py` 轮询队列、`scripts/keepawake.py N` 后台每 2.5s `system_wakeup`
  维持 awak（否则 19s 后进 S3，串口静默）。

**下个会话下一步（按优先级，已按第三轮更正重写）**：

**当前唯一确认的事实**：`sceneboard=true` 的镜像**全程无任何可见内容**（burst 纯黑 →
QEMU 占位灰字），且**开/关 uni_render 都一样**。而 2026-09-18 的**分离架构**镜像
（`evidence/pc2in1_boot.png`）锁屏正常。所以问题在 **sceneboard/window_scene 这条架构变更**
（或 SceneBoard 本体/其依赖），**不是 uni_render、不是 virtio-gpu 卡死**。

1. **先证明"是否曾经出过帧"**：用 guest 自带 `snapshot_display`（存在于
   `/system/bin/snapshot_display`）抓 RS 认为的屏幕内容：
   `snapshot_display -f /data/shot.jpeg`，再把文件读出来看。
   - 若 RS 截图**有内容**（锁屏/桌面）→ 说明"渲染 OK，只是没 scanout/上屏"，
     去查 HDF display host / DRM / scanout 绑定。
   - 若 RS 截图**也是黑的** → 说明 **UI/合成根本没画**，去查 SceneBoard 是否
     attach 了窗口 / RS 是否收到 layer。**这是最关键的一步，先做。**
2. **隔离变量（需要一次全量重建，代价 1h）**：当前 `sceneboard=true` 的镜像只改过
   window 子系统 + graphic 的 `graphic_2d` features。若第 1 步证明"没画"，
   可重建一个 **sceneboard=true 但 graphic 只保留 `ace_enable_gpu=true`**
   （去掉 `rs_enable_eglimage`/`use_texgine`/`uni_render`）的版本，排除 graphic features。
   注意：AGENTS 记录显示"最早的 sceneboard 构建"在没设 uni_render 时也是黑的，
   所以 graphic features 大概率不是原因，**优先查 window/SceneBoard**。
3. **查 SceneBoard 是否真的创建并显示窗口**：hilog 里 SceneBoard（pid 1307）已经在建
   `SCBScreenSession`/`RSDisplayNode(bounds 1280x800)`，但 `GetScreenInfoById:
   SendRequest nullptr`（stub 返回空 `ScreenInfo`）与
   `screen_manager.cpp UpdateScreenInfoLocked: displayInfo is null` 说明
   **服务端 ScreenSessionManager 没建立可用 screen session**
   （`ScreenSessionManager::GetScreenInfoById` → `GetScreenSession(screenId)==nullptr`）。
   下一步重点：确认 SA4607（`libscreen_session_manager.z.so`，foundation 进程）是否
   收到了屏幕连接、是否创建了 `ScreenSession`、是否 `SetScreenPowerById(POWER_ON)`。
   相关代码：`window_scene/screen_session_manager/src/screen_session_manager.cpp`、
   `screen_session.cpp`、`window_scene/screen_session_manager_client/`。
4. **自动 suspend 是次生现象**：`power_mode_config.xml` 里
   `SystemAutoSleepTime(102)=5000ms`、`DisplayOffTime(101)=5000ms`；
   `PowerStateMachine::InitState` 若判定屏幕未 ON 就进 SLEEP → ~5s 后 auto-suspend。
   所以**只要屏幕真正 ON 就不会挂起**。调试时用 `scripts/keepawake.py N` 维持唤醒，
   或临时改 `power_mode_config.xml`（在 `base/powermgr/power_manager/services/native/
   profile/`，安装到 `/system/etc/...`）把 101/102 设大。
5. **次要项**（仅在 1~3 修好后仍异常再看）：
   - `libwms.z.so` 在 sceneboard 模式下不存在（4606 靠 `libsms` 的
     `MockSessionManagerService` 晚注册）；`SAMGR: insert SA:4606_94 / Publish result:0`
     显示它**已注册成功**，暂不处理。
   - `const.product.has_buildin_screen` / `persist.sceneboard.ispcmode` 未设；
     参考 wukong100 也没设，非首帧必需。
   - SceneBoard.hap 的 ARM 原生库（`libmultimodalinput`/`libeffectrender`）在 x86_64
     上 dlopen 失败（另有 `libhistogram.z.so` 也 dlopen 失败，均非致命）。
   - `/etc/unirender.config` 运行时可切 `DISABLED`/`ENABLED_FOR_ALL`（无需重编）。

**调试工具（本会话新增，均在 `out/x86_64_virt/ohos-dbg/scripts/`）**：
- `launch_diag_filelog.sh`：串口落文件版（适合抓完整启动日志，无 client 也不丢）。
- `launch_diag_sock.sh`：串口 socket + `no_console_suspend`（配合下面脚本）。
- `wake_cmd.py "命令" [wait]`：**先 QMP `system_wakeup` 再发串口命令**（必用，
  否则 guest 已 suspend 收不到命令）。
- `send_script.py <本地sh> [远端名] [wait]`：base64 分块把脚本传入 guest 并执行
  （规避串口终端 80 列折行打断长命令）。
- `boot_shots.py`：启动后按时间点 QMP 截图并输出 extrema/颜色数。

**⚠️ 屏幕 "Display output is not active" 根因（2026-09-20 定位）**：
> **【已被第三轮更正推翻】**：开/关 uni_render 都黑屏（见上），所以 uni_render 不是根因。
> 以下内容仅作历史记录保留。
`RS_ENABLE_UNI_RENDER` 未编译进来。SceneBoard（合一架构）依赖 RenderService 的
**统一渲染（unified render）** 路径来创建 composer agent / HDI 输出通路并出首帧；
没有该宏时 RS 仍走分离管线：
- `foundation/graphic/graphic_2d/rosen/modules/render_service/composer/
  composer_service/pipeline/rs_render_composer_manager.cpp:33,70`
  在 `IsUniRender()==false` 时直接 `RS_LOGE("... not uni render")` 并 return，
  **不创建 unified composer agent**，只有 legacy `RSPhysicalScreenProcessor` 路径。
- 该宏由 GN arg `graphic_2d_feature_rs_enable_uni_render` 控制
  （`foundation/graphic/graphic_2d/graphic_config.gni`，默认 false）。
- **QEMU 产品的 graphic 子系统原本只继承了 `rich.json` 的
  `graphic_2d_feature_ace_enable_gpu=true`，从未设 uni_render**；
  而参考 PC 产品 `vendor/revoview/wukong100/config.json` 明确设了
  `graphic_2d_feature_rs_enable_uni_render = true`（与 sceneboard=true 配套）。
- **修复**：在 `vendor/ohemu/qemu_x86_64_linux_full/config.json` 的 graphic
  子系统补 `graphic_2d` 组件，features 含
  `graphic_2d_feature_rs_enable_uni_render = true`
  （同时保留 `ace_enable_gpu`/`rs_enable_eglimage`/`use_texgine`）。
  然后**全量重建**（改变 render_service 编译宏，非增量）。
- 验证：`grep -c RS_ENABLE_UNI_RENDER out/x86_64_virt/render_service/librender_service.ninja`
  应为 >0（约 `graphic_config.gni` 发宏处）；启动后 hilog 不再出现
  `not uni render` / `tokenMaskId is not find ClientToRenderConnection`，
  QEMU 不再是 "Display output is not active"。

**次要问题（待验证，若 uni_render 修复后仍无画面再看）**：
- SA4606 profile 指向 `libwms.z.so`，但 sceneboard 模式下
  `wmserver/BUILD.gn:264` 把 `libwms` 变成空 group，镜像里**没有**
  `libwms.z.so`（4606 由 `MockSessionManagerService` 在 `libsms` 中晚注册）。
  如需可在 sceneboard 分支构建一个 link `libsms` 的 `libwms.z.so` shim。
- `const.product.has_buildin_screen` / `persist.sceneboard.ispcmode` 未设，
  `screen_session_manager.cpp:189,639` 会走非 PC 路径（
  `OnScreenChangeDefault` 而非 `OnScreenChangeForPC`）。PC 布局需要时再设。

### 7.3.1 后续排查结果（2026-09-21，关键：黑屏根因定位）

**调试通道大升级：hdc over hostfwd**。官方 launcher 会给 guest `hdcd:5555` 做 hostfwd，
我们的调试启动脚本没做。加 `-nic user,hostfwd=tcp:127.0.0.1:5555-:5555` 后，
host 侧 hdc（`~/.local/deveco/command-line-tools/sdk/default/openharmony/toolchains/hdc`）
`hdc tconn 127.0.0.1:5555` 连上，`hdc shell` 用 **TOKEN_SHELL**（flag:2），
可过 `CheckSavePermission` 等权限校验（串口 console 是 TOKEN_NATIVE flag:1，会被拒）。
**以后一律用 hdc，不要再用串口 console 做交互。** 相关脚本：
`scripts/start_hdc_bg.sh`、`launch_hdc.sh`、`launch_hdc_filelog.sh`、`scripts/ab_wake.py`。

**重要更正：此前"SceneBoard 从不注册 RS 渲染节点"是错的**——那是**旧 userdata +
hilog 环形缓冲被冲掉**造成的假象。用**全新 userdata** + hdc + 保持唤醒后，
SceneBoard 的 ArkUI **完整走通**：
```
SCBScreenSessionManager init → RSRenderServiceConnectHub CreateConnection →
AddRenderProcessConnectionToken → RSRootNode::Create → rosen_window ArkUI requests first Vsync →
RSSurfaceNode::Create (18 个 SCB* 窗口) → RSRenderPipelineAgent CreateNodeAndSurface RegisterRenderNode →
AceWindowScene OnAttachToFrameNode → Root node request first frame → ArkUi flush first frame
```
**注意：换 SceneBoard 相关实验后务必重置 `dbg/userdata.qcow2`（从 `images/userdata.img`
重建 overlay），否则会复现"没节点"假象。**

**已排除的假设（都验证过，别再重复）**：
- `rs_enable_uni_render`：ON/OFF 黑屏结果一样（A/B 三连跑 `ab_summary.txt`）；仅影响
  `snapshot_display` 能否返回 PixelMap（ON→RC=255，OFF→成功但全黑）。
- virtio-gpu 卡死：QEMU trace 显示命令都被处理；D 状态是 suspend 后的次生现象。
- SceneBoard.hap 的 ARM 原生库（`libeffectrender.so`/`libmultimodalinput.so`）：导入是惰性的、
  非致命（`SwiperPageWhiteBoxComponent.aboutToAppear` 照常执行），与黑屏无关。
- `persist.sceneboard.ispcmode=true`（PC 模式）：`OnScreenChangeForPC` 确实跑了，但显示节点
  依旧无子节点，**不解决黑屏**。
- 关闭 RS client 多实例 `persist.rosen.rsclientmultiinstance.enabled=0`：**更糟**——
  逻辑显示节点根本不创建，`RSUIDirector::AddUIDirectorCommand, RSUIContext is nullptr` 刷屏
  2400 次，仍全黑。**多实例是这个架构的必需项。**

**当前确认的真正根因（RSUIContext / 显示节点归属不匹配）**：
- RS 侧：`LOGICAL_DISPLAY_NODE[1623497637890] RSUIContextToken: NO_RSUIContext,
  Bounds[-inf -inf -inf -inf], ChildrenIndex:-1`；`RSScreenRenderParams:
  screenInfo_.id[0] ... allMainAndLeashSurfaces_.size()[0]`；`ClientNodeTreeDump:` 空；
  `RSMainThread Power On First Frame finish, node:23` 但 `RSUniRenderThread processNode:0`。
  → **显示节点的 `RSSetUIContextToken` 与几何命令从未到达 RS**（不是"换了别的 map"）。
- 客户端：`RSNode::AddChild, Id: 5909874999308, SurfaceNode:[...SCBWallpaper5]`——
  父节点 id 落在 **SceneBoard 自己的 RSUIContext id 空间**（token ~5909874999297），
  不是显示节点 id。18 个 SCB 窗口挂在 SceneBoard 本地树，**从未桥接到服务端逻辑显示节点**。
- 显示节点由 **DMS（foundation 进程）** 创建；DMS 侧日志有
  `RSRenderServiceConnectHub::GetRenderProcessTokenMaskId connectToRenderRemote is nullptr`
  → `INVALID_TOKEN_MASK_ID` → 显示节点的 token/几何命令被丢弃。
  （注意：`InitRSUIDirector ... rsUIContext is null` 是**误报**，
  `rs_adapter.cpp:486-499` 该参数默认为 nullptr，打印它而已。）
- 窗体挂载机制：`ScreenPattern::OnAttachToFrameNode` →
  `context->SetRSNode(displayNode)`（`screen_pattern.cpp:76-96`），子节点靠
  `RosenRenderContext::AddChild` → `rsNode_->AddChild` 建立父子关系；
  `AttachToDisplay`/`AttachToWindowContainer` **只有开机动画/MMI指针/无障碍在用**，
  window_scene 路径根本不用（所以日志里 attach 只出现一次，是 BootAnimationNode）。

**候选修复（都需改代码 + 全量重建 ~1h，未验证；按风险排序）**：
1. 对齐参考 PC 产品 `vendor/revoview/wukong100/config.json` 的 graphic 配置
   （我们只抄了 window 子系统）：它多设了 `enable_opengl=true`、`enable_vulkan=true`、
   `upgrade_skia=true`、`enable_swap_ycbcr_channel=true`，并含 `graphics_effect`、
   `graphic_surface`、`graphic_3d`、`vulkan-*` 等组件。**注意 QEMU 无 3D（-virgl），
   开 vulkan/opengl 有风险，可能起不来。**
2. 改 window_manager：让 scene_board 客户端路径把显示节点建在**自己的 RSUIContext**里
   （`screen_session.cpp:88-91` 的 `CREATE_SESSION_FOR_CLIENT` 直接返回、不建不设 bounds；
   `:3159` `SetDisplayNode`；`ScreenSessionManagerClient::HandleDisplayNodeWhenScreenConnect`
   `screen_session_manager_client.cpp:1222-1237`）。
3. 修 DMS 侧渲染连接：确认 RS `OnScreenConnected` 返回给 DMS 的
   `connectToRenderToken`/`remoteConn` 非空（`rs_render_service.cpp:440-466`、
   `rs_render_pipeline_client.cpp:71-79`、`rs_render_service_connect_hub.cpp:197-231`）。
4. 让 window_scene 显式给 SCB 主窗口调 `RSSurfaceNode::AttachToDisplay(screenId)`
   （`rs_surface_node.cpp:884-893`）——绕过层级依赖，较 hack。

**相关证据/产物（`out/x86_64_virt/ohos-dbg/`）**：`scb_chain_stop_analysis.txt`、
`att_experiment_report.txt`、`mi/mi_experiment_report.txt`、`ab_summary.txt`、
`att/`、`att2/`、`mi/`、`trace_plog/`。

### 7.3.2 两次修复尝试的结果（2026-09-21，均未解决黑屏）

**尝试 A：套用 wukong100 的 graphic 配置 → 构建失败，已回退。**
`graphic_2d_feature_enable_vulkan=true` 会给全树定义 `RS_ENABLE_VK`，但
`third_party/vulkan-headers/include` 的 include 路径只在 `2d_graphics` 目标上挂载
（`graphic_config.gni` + `2d_graphics/BUILD.gn:358`），其它目标全部
`fatal error: 'vulkan/vulkan.h' file not found`（1609 个失败）；另外
`upgrade_skia=true` 选了 `third_party/skia/m133`，与 OHOS 分支 API 不符
（`SkSurface::setDrawingArea` 不存在）。**结论：x86_64_virt 不能照抄
wukong100 的 graphic 配置**（QEMU 无 3D/Vulkan）。配置已改回原样。

**尝试 B：修 `connectToRenderToken` 为空 → 编译进去了，但黑屏依旧。**
根因（已确认）：`ScreenSessionManager::UpdateScreenTypeInfo`
（`screen_session_manager.cpp:2545`）和 `OnScreenChangeDefault`（`:1891`）
调用 `GetOrCreatePhysicalScreenSession(screenId)` **没传 `connectToRenderToken`**
（PC 分支 `:1847` 是传的），于是 reason=4 的物理 ScreenSession 以 null token 构造：
- `screen_session.cpp:81` `InitRSUIDirector(nullptr)` → `RSRenderPipelineClient(nullptr)`
  → `GetRenderProcessTokenMaskId connectToRenderRemote is nullptr` → `INVALID_TOKEN_MASK_ID`；
- `screen_session.cpp:83` `RSUIContextContainer::SetRenderSession(config.renderSession)`
  **把进程级全局 renderSession 覆盖成 null**（已确认为 static 全局）。
已修的 3 处（`foundation/window/window_manager`，全量重建 1h28m 成功、已注入镜像）：
1. `screen_session_manager.cpp:2545` → 传 `screenSession->GetRenderSession()`；
2. `screen_session_manager.cpp:1891` → 传 `connectToRenderToken`；
3. `screen_session.cpp:83` → 仅当 `config.renderSession != nullptr` 才写全局。
**结果：仍是纯黑**（`verify_fix/`）：`LOGICAL_DISPLAY_NODE` 依旧
`RSUIContextToken: NO_RSUIContext, Bounds[-inf]`、`allMainAndLeashSurfaces_.size()[0]`、
`ClientNodeTreeDump:` 空；`SCREEN_NODE` 自身也是 `NO_RSUIContext`。
这 3 处是**正确的 bug 修复**（保留），但不是充分条件。

**新增关键线索（下个会话从这里继续）**：
- RS 日志 `RSMainThread MergeToEffectiveTransactionDataMap pid:0 not valid, skip it`
  ——客户端事务以 **pid 0** 到达并被跳过（可能解释了所有 SetBounds/SetUIContextToken/
  AddChild 都"从未到达"）。
- `SendClientDumpNodeTreeCommands ... count[0]` / `CollectClientNodeTreeResult ...
  completionCount[0]` ——RS 侧**注册的客户端数为 0**。
- SceneBoard 侧 `SCBScreenSession: SCBScreenSession` **每 ~10s 重试一次**（拿不到屏幕会话），
  与 `GetScreenInfoById: SendRequest nullptr` 呼应。
- `snapshot_display` 现在能解析到 `display 0, 1280x800`，但
  `CreatePixelMapByDisplayNode NodeId[...], size[0, 0]` → 无内容可截。
- 屏幕电源本身 OK：`hidumper -s RenderService -a screen` →
  `powerStatus=POWER_STATUS_ON, backlight=223, activeMode 1280x800@75`。
- 下个会话重点：**为什么 RS 的渲染客户端连接没注册 / 事务 pid 为 0**
  （`RSRenderServiceClient::Connect`、`RSClientToServiceConnection`、
  `RSUIContextContainer::GetRSUIContext()` 在 DMS 侧是否为空、
  SceneBoard 为何 10s 重试 `SCBScreenSession`）。注意 hilog 环形缓冲只有 ~8k 行，
  必须开机早期就 `hilog -w start`，否则又会误判"没有节点"。

**切换到 PC 桌面（SceneBoard）的做法（原始步骤）**：
在 `vendor/ohemu/qemu_x86_64_linux_full/config.json` 加 window 子系统覆盖：
```json
{
  "subsystem": "window",
  "components": [{
    "component": "window_manager",
    "features": ["window_manager_use_sceneboard = true"],
    "syscap": ["SystemCapability.Window.SessionManager = true"]
  }]
}
```
然后**全量重建**（sceneboard 会改变编译目标集合，不只是打包）。

**⚠️ 切换后的影响（重要）**：
- 之前第 9 节的三个输入修复**全在 `wmserver/`（分离架构）**，切到 sceneboard 后
  `wmserver/` 不再被使用，这些修复**不再相关**（合一架构 `window_scene/` 路径
  `scene_session_dirty_manager.cpp:988` 本来就正确设置了 `displayId`/`groupId`）。
- 预计会踩新坑：SceneBoard.hap 是预编译产物，需确认与当前 manifest/syscap 兼容；
  可能还需额外的 window_scene 依赖部件。
- 用户已知悉这是大改动（全量重编 16min+，可能多轮调试）。

---

### 7.3-old 【已完成的铺垫】2in1 设备类型 + 自由窗口（分离架构）

说明：以下工作在分离架构下完成并验证，但**不足以得到 PC 桌面 shell**（见上）。
保留作为“窗口自由化”的成果，以及参数固化/构建/踩坑记录。

**关键机制（分离架构 wmserver）**：
- PC/自由窗口开关：`const.window.multiWindowUIType=FreeFormMultiWindow`
  → `wmserver/src/window_manager_service.cpp:352 LoadWindowParameter()`
  把它映射成 `WindowUIType::PC_WINDOW`（`HandsetSmartWindow`=手机，`TabletSmartWindow`=平板）。
- 设备类型：`const.product.devicetype=2in1`（**只读 param**，运行时 `param set` 会失败，
  必须构建时用 `--device-type 2in1` 或改 `ohos.para`；由
  `base/startup/init/services/etc/BUILD.gn:160` 用 `device_type` GN arg 生成）。
  影响 ArkUI 布局（`device_config.cpp` 读 `const.product.devicetype`）。
- 装机校验风险：`bundle_install_checker.cpp:1760 CheckDeviceType()`。
  devicetype=2in1 时，只声明 `["default","tablet"]` 的 HAP 可能被判
  `DEVICE_TYPE_NOT_SUPPORTED`。旁路 param：`const.bms.supportAppTypes`
  （`bundle_install_checker.cpp:71`），设为 `default,phone,tablet,2in1` 即可放行。
- 应用安装设备类型声明示例：launcher `product/{phone,pad}/src/main/module.json5`
  只有 `["default","tablet"]`；仓库里**没有** 2in1/pc 专用 launcher product 变体。

**已完成（构建 + 参数固化）**：
1. 源码改动：`vendor/ohemu/virt/etc/param/product_virt.para`（安装到
   `/sys_prod/etc/param/`，由 init `LoadDefaultParams` 加载），追加：
   ```
   const.window.multiWindowUIType=FreeFormMultiWindow
   const.bms.supportAppTypes=default,phone,tablet,2in1
   ```
2. 用 `--device-type 2in1` 全量构建成功（16min，日志
   `out/x86_64_virt/ohos-dbg/build-pc2in1.log`），产出新 `system.img`/`sys_prod.img`。
   验证镜像内参数已固化：
   - `system.img:/system/etc/param/ohos.para` → `const.product.devicetype=2in1`、
     `const.build.characteristics=2in1`
   - `sys_prod.img:/etc/param/product_virt.para` → free-form + supportAppTypes 两行
3. 运行时（改动前）已验证：2in1 下系统正常启动，**锁屏切换为 PC 风格大布局**。

**重启验证（新镜像，已完成部分）**：
- 用 `out/x86_64_virt/ohos-dbg/scripts/launch_diag.sh` 启动（socket/overlay 全在 out 下）。
- **坑：换了新 system.img 后必须同时重建所有 overlay，尤其 `userdata.qcow2`**。
  只重建 system overlay 而沿用旧 userdata，会导致
  `/data/app/el2/100/base/com.ohos.launcher` 缺失、launcher 沙箱挂载失败、黑屏。
- 复验通过：`const.product.devicetype=2in1`、`const.window.multiWindowUIType=FreeFormMultiWindow`、
  `const.bms.supportAppTypes=default,phone,tablet,2in1` 三个 param 均从镜像生效；
  锁屏为 PC 风格，触摸滑动可解锁进入 Launcher（见 `evidence/pc2in1_boot.png`、
  `pc2in1_after_unlock.png`）。

**待办 / 未验证**：
- [ ] **free-form 窗口证据仍缺**：需要启动一个应用，确认窗口是可拖动/缩放的浮窗。
- [ ] 应用启动受阻（**疑似与 2in1 无关的既有问题**）：
  - console shell `aa start -b com.ohos.camera -a com.ohos.camera.MainAbility`
    报 `10103601 bundleName does not exist`（注意：camera 的能力名是
    `com.ohos.camera.MainAbility`，不是 `EntryAbility`）；
  - `bm dump -a` 报 `failed to get information`，含 `avc denied ... console`；
  - 从 Launcher 点图标：MMI `InputKeyFlow` 显示事件已投递到 launcher 进程
    （`SendMsg:<launcher pid>`），但应用进程未拉起，launcher 日志无 StartAbility。
  - 判断：console shell 的 `bm`/`aa`/`hidumper` 多被 SELinux/seccomp 限制，
    不能作为可靠的应用启动验证手段；下一步建议经 launcher UI 或
    `hdc shell`（而非串口 console）验证。
- [ ] 备选验证 free-form 的方式：等应用能启动后，截图看窗口是否带 decor（标题栏/
    圆角）且非全屏；或 `hidumper -s 4606`（WMS）dump 窗口 mode（同样受限）。

### 7.3.1 已踩坑：构建报 `hvigor spawn java ENOENT`

- 现象：全量构建在 HAP 打包阶段大量 `FAILED ... *_hap.stamp`，
  `out/x86_64_virt/error.log` 末尾 `> hvigor ERROR: spawn java ENOENT`。
- 根因：主机 `JAVA_HOME=/snap/android-studio/236/jbr` 已失效（snap 升到 242），
  `java` 不在 PATH。**与代码改动无关**。
- 修复：构建前 `export JAVA_HOME=/home/katax/.gradle/jdks/jetbrains_s_r_o_-17-amd64-linux.2`
  并把 `$JAVA_HOME/bin` 加到 PATH（见第 2 节）。

### 7.4 显示方式：GTK（首选）vs VNC

**用户偏好本地窗口，不用 VNC**。仓库自带官方 launcher，Linux 上默认就是 **GTK**
（本地窗口，鼠标键盘直通）：

```sh
cd /home/katax/Public/OHOS/out/x86_64_virt/packages/phone/images
./qemu_run.sh                      # 默认 --display auto → Linux 上选 gtk
./qemu_run.sh run --display gtk    # 显式 GTK
./qemu_run.sh run --display sdl    # GTK 起不来时用 SDL
./qemu_run.sh run --instance 01 --background   # 后台
./qemu_run.sh status --instance 00
./qemu_run.sh stop --instance 00 --force
```
- launcher 生成命令的关键显示参数是 `-display gtk,gl=off`（见
  `qemu_launcher_lib/launcher.py:_display_args`）。
- 它用 `virtio-mouse-pci`（不是 virtio-multitouch），并把 runtime 放
  `/tmp/ohos-qemu-<uid>/...`、实例 overlay 放
  `~/.local/state/openharmony-qemu/instances/...`（官方 launcher 行为）。
- 当前主机 `DISPLAY=:0`、`XDG_SESSION_TYPE=wayland`，GTK 可开窗。

**自建脚本**：`out/x86_64_virt/ohos-dbg/scripts/start_vm.sh`（前台，VNC `:24`），
`launch_diag.sh`（同款）。二者是调试用的最小启动，不走官方 launcher。

**VNC 连接坑（Remmina）**：Remmina 把 `:N` 当 display 号，填 `127.0.0.1:5924`
会去连 `11824` 而失败。正确写法：`127.0.0.1:24` 或 `127.0.0.1::5924`。

**鼠标漂移/滚轮失效（VNC 固有）**：只有 PS/2 相对鼠标时，VNC 发相对位移，
guest 累积漂移、与主机光标对不上。
- 试过 `-device qemu-xhci -device usb-tablet`（绝对定位），但**实测反而鼠标不动**，
  已回退。此方向在 VNC 下未成功；**建议直接用 GTK**（本地窗口无此问题）。
- OHOS 光标走独立硬件光标层，`qmp screendump` **截不到光标**，别用截图判断光标位置。

**guest 长空闲会挂起**：跑约 8 小时后串口 0 字节、屏幕全黑、VNC 显示
“display output not active”。解决：`pkill -f qemu-system` 重启。

### 7.5 下一步建议（新会话从这里继续）

1. **主线任务：切到 SceneBoard PC 桌面**（见 7.3）。步骤：
   - 改 `vendor/ohemu/qemu_x86_64_linux_full/config.json` 的 window 子系统；
   - 全量重建（记得 `export JAVA_HOME=...` + `RUBYOPT`，见第 2 节；后台 + 日志落 `out/`）；
   - 重建所有 overlay（含 userdata）后用 `qemu_run.sh`（GTK）启动；
   - 验证是否出现 PC 桌面（任务栏/状态栏/可拖动窗口）。
2. 切换后 `wmserver/` 的三个输入修复不再相关；注意 `window_scene/` 路径是否会
   重现当初那三个连接/displayId 类问题（理论上不会，但要验证触摸/鼠标）。
3. 若切架构失败或成本过高，回退方案：保持分离架构 + 2in1/free-form（已完成），
   接受“手机 Launcher + 自由窗口”。
4. 三个输入修复 commit 已完成（见第 8 节），无需再提交。

## 8. 工作区状态速查

- **已提交（注意：两仓在分支 `fix-mmi-display-info` 上，非 detached）**：
  - MMI 仓 `foundation/multimodalinput/input`：
    `193b62cf5 fix(input): retry MMI service connection in AllocSocketPair`
  - WMS 仓 `foundation/window/window_manager`：
    `0348bc8415 fix(wms): re-flush display info when MMI service comes online`
    `a8265d0238 fix(wms): set displayId on MMI WindowInfo in separated architecture`
- 本会话新增未提交改动（PC 任务）：
  - `vendor/ohemu/virt/etc/param/product_virt.para`（追加 `const.window.multiWindowUIType=FreeFormMultiWindow`
    和 `const.bms.supportAppTypes=default,phone,tablet,2in1`）
  - `out/x86_64_virt/args.gn` 里 `device_type = "2in1"`（build-only-gn 写入；已用它全量
    构建成功，产物 system.img/sys_prod.img 已含 2in1）
  - **尚未改** `vendor/ohemu/qemu_x86_64_linux_full/config.json`（SceneBoard 切换点，见 7.3）
- **回退方法**：若想回到“手机 Launcher + default 设备类型”，
  `git checkout vendor/ohemu/virt/etc/param/product_virt.para`，重编时去掉 `--device-type 2in1`
  （或把 `out/x86_64_virt/args.gn` 的 `device_type` 改回 `default` 后重建）。
- 另有历史遗留改动：`foundation/window/window_manager/interfaces/kits/napi/environmental/package.json`（1 行删除，非本次）
- 辅助脚本与调试产物已从 `/tmp/opencode/` 迁到 **`out/x86_64_virt/ohos-dbg/`**：
   - `scripts/`：`launch_diag.sh`、`start_vm.sh`（都走 out 路径 + `run/` 放 socket）、
    `inject_libs.sh`、`ser_cmd.py`、`ser_run.py`（推荐，带 bounded drain）、
    `boot_capture.py`、`vnc_swipe.py`、`touch_swipe.sh`/`touch_swipe2.sh`/`touch_tap.sh`
  - `evidence/`：`unlocked.png`（触摸解锁后的 Launcher）、`pc2in1_boot.png`/`pc2in1_after_unlock.png`
    （2in1 PC 风格锁屏与桌面）、`pc_boot.png`、`pos_a.png`/`pos_b.png`
  - `dbg/*.qcow2`：QEMU 磁盘 overlay（system.qcow2 backing 到 `out/.../images/system.img`）
  - `run/`：QEMU 串口/QMP unix socket（`ser.sock`、`qmp.sock`）
  - 构建日志：`build-pc2in1.log`（2in1 全量构建成功日志）
- `/tmp/opencode/` 已清空（3.1G → ~0.5M），仅剩几个与本次无关的历史 config/json；
  **不要再往 `/tmp` 写任何东西**（第 0 节约定）。
- 注意：`scripts/launch_diag.sh` / `start_vm.sh` 现在默认用**新构建的 system.img**
  （2in1 已固化），其 overlay `dbg/system.qcow2` 是空 overlay，backing 到当前
  `packages/phone/images/system.img`。
- **重要提示**：换过 `system.img`（或 sys_prod/userdata 等任意 `.img`）后，
  **必须重建对应的 `dbg/*.qcow2` overlay**（尤其 `userdata.qcow2`），否则 guest 会
  读到旧 overlay 遮蔽新镜像，出现黑屏/launcher 挂载失败。

## 9. 当前镜像状态

- `out/x86_64_virt/packages/phone/images/system.img`（2026-09-18 23:28 构建）：
  `const.product.devicetype=2in1`、`const.build.characteristics=2in1` 已固化。
- `sys_prod.img` 同步更新：`/etc/param/product_virt.para` 含 free-form + supportAppTypes。
- 桌面仍是**手机版 Launcher**（因 sceneboard=false），锁屏是 2in1 大布局。

## 10. 已完成的输入修复结论（上一阶段）

**图形桌面 + 输入（触摸/鼠标）已全部可用。** 三个根因、按发现顺序：

1. **MMI 连接管理器一次性建连失败后不重试**（WMS 进程）→ 修 `AllocSocketPair` 懒重连。
2. **WMS 未在 MMI SA 上线时重推 display info** → 修 `OnAddSystemAbility`。
3. **WMS 构造 MMI::WindowInfo 未填 `displayId`**（分离架构专有）→ 修 `TraverseWindowNodes`。

验证：触摸注入滑动解锁锁屏，成功进入 Launcher（见 `evidence/unlocked.png`）。

> 注意：这三个修复只服务于**分离架构（wmserver）**。若切到 SceneBoard
> 合一架构（见 7.3），`wmserver/` 不再使用，这些修复不再相关。

## 11. 【最终方案】分离架构 + 2in1 + 移植社区 pad/pc UI（2026-09-21 完成）

**结论：x86_64_virt 的 PC 风格桌面已可用。不要再走 SceneBoard 路线。**

### 11.1 参考：x86 移植社区（gitcode `ohos-porting-communities`）
其 `vendor_opc`（分支 `OpenHarmony-6.1-LTS`，本地克隆在
`out/x86_64_virt/ohos-dbg/porting/vendor_opc`）的 `x86_general` 产品：
- **不用 sceneboard**（`vendor/opc/x86_general/custom_conf/rich.json` 的
  `window_manager` features = `[]`）；`const.product.devicetype=tablet`。
- 图形极简：只 `ace_enable_gpu` + `graphic_surface`（产品再加 eglimage/texgine/upgrade_skia）。
- **PC 观感来自「pad/pc 预编译 HAP」**：`common/BUILD.gn` 的 `is_use_phone_ui=false`
  时用 `common/hap/` 下的 pad 版 Launcher/SystemUI 替换手机版（含
  `SystemUI-ScreenLock-2in1.hap`）。这些 HAP 是 **V3 签名**，
  叶子证书 SHA256 = `8E93863FC32EE238060BF69A9B37E2608FFFB21F93C862DD511CBAC9F30024B5`，
  **与本产品 `install_list_capability.json` 的 `app_signature` 完全一致 → 无需重签即可装**。
- Windows 下用 `qemu_x86_run_windows.ps1` 跑 QEMU。

### 11.2 本产品最终配置（已完成、已验证）
- `vendor/ohemu/qemu_x86_64_linux_full/config.json` **= git HEAD 原样**
  （无 graphic_2d / 无 window 覆盖；graphic 只有 `graphics_effect` + `graphic_utils_lite`）。
  ⚠️ **不要删这两个组件**：`base/update/updater/services/ui/BUILD.gn:85` 依赖
  `graphic_utils_lite`，删了会 GN 失败（`OHOS component : (graphic_utils_lite) not found`）。
- `window_manager_use_sceneboard = false`（继承默认）→ **分离架构**。
- 构建：`--device-type 2in1`；`vendor/ohemu/virt/etc/param/product_virt.para` 的
  `const.window.multiWindowUIType=FreeFormMultiWindow` + `const.bms.supportAppTypes=...`（保留）。
- `vendor/ohemu/virt/preinstall-config/install_list.json` /
  `install_list_capability.json` **已还原为 HEAD**（SceneBoard 条目已删除）。

### 11.3 已应用的 pad/pc UI（`applications/standard/hap/`，未提交）
从 `porting/vendor_opc/common/hap/` 复制：
- **覆盖**：`Launcher.hap`（module `pad_launcher`）、`SystemUI.hap`（`pc_entry`）、
  `SystemUI-StatusBar.hap`（`pc_statusbar`）、`SystemUI-ScreenLock.hap`
  （用 `SystemUI-ScreenLock-2in1.hap`，module `pc`，deviceTypes 含 2in1）。
- **新增**：`SystemUI-ControlPanel.hap`（`pc_controlpanel`）、
  `SystemUI-NotificationPanel.hap`（`pc_notificationpanel`），并在
  `applications/standard/hap/BUILD.gn` 加 2 个 `ohos_prebuilt_etc`
  （`module_install_dir="app/com.ohos.systemui"`）+ 2 个 `group("hap")` 依赖。
- `install_list*.json` **无需改**（同 bundle 目录 + 同签名）。
- 备份与原文件在 `out/x86_64_virt/ohos-dbg/verify_sep/orig_hap/`，
  改动清单见 `verify_sep/hap_swap_notes.md`。
- **回退**：把 `orig_hap/` 的文件拷回、删掉 2 个新 HAP 与 BUILD.gn 的 4 行改动即可。

### 11.4 验证证据（2026-09-21）
- 全量重建（分离架构）1h31m 成功 → `out/x86_64_virt/ohos-dbg/build-separated.log`。
- 基线（换 HAP 前）：手机锁屏 + Launcher，screendump `verify_sep/base_t0.png`
  （extrema `((84,255),(38,255),(7,255))`，97762 色）、`after_unlock.png`（130296 色）。
- 换 HAP 后（重打包 16m44s，`build-repack.log`）：
  - **PC/2in1 锁屏**（大时钟、PC 状态栏）→ `verify_sep/pc_lock.png`（96442 色）。
  - **pad/平板桌面**（应用网格 + 居中 Dock + 平板导航栏 + 状态栏）→
    `verify_sep/pc_desktop.png`（77305 色）。
  - `bm dump` 确认 `pc_entry`/`pc`/`pc_statusbar`/`pc_controlpanel`/`pc_notificationpanel`
    + `pad_launcher` 已生效；WMS 出现 `SystemUi_ControlPane`、`SystemUi_Notificatio`。
  - `hidumper -s RenderService -a screen` → `POWER_STATUS_ON, backlight=223, 1280x800@75`。
  - 输入修复仍生效：`DisplaysInfo is empty` / `Failed to initialize MMI client` /
    `Failed to obtain physical` 均为 0。

### 11.5 后续可选（未做）
- 若想要更彻底的「PC 桌面」（任务栏、自由拖动窗口），可继续沿用该路线：
  编辑 `/vendor/etc/window/resources/window_manager_config.xml`
  （社区版：`decor enable=true`、`supportedMode=floating fullscreen`、
  `defaultWindowMode=102`），本产品对应文件在 `vendor/ohemu/virt/window_config/`。
- 应用窗口目前仍是自由窗口（FreeFormMultiWindow）。

## 12. 【关键发现】QEMU 必须用 virtio-gpu-gl（virgl），否则图形栈只有最慢的 softpipe

**2026-09-21 定位**：镜像里的 GPU 驱动其实是**按 QEMU 3D 准备的**，但官方 launcher 和我们的脚本
一直用普通 `virtio-gpu-pci`（无 3D），导致 guest 只能退回 **Mesa 21.2.1 的 `softpipe`**
（单线程软光栅，极慢，缺 EGL 扩展 → 之前那些 `eglQuerySurface failed` /
`eglSetDamageRegionKHR failed` / `SetBufferColorSpace fail` 很可能就是它导致的）。

证据：
- `device/qemu/common/virt_full/hardware/gpu/x86_64/` 里带了
  **`virtio_gpu_dri.so`（virgl 驱动）**、**`libvulkan_virtio.so`（venus）**、
  `libVkLayer_MESA_*.so`、`swrast_dri.so`/`kms_swrast_dri.so`、libEGL/libGLES/libgbm。
- 镜像里 `swrast_dri.so` = **Mesa 21.2.1，只编了 `softpipe`（没有 `llvmpipe`）**。
- `foundation/graphic/graphic_2d/frameworks/opengl_wrapper/BUILD.gn:319` 引用
  `mesa3d:zink_opengl`（GL 走 zink）→ 说明 OHOS 6.1 预期的是较新的 Mesa/zink 方案。
- 官方 `packages/phone/images/qemu_profile.json` 用的是
  `["-vga","none","-device","virtio-gpu-pci"]`（**无 3D**），
  `qemu_run.sh` 的 `_display_args` 还固定 `gl=off`。

**验证方法**：把 GPU 设备换成 3D 版即可，无需重编镜像：
```sh
# 普通（旧）： -vga none -device virtio-gpu-pci
# 3D（正确）： -vga none -device virtio-gpu-gl-pci -display gtk,gl=on
```
启动后内核日志会从 `[drm] features: -virgl ...` 变成
**`[drm] features: +virgl +edid -resource_blob -host_visible`** 和 `+context_init`。
（QEMU 10.2.1 支持 `virtio-gpu-gl-pci`；本机宿主有 GPU，`gtk,gl=on` 可用。）
**注意：venus 未启用（无 `+venus`），所以 Vulkan 仍不可用**，
`/system/etc/vulkan/icd.d/icdconf.json` 还指向不存在的 `libVK_IMG.so`——
**不要走 `enable_vulkan`，要走 `enable_opengl`（virgl）**。
另外 `-display gtk,gl=on`/`egl-headless` 时 QEMU `screendump` 会报 `no surface`，
**改用 guest 内 `snapshot_display -i 0 -f /data/local/tmp/x.jpeg` 抓图**（分离架构下可用）。

**已确认**：用 `virtio-gpu-gl-pci` 启动后，guest 的 `snapshot_display` 返回真实画面
（640x480、38872 色，非黑），说明 virgl 生效。

**⚠️ 但 virgl 并不能解决 SceneBoard 黑屏（2026-09-21 实测结论）**：
用 `sceneboard=true + enable_opengl`（virgl）重建（`build-scb-gl2.log`，1h13m 成功）后，
用 `virtio-gpu-gl-pci` 启动（`+virgl` 已生效）：SceneBoard 仍然全黑——
- `LOGICAL_DISPLAY_NODE` 依旧 `RSUIContextToken: NO_RSUIContext`、`Bounds[-inf]`、无子节点；
- SceneBoard 的 18 个 `SCB*` surface 全是 `Surface Node Not On Tree`、`default-size=[0x0]`、0 buffer；
- **RS 注册渲染客户端 = 0**；`MergeToEffectiveTransactionDataMap pid:0 not valid, skip it` 仍在；
- `eglQuerySurface/eglSetDamageRegionKHR/SetBufferColorSpace` 报错在 virgl 下**依然存在**。
→ **GPU/Mesa 后端不是根因**；根因就是第 7.3.1/7.3.2 记的
「RS 渲染客户端/tokenMaskId 注册失败 → 显示节点 `NO_RSUIContext`」。
证据在 `out/x86_64_virt/ohos-dbg/verify_scbgl/`（`SUMMARY.md`、`qmp_scb.png`、`rs_allinfo.txt`、`hilog.txt`）。

### 12.1 【进行中】针对 RS 渲染客户端注册的两处平台修复（2026-09-21）

源码分析（`rs_main_thread.cpp:2673-2685` 等）给出的因果链：
1. 客户端事务经 **TF_ASYNC** 提交；服务端 stub/unmarshal 用 `GetCallingPid()` 覆盖
   `RSTransactionData::SetSendingPid()`，而 **async 调用下 `GetCallingPid()` 可能返回 0**
   （代码注释自认，见 `rs_client_to_render_connection.cpp:290-301`）。
2. `RSMainThread::MergeToEffectiveTransactionDataMap` 按 `GetSendingPid()` 归桶，
   **pid 不在 `effectiveTransactionDataIndexMap_` 就整条丢弃**
   （日志 `MergeToEffectiveTransactionDataMap pid:0 not valid, skip it`）——
   于是 `RSSetUIContextToken` / `AddChild` / `SetBounds` 全部不生效 →
   显示节点 `NO_RSUIContext`、`Bounds[-inf]`、无子节点。
3. 另一条：`RSSystemProperties::GetUniRenderEnabled()`（`rs_system_properties.cpp:195-204`）
   用 `std::call_once` **永久缓存**；若首次调用时 RS 还没连上
   （`RSRenderServiceClient::GetUniRenderEnabled()` 在 `clientToService==nullptr` 时返回 false），
   该进程会永久走 "divided render" → 不建 per-process 渲染连接 → pid 注册表为空。

**已改的 3 处（`foundation/graphic/graphic_2d`，待验证）**：
- `core/transaction/rs_unmarshal_thread.cpp`：仅当 `callingPid > 0` 才覆盖 `SendingPid`
  （否则保留客户端写入的真实 pid，与 `rs_transaction_data.cpp:232-234` 既有回退思路一致）。
- `core/transaction/zidl/rs_client_to_render_connection_stub.cpp`：同上的两处
  （sync 路径 `:360` 与 async 路径 `:411`）。
- `render_service_base/src/platform/ohos/rs_system_properties.cpp`：`GetUniRenderEnabled()`
  改为**只在得到 true 时才锁定**，false 时允许后续重试（避免过早缓存 false）。

构建日志 `build-rsfix.log`；验证时看：
`MergeToEffectiveTransactionDataMap pid:0` 是否消失、`LOGICAL_DISPLAY_NODE` 是否出现
`RSUIContextToken`/`Bounds`/子节点、`allMainAndLeashSurfaces_` 是否 >0、
`snapshot_display` 是否返回非黑画面。

**✅ 验证结果（2026-09-22 00:41，成功！SceneBoard PC 桌面已出画面）**：
用 `virtio-gpu-gl-pci` 启动（`+virgl` 生效）后：
- **`MergeToEffectiveTransactionDataMap pid:0` 完全消失**（0 次）；`connectToRenderRemote is nullptr`、
  `Surface Node Not On Tree`、`GetScreenInfoById: SendRequest nullptr` 也全部 0 次。
- `snapshot_display` **RC=0**：锁屏 39044 色（PC 大时钟），触摸上滑解锁后 **42336 色**（壁纸+应用图标+Dock）。
- `LOGICAL_DISPLAY_NODE` 有了**真实 `RSUIContextToken`**、`Bounds[0 0 640 480]`、有子节点
  （`SCBWallpaper5/SCBDesktop6/SCBScreenLock10/SCBGestureNavBar13/SCBStatusBar15/...`）。
- SceneBoard 已安装且运行；`SCBScreenSession` 不再每 10s 重试。
- 截图：`out/x86_64_virt/ohos-dbg/verify_rsfix/rsfix_t0.png`（锁屏）、
  `rsfix_after_unlock.png`（桌面）。
- 遗留非致命：`eglQuerySurface/eglSetDamageRegionKHR/SetBufferColorSpace` 告警仍在（66 次）但不影响出帧；
  `allMainAndLeashSurfaces_.size()` 仍 0（但 `allMainAndLeashSurfaceDrawables_.size()`=7，出帧正常）；
  `ClientNodeTreeDump` 仍空（次要 dump 机制）。

**结论**：SceneBoard 黑屏的根因就是上面两处 RS 平台问题（async 事务 pid 被置 0 后整批丢弃 +
`GetUniRenderEnabled()` 过早永久缓存 false）。**前提是 QEMU 必须用 `virtio-gpu-gl-pci`（virgl）**，
否则只有 softpipe，画面依旧出不来。体验方式见第 13 节。

## 13. 怎么体验（SceneBoard PC 桌面）

**一条命令**（前台，会弹出 GTK 本地窗口；约 1~2 分钟进锁屏，鼠标按住上滑解锁进桌面）：
```sh
bash /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/scripts/run_pc.sh
```
- 脚本用 `-device virtio-gpu-gl-pci,xres=1280,yres=800 -display gtk,gl=on`（**必须 3D**），
  overlay 用 `out/x86_64_virt/ohos-dbg/dbg/*.qcow2`，并做 hdc hostfwd（`127.0.0.1:5555`）。
- 退出：关窗口，或 `pkill -9 -f 'qemu-system-x86_64 -[m]achine'`。
- 抓图（GTK gl=on 时 QEMU `screendump` 会报 `no surface`）：guest 内
  `hdc shell "snapshot_display -i 0 -f /data/local/tmp/x.jpeg"`，再 `hdc file recv`。

**官方 launcher（`qemu_run.sh`）默认不能出画面**：`packages/phone/images/qemu_profile.json` 用的是
`virtio-gpu-pci`（无 3D），且 `qemu_launcher_lib/launcher.py` 的 `_display_args` 固定 `gl=off`。
要用官方 launcher 体验，需要把 profile 的 `graphics.device_args` 改成
`["-vga","none","-device","virtio-gpu-gl-pci,xres=1280,yres=800"]` 并把 `gl=off` 改成 `gl=on`
（这两处在构建输出里，重新构建会被覆盖；源头在 `device/qemu/` 下）。

**⚠️ 使用注意（2026-09-22 实测补充）**：
- **锁屏必须"触摸上滑"解锁，鼠标按住拖动不解锁**（OHOS 锁屏只认触摸手势）。
  已在 `scripts/unlock_touch.sh` 提供 guest 内触摸注入脚本，
  并在 `scripts/pc_session.py` 里做成**开机自动上滑解锁**（`run_pc.sh` 已内置调用），用户无需手动操作。
- **黑屏根因不是 `power_mode_config.xml`**：是 **SceneBoard 自己调用
  `power.overrideScreenOffTime(10000)`**（日志 `PowerState: setoff … ->10000 …U:20010009`），
  把熄屏时间压到 10s → ~10s 后 DIM→INACTIVE→SLEEP。
  已在镜像里注入 init 服务压制（`/system/bin/zz_keepawake.sh` +
  `/system/etc/init/zz_keepawake.cfg`，boot 阶段循环 `power-shell timeout -o 86400000`），
  同时把 `power_mode_config.xml` 的 101/102 改成 `-1`。验证 4 分钟无 `PM: suspend entry`。
  **回退**：删除这两个注入文件 + 用仓库源覆盖回 `power_mode_config.xml`，再 fsck + 重建 overlay。
- 输入设备三种都可用：`virtio-multitouch-pci`(触摸) / `virtio-mouse-pci`(鼠标) /
  `virtio-keyboard-pci`(键盘)；串口 `virtio_input_hid_handle_status: unknown type 20` 是无害告警。
  之前"鼠标键盘没反应"其实是因为屏幕已经黑了。
- **遗留**：GTK 后端下分辨率只有 640x480（`-device` 里的 `xres/yres` 在 egl-headless 下才生效），
  且底部有 SceneBoard 的 `SCBGestureNavBar` 手势导航条（"小白条"），均未解决。

**🚀 性能（卡顿）修复（2026-09-22）——重编并注入 Mesa 25.0.1（virgl 硬件加速）**：
- 卡顿根因：镜像里的 Mesa 是 **21.2.1，只有 `softpipe`**（CPU 软光栅）；且它走 virgl 路径时
  **`render_service` 会反复 SIGSEGV**（`kms_swrast_dri.so util_copy_rect` 等）。
- 做法：用本树 **Mesa 25.0.1**（`third_party/mesa3d`）交叉编译 x86_64-ohosmusl，并按镜像里
  21.2.1 的行为补齐 OHOS 的 **`__DRIimageLoaderExtension`（image loader / dma-buf 路线）**
  —— 关键是支持 **`EGL_NATIVE_BUFFER_OHOS(0x34E1)`**（`ohos_create_image_khr` →
  `OH_NativeWindow_GetBufferHandleFromNative` → `BufferHandle.fd` → `dri2_from_dma_bufs`，
  供 virgl 以 `WINSYS_HANDLE_TYPE_FD` 导入）。
  改动只在副本：`out/x86_64_virt/ohos-dbg/mesa_build/mesa3d-src/`
  （`src/egl/drivers/dri2/platform_ohos.c`、`egl_dri2.h`），**仓库源码未动**。
- 注入：`libEGL.so.1.0.0 / libGLESv1_CM.so.1.1.0 / libGLESv2.so.2.0.0 / libgbm.so.1.0.0 /
  libgallium-25.0.1.so`（驱动静态链进 libgallium，**不需要单独放 `virtio_gpu_dri.so`**）。
  注入脚本 `mesa_build/inject_loader.dbgfs`；备份 `mesa_build/orig/`；回退 `mesa_build/revert.dbgfs`
  （`debugfs -w -f revert.dbgfs system.img` → `e2fsck -f -y` → 重建 overlay）。
- 验证：**RS 不崩**；`hidumper -s RenderService -a gles` →
  **`GL_RENDERER: virgl (Mesa Intel(R) Graphics (PTL))`, `GL_VERSION: OpenGL ES 3.2 Mesa 25.0.1`**；
  密集负载（连续 40 次通知面板开合）**掉帧 0**（>66/>33/>16.67ms 全 0），基线同负载下 RS 反复 SIGSEGV。
  证据 `out/x86_64_virt/ohos-dbg/verify_mesa/`。
- 遗留（非致命，进一步提速可做）：`eglQuerySurface(EGL_BUFFER_AGE_EXT)` /
  `eglSetDamageRegionKHR` / `SetBufferColorSpace` 仍报错 → 退化为整屏重绘（无脏区优化）；
  需在 OHOS 平台启用 `EXT_buffer_age` 并让 `query_buffer_age` 返回有效值。

**当前实现状态（2026-09-22）**：
- 架构：合一架构 `window_manager_use_sceneboard = true`；
- 图形：`graphic_2d` features = `rs_enable_eglimage / use_igraphics_extend_hooks=false /
  enable_opengl / ace_enable_gpu / rs_enable_uni_render / use_texgine`（**无 vulkan、无 upgrade_skia**）；
- 设备类型 `2in1`；`vendor/ohemu/virt/preinstall-config/` 含 SceneBoard 预装/特权条目；
- 3 处 window_manager 的 `connectToRenderToken` 修复 + 3 处 RS 平台修复（见 12.1）。
- 分辨率目前 640x480（QEMU 默认），脚本里已加 `xres=1280,yres=800`。

**当时正在做的事（下个会话续）**：用
`sceneboard=true + enable_opengl（不加 vulkan/upgrade_skia）` 重建（`build-scb-gl.log`），
然后用 `virtio-gpu-gl-pci` 启动，验证 SceneBoard 黑屏是否被 virgl 解决。
启动脚本 `out/x86_64_virt/ohos-dbg/scripts/launch_gl_test.sh` 是 3D 版模板
（`-device virtio-gpu-gl-pci -display gtk,gl=on`）。
另注：`build/config/compiler/BUILD.gn` 的 `default_include_dirs` 里加了
`//third_party/vulkan-headers/include`（当时为修 vulkan 构建），开启 vulkan 时还需要
`VK_USE_PLATFORM_OHOS` 与 `SK_VK_PARTIALRENDER` 两个宏才能编过。

## 14. 【已解决】Mesa 25 + virgl 真正上屏（2026-09-22）

> 背景：第 13 节把 Mesa 25 注入后，`snapshot_display` 有画面、RS 不崩，但**实际屏幕全黑**。
> 本轮定位并修复。详见 `out/x86_64_virt/ohos-dbg/verify_mesa/SUMMARY_onscreen.md`。

### 14.1 可靠"上屏" oracle（必记，之前失败的原因）
3D（`-device virtio-gpu-gl-pci`）时 QMP `screendump` 报 `no surface`，**不能**用来验证。
两条可用 oracle：
- **宿主抓 QEMU GTK 窗口**（最直接，= 用户看到的画面）：
  QEMU 用 `GDK_BACKEND=x11` + `-display gtk,gl=on` 启动，然后
  `GDK_BACKEND=x11 python3` + `Gdk.pixbuf_get_from_window(window_stack[0], …)` 存 PNG。
  Wayland 下普通 Gdk 拿不到 window_stack，**必须 x11**。
- **guest 内 `drmfb_dump`**（读 HDI 实际扫描输出的 CRTC fb）：
  `out/x86_64_virt/ohos-dbg/tools/drmfb_dump.c` → `gcc -static -I/usr/include/libdrm -ldrm`
  → `hdc file send` → `/data/local/tmp/drmfb_dump /data/local/tmp/x.ppm`。
  配合 `/sys/kernel/debug/dri/0/framebuffer`、`/sys/kernel/debug/dri/0/state` 看 fb 的
  `allocated by / format / imported`。

### 14.2 根因（一句话）
OHOS 显示 HDI 从 **guest 内存**取内容扫描输出（自己分配的 XR24 fb / 层合成拷贝）；
而 virgl 在**宿主 GPU** 渲染进 host texture，**从未 transfer 回 guest dma-buf**，HDI 只能拿到
全 0 内存 → 黑屏。2D softpipe 正常是因为 CPU 直接写 guest 内存。
- 修复前证据：GTK 窗口纯黑、DRM fb 纯黑，但 RS `snapshot_display` 40322 色。
- 顺带更正：之前"2D 模式 92% 黑"的对照**无效**——2D 下 Mesa 25 因无 virgl
  `create_screen FAILED` → render_service 失败 → init 约 13s 重启（停在 boot console）。

### 14.3 修复（只改副本 `mesa_build/mesa3d-src/src/egl/drivers/dri2/platform_ohos.c`）
1. 新增 `ohos_sync_back_buffer()`：在 `ohos_swap_buffers()` 里 flush 之后、
   `NativeWindowFlushBuffer` 之前，对 `dri2_surf->dri_image_back` 调用
   `dri2_map_image(ctx, img, …, __DRI_IMAGE_TRANSFER_READ, …)` + `dri2_unmap_image()`
   **强制 virgl 把渲染结果 host→guest transfer 回 dma-buf**。
2. `dri2_initialize_ohos()`：`dri2_create_screen` 失败时回退 `driver_name="swrast"`
   （让 Mesa 25 在 2D/无 virgl 设备上也能起来，不再 panic）。
- 构建：`cd mesa_build && ninja -C build-x86_64 && ninja -C build-x86_64 install`，
  再 `llvm-strip` 拷到 `stage/`，用 `inject_loader.dbgfs` 注入。

### 14.4 验证结果（3D virgl）
- GTK 窗口 **108921 色 / 0% 黑**（桌面）→ `verify_mesa/onscreen_3d_gtk.png`
- DRM 扫描输出 fb **46157 色 / 0% 黑** → `verify_mesa/drm_scanout_3d.png`
- `GL_RENDERER: virgl (Mesa Intel(R) Graphics (PTL))`，`create_screen OK driver=virtio_gpu`
- 密集负载（面板开合 x25）：`hitchs` `>66/>33/>16.67ms` 全 0，render_service 不重启
  （基线 vendor softpipe 同负载反复 SIGSEGV）

### 14.5 怎么跑 / 回退
- 3D 上屏体验：`GDK_BACKEND=x11 bash out/x86_64_virt/ohos-dbg/scripts/run_gl_gtk.sh`
  （`-device virtio-gpu-gl-pci -display gtk,gl=on`，overlay 用 `dbg/*.qcow2`）
- 2D 基线：`bash scripts/run_pc.sh`
- 回退到 vendor 21.2.1：`debugfs -w -f mesa_build/revert.dbgfs <system.img>` → `e2fsck -f -y`
  → 重建 `dbg/*.qcow2`（尤其 `system.qcow2`）。
- 当前 `system.img` 已是 **Mesa 25 + 上述两处修复**（可用、上屏成功）。

## 15. Mesa 25 上屏修复第二轮：方向翻转 + 分辨率/PC 布局（2026-09-22 下午）

> 承接 §14。本轮在**不改仓库源码**的前提下，只改 `mesa_build/mesa3d-src/` 副本。
> 三处产物证据在 `out/x86_64_virt/ohos-dbg/verify_dir/` 与 `verify_mesa/`。

### 15.1 修「整体上下翻转」（已解决）
- 现象：锁屏时间/文字**上下镜像**（不是 180° 旋转；把截图做 `FLIP_TOP_BOTTOM` 后文字变正）。
- 根因：OHOS 扫描输出按**上→下**（row0=顶），而 GL/DRI 窗口缓冲是**下→上**（row0=底），
  virgl 渲染结果经 `transfer_get` 回传到 guest dma-buf 后就是倒的。
- 修法：`platform_ohos.c` 的 `ohos_sync_back_buffer()`：在 `dri2_map_image(...TRANSFER_READ)`
  拿到线性映射后、`dri2_unmap_image()` 前，**按行原地翻转**（用 `dri2_query_image` 取
  FOURCC 推 bpp；`row_bytes = min(stride, w*bpp)`；swap row y ↔ row h-1-y）。映射指针就是
  dma-buf 本身（virgl 对非 blob/非 staging 资源走 `VIRGL_TRANSFER_MAP_HW_RES`）。
- 验证（os oracle）：GTK 窗口截图 `verify_dir/flip_t0.png`（锁屏文字正）、
  `flip_desktop2.png`（桌面正）；`drmfb_dump` 扫描输出 `verify_dir/scan640.png`（计算器窗口，
  标题栏在顶、按钮在右上）——方向正确。

### 15.2 拖影/卡：定位结果（未彻底解决）
- **不是** buffer-age/脏区问题：`eglQuerySurface(EGL_BUFFER_AGE_KHR)` 失败
  （我们的 EGL 未 advertise `EXT_buffer_age`/`KHR_partial_update`，因为 virgl 无
  `set_damage_region`），RS 取到 age=-1 → `MergeToEffective...` 里 `SetBufferAge(0)`、
  **整屏重绘**（日志 `MergeDirtyHistory with invalid buffer age -1`）。全屏重绘本身正确。
- **不是**回传时序/部分刷新：`ohos_sync_back_buffer` 是在 `FlushBuffer` 前做**整屏**
  `TRANSFER_READ`，且 virgl 在 `transfer_get` 前后都 `resource_wait`（阻塞到完成），
  `FlushBuffer` 传 fence=-1 时内容已就绪。
- **实际现象**：动画/锁↔桌快速切换时偶发**单帧「小图平铺」**（把整屏内容压缩成约
  120px 周期的小图重复，`verify_dir/anim_flip/090_8.268.jpg`、`grid_zoom.png`）。
  该帧在**加翻转修复之前就存在**（`anim_panel/048`），所以与翻转无关。`snapshot_display`
  也是同一结果 → 是 **RS/合成端渲染出的内容**，不是 scanout 读错 stride（HDI 客户端
  缓冲恒为 640x480/stride2560，`SetDisplayClientBuffer size=1228800`）。
- 判断：属于**合成/模糊特效路径**（面板/锁屏切换时对离屏 snapshot 的采样或上传 stride）。
  稳屏时 RS 输出干净；仅过渡帧出现，故表现为「拖影/卡」。**修法需要动 RS 核心或确认
  virgl 的 `GL_UNPACK_ROW_LENGTH`/sampler wrap 处理**，本轮未做（不动仓库源码）。
- 可对比数据：40 次面板开关负载 `hidumper -s RenderService -a 'hitchs ScreenNode'`
  `>66/>33/>16.67ms` 全 0（帧耗时正常），但过渡帧有上述平铺。

### 15.3 分辨率：640x480 → 1280x800（成功）+ PC 布局结论
- 关键：`-device virtio-gpu-gl-pci,xres=1280,yres=800` 在 **GTK 后端被忽略**（EDID 首选
  =640x480，`drm_modes` 显示 mode[0] type=0x8 PREFERRED；GTK 窗口也 resize 不动）。
- **正确做法**：`-display egl-headless,gl=on -vnc 127.0.0.1:24` + `edid=off` + `xres/yres`。
  此时 kernel `virtio_gpu` 用 `GET_DISPLAY_INFO` 的 w/h 加一个 **preferred CVT 模式**：
  `drm_modes` mode[0] 变成 `1280x800 type=0x8`，`hidumper` 报
  `render resolution=1280x800, activeMode 1280x800@60`（脚本 `scripts/run_res.sh`，
  可用 `VRES/VRESY` 覆盖）。
- **PC 布局结论：分辨率不是开关**。1280x800 与 640x480 下，SceneBoard 的桌面/窗口风格
  基本相同：点开计算器**两种分辨率都有 PC 式标题栏**（`计算器` + 最小化/最大化/关闭），
  差别只是 1280x800 桌面图标带文字标签、更清晰；**两者都没有任务栏**。
  `persist.sceneboard.ispcmode=true` 运行时/重启后也**没有**出现任务栏
  （`const.product.has_buildin_screen` 未设→默认 1；`const.window.support_window_pcmode_switch`
  未设→false）。证据：`verify_dir/res_lock.jpeg`(1280x800 锁屏)、`res_desk.jpeg`(1280x800 桌面)、
  `res_app.jpeg`(1280x800 计算器带标题栏)、`d640.jpeg`/`d640app.jpeg`(640x480 对照)。

### 15.4 产物 / 回退
- 改动仅：`mesa_build/mesa3d-src/src/egl/drivers/dri2/platform_ohos.c`
  （新增 `ohos_fourcc_bytes_per_pixel()` + 翻转行序）。
- 构建：`cd mesa_build && ninja -C build-x86_64 && ninja -C build-x86_64 install`，
  再 `llvm-strip --strip-unneeded` 拷到 `stage/`（5 库）。
- 注入：`bash mesa_build/inject_m25.sh`（内部 `inject_loader.dbgfs` + `e2fsck -f -y` +
  重建 `dbg/system.qcow2`）。
- 回退：`debugfs -w -f mesa_build/revert.dbgfs <system.img>` → `e2fsck -f -y` → 重建 overlay
  （回到 vendor 21.2.1，无翻转、方向会**再次**变倒，仅在确认不想要该修复时用）。
- 当前 `system.img` = **Mesa 25 + 翻转修复**，640x480 实验证方向正确、可上屏。
- 新增脚本：`scripts/run_recon.sh`（GTK X11 便于宿主 Gdk 抓图，无自动解锁）、
  `scripts/run_res.sh`（egl-headless 1280x800）、`scripts/gtk_shot.py`、`scripts/gtk_resize.py`、
  `scripts/anim_cap2.py`、`tools/drm_modes.c`、`tools/tapgen.sh`。

## 16. 【已达成】任务栏式 PC 桌面 —— 自己构建 PC 产品版 SceneBoard（2026-09-22 晚）

> 一句话：**PC 桌面 = `window_scene_board` 仓的 `product/pc`（module `pc_sceneboard`）**，
> 它既不在开源 manifest、也没有预编译 HAP，**必须自己用 hvigor 构建**后替换掉预装的手机版。
> 完整复现步骤 + 截图见 `out/x86_64_virt/ohos-dbg/PC_DESKTOP_STATUS.md`。

### 16.1 为什么"开了 sceneboard 开关还是没有 PC 桌面"
- **开源 manifest 里没有 `window_scene_board`**：
  `grep -c window_scene_board .repo/manifests/ohos/ohos.xml` = **0**
  （window 子系统只有 `window_window_manager`/`_lite`/`_cangjie_wrapper`）。
  加它的 PR **#2660（release）/ #2661（master）都还没合入**，路径
  `applications/standard/window_scene_board`，group 含 `ohos:standard`。
  **所以不管 `-b master` 还是 `-b OpenHarmony-7.0-Release`，`repo sync` 都拿不到它**——
  这不是漏 sync，也不是被 `-g ohos:standard` 过滤。
- 开源 release 把系统应用以**预编译 HAP**（`applications_hap`）发，里面**只有手机产品版**
  （`module: phone_sceneboard, deviceTypes:[default,tablet]`），它**不集成**
  `feature/smartdock`（任务栏）/`feature/pcmode`/`product/pcbase` → 只有平板式桌面，
  且 `pcService.statusBar`、`pc_mode_gridlayout_info`、`hw_launcher_2in1_pc_workspace.json` 全缺。
- 源码仓的官方 `BUILD.gn` 依赖 `//vendor/binary/...`（华为内部 hvigor 工具链）→ 走 OHOS
  `build.sh` 构建不了；**但用 DevEco CLI 的 hvigor 独立构建可以**（见 16.2）。

### 16.2 构建配方（已验证；全部在 `out/` 下，不动仓库）
分支选 **`OpenHarmony-7.0-Release`**（`build-profile.json5` 里 `compileSdkVersion 26.0.0`
与本地 `prebuilts/ohos-sdk/linux/26.0.0`（26.0.0.105）匹配；`master` 分支要 API 23，本地没装）。
```sh
git clone --depth 1 -b OpenHarmony-7.0-Release \
  https://gitcode.com/openharmony/window_scene_board.git \
  out/x86_64_virt/ohos-dbg/porting/scb_src

# SDK：hvigor 要「新管理模式」布局 <sdkRoot>/26.0.0/{ets,js,native,previewer,toolchains}
# （hvigor 代码 sdkmanager-common：API26+ 用 platformVersion 做目录名；直接指 ets 那层会报
#  "The SDK management mode has changed."）
cp -a prebuilts/ohos-sdk/linux/26.0.0 out/x86_64_virt/ohos-dbg/porting/sdk/26.0.0
printf 'sdk.dir=.../porting/sdk\nnodejs.dir=<node v18 dir>\n' > porting/scb_src/local.properties

# 仓里自带的接口 d.ts 打桩进 SDK（@ohos.pcService.statusBar / sceneSessionManager / window ...）
cd porting/scb_src && node hvigor/update-sdk-interface.js <sdkRoot>/26.0.0

# 依赖：85 个模块目录（scripts/scb_ohpm_install.sh，约 15 分钟）
# 不装 → HAR 依赖资源不合并 → 报 $media:icon / $color:scb_intent_start_window_background 未定义
# 另需补 product/pc 缺的 icon.png（开源分支没带）：
#   cp product/phone/src/main/resources/base/media/icon.png product/pc/src/main/resources/base/media/

# 构建（scripts/build_scb_pc.sh）
export NODE_HOME=<prebuilts/build-tools/common/nodejs/node-v18.20.1-linux-x64>
export JAVA_HOME=/home/katax/.gradle/jdks/jetbrains_s_r_o_-17-amd64-linux.2  # 否则 spawn java ENOENT
export PATH=$JAVA_HOME/bin:$NODE_HOME/bin:/home/katax/.local/deveco/command-line-tools/bin:$PATH
hvigorw assembleHap --mode module -p module=pc_sceneboard --no-daemon \
  -p debuggable=false -p build_mode=release -p hvigor-obfuscation=true
# → product/pc/build/default/outputs/default/pc_sceneboard-default-signed.hap
```
- 工具：DevEco CLI `hvigorw` **6.26.4**、node **v18.20.1**、ohpm **26.0.0.630**、JBR **17**。
- 产物 **95,183,981 B**：module `pc_sceneboard`、bundle `com.ohos.sceneboard`、
  `apiReleaseType: Release`、`deviceTypes:[default]`、**含 `libs/x86_64/*.so`**（关键，
  `libLayoutRotatePacking.so`/`libc++_shared.so`）。
- 签名：HAP 证书 `0716E4E8...`；profile 的 **distribution 证书 = `8E93863F...24B5`**，
  与 `vendor/ohemu/virt/preinstall-config/install_list_capability.json` 里
  `com.ohos.sceneboard` 的 `app_signature` 一致 → **授权条目无需改**。

### 16.3 注入 + 验证
```sh
{ echo "rm /system/app/SceneBoard/SceneBoard.hap"
  echo "write <...>/pc_sceneboard-default-signed.hap /system/app/SceneBoard/SceneBoard.hap"; } \
  | debugfs -w out/x86_64_virt/packages/phone/images/system.img
e2fsck -f -y out/x86_64_virt/packages/phone/images/system.img
bash out/x86_64_virt/ohos-dbg/scripts/rebuild_overlays2.sh   # 必须全新 userdata
GDK_BACKEND=x11 bash out/x86_64_virt/ohos-dbg/scripts/run_gl_gtk.sh
```
结果（`out/x86_64_virt/ohos-dbg/verify_pcscb/`）：
- `desktop.png`：**底部任务栏**（应用中心 + 时间 下午8:04/9月22日 + 通知铃铛）、桌面图标带标签、
  **无手势小白条**；`app_calc2.png`：计算器为**自由窗口**（标题栏含图标/名称 + 最大化/最小化/关闭），
  任务栏出现运行中应用图标。
- 日志（去掉命令回显后）：`pcService` **0**、`isDragFromSideBar` **0**、`pc_mode_gridlayout` **0**、
  `no such table` **0**、`get2in1PcLayoutConfigFile` **0**、sceneboard jscrash **0**；
  `SCBTM: registerTransitionController ... SmartDock_AppIcon_Container_...appcenter/recents.MainAbility`。

### 16.4 产物/回退
- 备份：`out/x86_64_virt/ohos-dbg/scb_hap_swap/pc_sceneboard_x86.hap`（新）；
  手机版备份 `scb_hap_swap/SceneBoard_7.0_signed.hap`。
- 回退：用手机版 HAP 覆盖回去 → e2fsck → 重建 overlay（回到平板式桌面）。
- 遗留：`@ohos/pcsmartdock` 的 `SuggestMenuModel.ts` 非致命报错；HAP 里 `libmultimodalinput.so` 只有 arm64。

### 16.5 分辨率 / 鼠标 / 光标（2026-09-22 晚 二轮，均已解决）
- **分辨率**：GTK 后端锁死 640x480（`xres/yres`、`edid=off` 都无效）。
  要 **1280x800** 必须 `-device virtio-gpu-gl-pci,xres=1280,yres=800,edid=off
  -display egl-headless,gl=on -vnc 127.0.0.1:24`（脚本 `scripts/run_gl_vnc.sh`，用 VNC 客户端看）。
  实测 `hidumper -s RenderService -a screen` → `render resolution=1280x800, activeMode 1280x800@75`。
- **鼠标**：**只能用相对设备 `virtio-mouse-pci`**。
  `usb-tablet`（绝对）guest 认得出但 **MMI 不认**（`InputWindowsManager: get deviceId failed:4`），
  光标不动；相对鼠标实测能驱动 RS 里 `Name [pointer window]` 节点的 `Bounds`。
- **"花屏白块" = 陈旧光标缓冲**：OHOS 光标是 MMI 用 RS surface node 软件绘制的
  （`Name [pointer window]`、64x64、`PositionZ[9999]`、直接挂在逻辑显示节点上）。
  鼠标事件进不来 → 光标缓冲从未绘制 → 显示该内存旧内容（带彩边白色大字/乱块），
  伴随 `RSSurfaceWatermarkHelper::DrawCommSurfaceWatermark Name:pointer window ... count is zero`。
  修好鼠标后白块消失。
- 两个**误导性日志**别追：`MouseTransformProcessor: displayinfo get failed, use default acclerate`
  （只是回退默认加速）、`MouseTransformProcessor: Mouse write failed , ret:1`
  （是 `HandleReportMouseResponseTime()` 里 DFX `HiSysEventWrite` 失败，与光标无关）。
- 证据：`out/x86_64_virt/ohos-dbg/verify_pcscb/`（`vnc_desktop.jpeg` 1280x800 桌面+右键菜单、
  `anim_3.jpeg` 自由窗口、`artifact_zoom.png` 陈旧光标特写、`rs_allinfo.txt` RS 节点树）。

### 16.6 分辨率/2D 路线：参照社区 x86 镜像（2026-09-22 深夜）
- 社区 `ohos-porting-communities/vendor_opc` 的 `x86_general/qemu_x86_run_windows.ps1` 用
  **2D**：`-device virtio-gpu-pci,xres=1280,yres=720 -display sdl,gl=off` + `virtio-mouse-pci`。
  **`xres/yres` 只在 `gl=off` 时生效**。
- 我们实测：**`-device virtio-gpu-gl-pci,xres=1280,yres=720 -display sdl,gl=on`** = 1280x720 +
  本地窗口 + virgl（脚本 `scripts/run_3d_sdl.sh`）；`egl-headless,gl=on -vnc` = 1280x800。
  `gl=off` 时 QMP `screendump` 可用，`gl=on` 时不可用（用 `snapshot_display`）。
- **我们的 2D 走不通**：Mesa 25 是 `-Dgallium-drivers=virgl,softpipe`（**无 llvmpipe**，
  且设备无 `libLLVM`）；2D 时回退 `swrast` 后 `dri2_from_dma_bufs` 失败
  （`failed to create DRI image from fd`）→ 全黑。
- **试过 kms_swrast 回退 → render_service 反复崩溃 → 内核 panic**（脏状态），**已回退**并留注释。
- **正确修法**：给 `platform_ohos.c` 的 `swrast_loader_extension` 补 `getImage`/`putImage`
  （软件路径做 CPU 拷贝），无 virgl 时用 `swrast_loader_extensions` 取代 `image_loader_extensions`。
- virgl 路径仍有两个未解问题：**backdrop blur 坏**（虚化/竖条纹，`persist.sys.graphic.blurEnabled=0`
  无效）、**光标图形不绘制**（节点位置正常）——很可能在 2D 软件路径下自然正常。

### 16.7 【已修复】光标不绘制（2026-09-23）
- 根因：**RS 侧竞态**——开机早期 MMI 建的 `pointer window` surface node **从未被 RS 消费 buffer**
  （`hitrace graphic` 里该 node 无 `AcquireBuffer`），RS 合成陈旧/空内容；MMI 绘制本身正常。
  `RSSurfaceWatermarkHelper ... water mark count is zero` 是**误导日志**（对所有 surface 每帧都打）。
- 修法（MMI workaround）：`pointer_drawing_manager.{h,cpp}` 首次建出指针窗口后，安排 **3 次延时
  `SwitchPointerStyle()`（2s/6s/15s）**重建节点+重绘；**编进 `libcursor_drawing_adapter.z.so`**
  （不是 `libmmi-server.z.so`），注入 `/system/lib64/`。
- 验证：`Recreate pointer window attempt:N` 日志；DRM 扫描输出 diff **2220 像素**、放大可见白色箭头光标；
  证据 `out/x86_64_virt/ohos-dbg/verify_cursor/`。回退：`git checkout --` 那 2 个文件 → 重编 → 注入 → e2fsck → 重建 overlay。
- **更正（2026-09-23）**：所谓"backdrop blur 坏/竖条纹"**主要是我方实验的副作用** ——
  `persist.sys.graphic.blurEnabled` 是 **persist 参数**（写盘、重启后仍生效）；早前把它设成 0 后
  面板不再绘制背景 → 看起来像透明/竖条纹。**恢复到 1** 后毛玻璃正常
  （实测与 σ=64 高斯模糊壁纸相关性 0.92；菜单/任务栏是 RS filter cache + HPS blur，通路本身是好的）。
  **教训：调完 `persist.*` 参数必须复位**（`param set persist.sys.graphic.blurEnabled 1` + 重启 RS/guest）。
- 仍未解决：**动画过渡帧偶发"整屏小图平铺"**（§15.2，真正的 RS/virgl 离屏快照采样/stride 问题，未定位到代码点）；
  毛玻璃有 ~3-5% 横向条带残差（HPS 下采样模糊固有，非致命）。

### 16.8 【已修复】3D 下"首次弹菜单毛玻璃只画一半"（2026-09-23，RS workaround）
- 现象（**3D/virgl 专属**）：冷启动后**第一次**弹桌面菜单，backdrop 毛玻璃**只画上半部分**；
  **动一下鼠标即自愈**。稳定复现 = 冷启动后不动鼠标直接弹菜单（oracle：菜单下半亮度≈140 坏 / ≈220 好）。
- 根因收窄：**不在 filter cache 逻辑**（坏态日志显示区域与 `filteredOut` 像素都完整），
  而在 **RS 渲染结果未落到显示缓冲**（virgl 合成/呈现竞态，**底层未定位**；疑与 §15.2 同源）。
  已验证无效（别重试）：改 `rs_filter_cache_manager.cpp`、`cachedblurpartialrender=0`、`uni.partialrender=0/5`、
  `HpsBlurEnable=0`、`filterCacheEnabled=0`。
- 修复（`foundation/graphic/graphic_2d`，3 文件，已注入）：`rs_uni_render_visitor.cpp::PostPrepare()` 检测到
  带 `GetBackgroundFilter()` 的节点 → `RSMainThread::NotifyBackdropFilterNodeAppeared(id)` → 对**每个首次出现的
  backdrop filter 节点**做一次 `SetDirtyFlag()+ForceRefreshForUni()`（等价鼠标移动/`RepaintEverything()`）；
  限流 `≤12 次`、间隔≥1s、仅首个 filter 后 10 分钟内。
- 验证：**5 次冷启动不动鼠标**弹菜单，下半亮度 **215.8**（基线 137.8）✓；`hitchs` 全 0；RS 无崩溃。
  证据 `out/x86_64_virt/ohos-dbg/verify_rsbugs3/`。回退：`git checkout --` 那 3 文件 → 重编 `librender_service` → 注入 → e2fsck → 重建 overlay。
- 当前 3D 推荐启动：**`SDL_VIDEO_HIGHDPI_DISABLED=1 bash scripts/run_3d_sdl_blob.sh`**（1280x720、virgl、`blob=on,hostmem=2G`）。
  仍存：**每帧全屏回读+CPU 行翻转**（Mesa 侧，3D "卡"的真正来源，未优化）。

## 16.9 【已修复】3D 下右键菜单/任务栏毛玻璃只画上半 —— 真正根因 + 1 行修复（2026-09-23 晚）

> 承接 §16.8（那个 RS 首次 backdrop 强制刷新 workaround **治标不治本**；本轮找到真正根因）。
> 详细过程与证据：`out/x86_64_virt/ohos-dbg/verify_blur2/SUMMARY.md`。

- **现象**：3D/virgl 冷启动后弹右键菜单，菜单/任务栏 backdrop 毛玻璃**只覆盖上半**（下半透出锐利壁纸）；
  `snapshot_display`（RS 重渲染）完整、`tools/drmfb_dump`（DRM 扫描真值）下半缺。
- **真正根因（本轮定位）**：`RSFilterCacheManager::DrawCachedFilteredSnapshot()` 里绘制缓存毛玻璃图时，
  **屏幕 canvas 上带着一个不完整的 region clip**（落在菜单矩形内），导致那次
  `canvas.DrawImageRect(缓存图, src, dst)` **只画了 dst 的上半**，下半保留陈旧内容。
  不是 Mesa 回传、不是大图合成、不是 damage/HDI、不是 filter cache 逻辑。
  决定性证据：在屏幕 canvas 上画一个普通不透明整屏矩形，也只落在菜单区域（clip 被限制），
  而把同一张缓存图画进**新建离屏 surface** 则**完整**（图像/绘制本身没问题）。
- **修复（1 文件 6 行）**：`foundation/graphic/graphic_2d/rosen/modules/render_service_base/src/render/
  rs_filter_cache_manager.cpp::DrawCachedFilteredSnapshot()`：`canvas.ResetMatrix();` 之后加
  `canvas.ResetClip();`（缓存图覆盖整个 `cachedRect_`，dst 是子集，重置 clip 后完整覆盖 dstRect）。
- **验收**：**5 次冷启动 × 每次连续弹 5 次菜单 + 大幅移动鼠标 = 25/25 次**，`drmfb_dump` 菜单
  上下半亮度一致（ratio 0.96~1.07；修复前 214.5/153.6 = 0.71）；`hitchs` 全 0；RS 无崩溃。
  证据 `out/x86_64_virt/ohos-dbg/verify_blur2/v{1..5}_m{1..5}.ppm`。
- **回退**：`git checkout -- rosen/modules/render_service_base/src/render/rs_filter_cache_manager.cpp`
  → 重编 `librender_service_base` → 注入 → `e2fsck -f -y` → 重建 `dbg/system.qcow2`。
- **遗留**：该 region clip 的精确来源未最终坐实（屏幕级可见区域裁剪 or filter 的
  `filterClipBounds_`）；`ResetClip` 语义等价于「该次绘制本就不应被裁剪」，正确但会放弃
  该 filter draw 的局部裁剪优化（当前 damage 本就全屏，无性能影响）。
- **排查教训（写给下一个会话）**：`GetImageSnapshot(RectI)` 的 **sub-rect 读回会误报**
  （只读到一部分），必须用**整屏读回**且注意 **GL 缓冲是 bottom-up、需按 `y=h-1-screenY` 采样**。

## 17. 真机（Intel PTL / X7-358H）准备：固件 + `pc_ptl` 产品化 + U 盘 P0（2026-09-24）

> 目标：为**真机**启动 OHOS 7.0 做"不需要用户到场"的三件事。**QEMU 路径未受影响**（回归通过）。

### 17.1 固件（已取证 + 已打包）
- **取证**（本机即目标硬件，`journalctl -k -b`）：Xe 实际加载
  `i915/xe3lpd_dmc.bin`(DMC)、`xe/ptl_guc_70.bin`(GuC 70.58.0)、`xe/ptl_huc.bin`(HuC 10.3.3)、
  `xe/ptl_gsc_1.bin`(GSC 105.0.2.1301)；WiFi `iwlwifi-sc-a0-gf-a0-100.ucode`；
  BT `intel/ibt-00a0-0041-{iml,pci}.sfi` + `ibt-00a0-0041-pci.ddc`。
- **坑**：本机固件是 `.zst`，而 `ptl/pc_ptl_standard_defconfig` **只开 XZ 压缩、未开
  `FW_LOADER_COMPRESS_ZSTD`**（defconfig:1637-1639）→ 统一放**解压后**文件。
- **落盘**：树内 `device/pc/ptl/firmware/`（`BUILD.gn` 用
  `install_images=["system","ramdisk"]`）；out `out/x86_64_virt/ohos-dbg/ptl_fw/`
  （含 `FIRMWARE_MANIFEST.md`：清单/大小/sha256/注入/回退；`ramdisk_ptl.img`）。
- **已注入**现有 `system.img` 的 `/system/lib/firmware/{xe,i915,intel}`（debugfs + e2fsck +
  重建 `dbg/system.qcow2`），guest 内 `ls` 可见。
- 依据：内核搜索 `/lib/firmware`；OHOS 沙箱 `appservice-sandbox.json:1153-1166` 映射
  `/system/lib/firmware`↔`/lib/firmware`；built-in 驱动早启动需 ramdisk 里也有一份。

### 17.2 `pc_ptl` 设备/产品化（GN 通过、设备侧可构建；全量镜像构建进行中）
- 命名/机制（关键）：**`device_name = 产品 config 的 board`**（`preloader_process_data.py:338`），
  kernel defconfig = `<board>_standard_defconfig`（`kernel.mk:94`）。故
  `board="ptl"`、`device_company="pc"`、`device_build_path="device/pc/ptl/linux_full"`，
  defconfig 用 **`ptl_standard_defconfig`**（= `pc_ptl_standard_defconfig` 副本）。
- 新增（**复用 QEMU `device/qemu/common/virt_full` 与 `vendor/ohemu/virt`**）：
  - `device/pc/ptl/{BUILD.gn,ohos.build,device.gni,linux_full/{BUILD.gn,config.gni,device.gni,bundle.json,ohos.build},firmware/BUILD.gn,cfg/BUILD.gn}`；
  - `vendor/pc/pc_ptl/{config.json,bundle.json,power_config/{BUILD.gn,power_mode_config.xml},subsystem_config_overlay.json}`；
  - `kernel/linux/config/linux-7.2/arch/x86/configs/ptl_standard_defconfig`（副本）。
- **踩坑 3 连**（都已修）：
  1. 自动 part `device_ptl:device_ptl` 需要 component `device_ptl` → 在
     `device/pc/ptl/linux_full/ohos.build` 声明之（QEMU 靠
     `build/subsystem_components_whitelist.json` 放行，新 board 不在白名单）。
  2. 继承 `virt_common_x86_64.json` 会带 `device_x86_64_virt:qemu_virt_full_x86_64`，而
     `board=ptl` 不会自动注册 `device_x86_64_virt` → 用
     `vendor/pc/pc_ptl/subsystem_config_overlay.json` 显式注册该子系统路径。
  3. `power_config` 源文件相对路径 `../../ohemu/virt/...` 在 `vendor/pc/` 下解析错 →
     改成本地 `power_mode_config.xml`。
- **验证**：`./build.sh --product-name pc_ptl ... --build-target device/pc/ptl/cfg:pc_ptl_cfg
  --build-target device/pc/ptl/firmware:pc_ptl_firmware` → **`pc_ptl build success`**；
  全量 `images` 构建已启动（`build-pc_ptl_full.log`，`out/ptl/`，约 119k 目标，**无 ccache** 故很慢）。
- **障碍/待办**：PC 产品版 `pc_sceneboard` HAP 未纳入构建（仍靠手工注入，见 §16）；
  I2C-HID/背光/WiFi/BT 的 HDF 适配未做；显示 HDI 复用已去硬编码实现（`verify_hdi`）。
- **QEMU 回归**：未改 x86_64_virt 任何文件；注入固件后重启 QEMU（`run_gl_vnc.sh`）→
  `snapshot_display` 1280x800、69539 色、0% 黑，桌面正常（证据
  `out/x86_64_virt/ohos-dbg/verify_ptl_fw/reg.jpeg`）。

### 17.3 P0 文档
- **`out/x86_64_virt/ohos-dbg/PC_ON_PTL_USB_BOOT.md`**：U 盘 GPT 布局（ESP/boot/system/
  vendor/sys_prod/chip_prod/userdata/misc，分区名决定 `/dev/block/by-name/*`）、
  `dd` 写镜像、GRUB2 `grub-mkstandalone` + `BOOTX64.EFI`、内核 cmdline（与 QEMU 差异：
  `console=tty0`、`by-name`、A 路线 `ohos.boot.hardware=virt` / B 路线 `pc_ptl`）、
  **调试通道推荐**（内置 eDP `console=tty0` 为主 + USB 网卡 `netconsole`/hdc TCP 为辅 +
  pstore；USB 串口仅在有排针时）、失败模式、不破坏 Ubuntu 的回退。
- 另注：`misc` 分区与 `by-name` 依赖 ueventd（`ueventd_device_handler.c:133,303`）。

## 18. 【已打通】WiFi 通用 nl80211 路径 + QEMU 端到端（2026-09-28）

> 详细证据/回退见 `out/x86_64_virt/ohos-dbg/verify_wifi/SUMMARY.md`。
> **一句话**：之前不是缺 nl80211 HDI，而是**产品走错了 WLAN 路径**（`feature_vendor` 默认 `hardware`
> = AP6275S，通用 nl80211 的 `libwifi_hal_default.z.so` 根本没编），且 HDF `wifi_host` **缺
> `chip_interface_service` 节点**。切到参考 PC 产品 `wukong100` 的 `vendor="default"` + chip HDI 后，
> QEMU 里用 `mac80211_hwsim` 实测到 **扫描 + 真实关联**。

### 18.1 链路（用户态，真机/QEMU 同一条）
- 服务：`wifi_manager_service`（SA 1120/1124）→ `HalDeviceManager`
  （`.../wifi_native/hal_device_manage/hal_device_manage.cpp:42,92,151`，`HDI_CHIP_INTERFACE_SUPPORT`）
  → HDI `chip_interface_service`（HDF host `wifi_host`，`libchip_hdi_driver.z.so`）
  → `libchip_controller_chip_interface_service_2.0.z.so` → vendor HAL **`libwifi_hal_default.z.so`**
  （`drivers/peripheral/wlan/chip/wifi_hal/wifi_hal.cpp:563` `genl_ctrl_resolve("nl80211")`、
  `:485 WifiGetWlanInterface()` 取 `wlan0`）→ 内核 `cfg80211/mac80211/iwlwifi`。
- WPA：`libwpa_proxy_2.0` → HDI `wpa_interface_service`（HDF host `wpa_host`）→ `libwpa.z.so`
  的 `wpa_main`（`driver=nl80211`，`wpa_common_cmd.h:46-48`）。
- 旧路径（已弃用）：`wlan_interface_service`(1.x) → `hdfwifi` 内核 HDF 驱动 → AP6275S，Intel 不可用。

### 18.2 改动（4 处，均可回退）
1. `vendor/ohemu/virt/virt_common_x86_64.json`：
   `drivers_peripheral_wlan_feature_vendor = "default"` +
   `wifi_feature_with_hdi_chip_supported = true`（x86_64_virt/pc_ptl 共用）。
2. `vendor/ohemu/virt/hdf_config/uhdf/device_info.hcs`：`wlan :: host` 内加 `wifi_chip_device`
   （`moduleName = "libchip_hdi_driver.z.so"`，`serviceName = "chip_interface_service"`）。
3. `kernel/linux/config/linux-7.2/arch/x86/configs/x86_64_virt_standard_defconfig`：
   `CONFIG_MAC80211_HWSIM=y`（**QEMU 测试用**；pc_ptl 已有 `IWLWIFI=y` 不需要）。
4. `third_party/wpa_supplicant/wpa_supplicant-2.9_standard/src/drivers/driver_nl80211_capa.c`
   `phy_info_rates`：`num_rates==0` 提前 `return NL_OK`。
   **根因**：本树 musl `calloc` 对 `n==0` 执行 `divl` 除零（反汇编
   `out/x86_64_virt/common/common/libc/ld-musl-x86_64.so.1` 的 `calloc+47`），
   hwsim 某 band `num_rates==0` → `os_calloc(0,4)` → `wpa_host` SIGFPE 反复重启。

### 18.3 QEMU 验证（`scripts/run_gl_vnc.sh`）
- `ls /sys/class/net`：`wlan0 wlan1 hwsim0 eth0`；`/sys/class/ieee80211`：`phy0 phy1`。
- CLI `/system/bin/cli_tool/executable/ohos-wifiManager`（`hdc shell` 为 **root**）：
  - `sta-enable` → `hidumper -s WifiDevice` = **`activated`**；
  - `scan-start/scan-list`：`NL80211_CMD_TRIGGER_SCAN/NEW_SCAN_RESULTS` 全通；空环境 0 BSS。
  - `/vendor/bin/hostapd`（`interface=wlan1 ssid=OHOS_TEST`）起 AP 后：
    `scan-list` 扫到 `OHOS_TEST`；`sta-connect --ssid OHOS_TEST` →
    `ASSOCIATING -> ASSOCIATED -> CTRL-EVENT-CONNECTED`，`sta-getLinkedInfo` 有 SSID/BSSID/RSSI/freq/linkSpeed。
  - 之后 `ObtainingIpaddr` 超时 deauth 重试（AP 无 DHCP，属预期）。
- **非致命**：`GetChipCaps/GetChipsetCategory failed`（通用 HAL 未实现）；`libhistogram.z.so` dlopen 失败（既有）。

### 18.4 踩坑/注意
- **全量重建会把 `device_type` 重置为 `default`**，PC 版 SceneBoard 会 4 次退出触发
  `reboot.panic` → sysrq kernel panic。构建必须带 **`--device-type 2in1`**（见 §11.2）；
  本次临时向 `system.img` 注入 `const.product.devicetype=2in1` 并关 `supportSCBCrashReboot`。
- 改内核 defconfig 后，ninja **不跟踪** `kernel/linux/config/**`；需删
  `out/x86_64_virt/packages/phone/images/bzImage` + `out/x86_64_virt/kernel.timestamp`
  再 `--build-target linux_kernel`（否则不会重编内核）。
- `--build-target wpa` / `hostapd` 只产二进制不重打镜像，需 `debugfs rm/write` + `e2fsck` + 重建 overlay。
- 以太网：QEMU `eth0` 开箱可用（netmanager 直接管内核 netdev，无需 HDI）；
  真机 USB NIC 需在 `ptl_standard_defconfig` 补 `CONFIG_USB_USBNET/R8152/CDCETHER`。

## 19. 【已解决】x86_64 浏览器空白 = 缺引擎 + 内核未开 NAMESPACES（2026-10-08）

> 详细报告：`out/x86_64_virt/ohos-dbg/fix_arkweb/SUMMARY.md`。

### 19.1 根因（两层）
1. **缺 x86_64 引擎**：`base/web/webview/ohos_nweb/BUILD.gn:26-28` 让 x86_64 直接复用
   arm64 `ArkWebCore.hap` → `/data/storage/el1/bundle/arkwebcore/libs/x86_64/libarkweb_engine.so`
   不存在 → `dlns_create failed` / `libarkweb_engine.so failed` / `NWebHelper failure`。
2. **内核 `CONFIG_NAMESPACES` 未开**（本会话新发现）：引擎加载后，渲染子进程
   `nwebspawn` 用 `clone(CLONE_NEWPID|CLONE_NEWNET)` 起 `web_render`，
   内核无 namespaces → `EINVAL(22)`（`fork child process error: 22`、
   `start render process error`）→ 仍白页。

### 19.2 修复
- **引擎**：用**已签名**的社区预编译 x86_64 HAP
  `out/x86_64_virt/ohos-dbg/porting/vendor_opc/common/hap/ArkWebCore-x86_64.hap`
  （sha256 `50cd246f…`，V3 签名叶子 `8E:93:86:3F…24:B5` = 本产品信任锚，
  bundle `com.ohos.arkwebcore`，引擎 164,924,848 B）。**无需重签**，直接替换
  `/system/app/com.ohos.arkwebcore/ArkWebCore.hap`。
- **内核**：`kernel/linux/config/linux-7.2/arch/x86/configs/{x86_64_virt,ptl}_standard_defconfig`
  加 `CONFIG_NAMESPACES=y/UTS_NS/IPC_NS/PID_NS/NET_NS=y`，重编两产品内核
  （x86_64_virt `5f87dac7…`、pc_ptl `545f460d…`，release 仍 7.2.7、`MODVERSIONS` 未开，
  既有 `.ko` 兼容）。
- **partdisk**：p2 换 HAP、p1 ESP `/boot/bzImage` 换 namespaces 内核；新 sha256
  `0a674ca6…`；压缩备份 `ohos_part_pc_ptl.pre_arkweb.{p1,p2}.img.zst` + 整盘后快照
  `ohos_part_pc_ptl.post_arkweb.img.zst`。

### 19.3 验证
QEMU（`run_gl_gtk.sh`）：引擎 `web engine libraryloaded`；渲染子进程
`NWebRenderMain start, sandbox pid=1`；**example.com 正文渲染成功**
（`fix_arkweb/ark_final.jpeg`）；`libarkweb_engine.so failed` / `fork child process error`
均为 0。真机判据见报告 §6。

### 19.4 关键坑 / 教训
- **不能从源码构建 x86_64 Chromium**：本树无 chromium 源码（manifest 无
  `chromium_arkweb`），且磁盘 100% 满（需 ~100G+）。社区配方
  `gitcode.com/openharmony-tpc/chromium_arkweb` + `build_arkweb.sh -t w -A x86_64`。
- PC 产品的 `linux_kernel` 有**独立 stamp**（`out/ptl/obj/kernel/linux/build/linux_kernel.stamp`）；
  只删 x86_64_virt 的 stamp 不会触发 pc_ptl 重编（第一次踩坑：30s 就 `BUILD_EXIT=0` 但
  bzImage 没变）。改内核 defconfig 后必须删**对应产品**的 stamp + bzImage + 共享
  `out/KERNEL_OBJ/kernel/OBJ/linux-7.2/.config`。
- 引擎版本 `5.1.0.107` < 设备壳 `7.0.0.41`，实测可用，但属遗留（建议后续用 7.0/M144 对齐）。

## 20. 【已解决】窗口焦点描边 `.outline()` 直角不跟随圆角（2026-10-09）

> 报告：`out/x86_64_virt/ohos-dbg/fix_outline2/SUMMARY.md`（产物含 HAP/RS库/镜像 sha、QEMU A/B 截图、回退）。

- **根因**：SceneBoard 主窗口装饰用 ArkUI `.outline()`（= RS **outline/outer border**），其圆角半径走**独立属性**
  `border->GetRadiusFour()`（`outlineRadius`），与窗口内容圆角 `properties.GetCornerRadius()`（`borderRadius`）**不同源**。
  outline 半径=0/未下发时：`rs_property_drawable_utils.cpp:257 GetRRectForDrawingBorder` 返回半径 0 的矩形
  （`ApplyFillStyle` 分支画“外方内圆”直角环）；`ApplyFillStyle` 假时 `rs_property_drawable_foreground.cpp:596
  DrawBorder` 走 `isZero && ApplyFourLine → PaintFourLine` 四条直线。窗口内容仍圆角 → 圆角外露直角描边。
  ArkUI 侧 `outlineRadius` 全链路正常（`js_view_abstract.cpp:4727` / `node_common_modifier.cpp:7391` →
  `view_abstract.cpp:2497` → `rosen_render_context.cpp:3564` → `RSProperties::SetOutlineRadius`）。
- **修法（2 处）**：① `porting/scb_src/.../SCBScene.ets` 主窗口恢复**单个** `.outline({width,color,radius:getOutlineRadiuses()})`
  （保留焦点颜色语义）；② RS 兜底：outline 半径为 0 时用节点 `GetCornerRadius()`（改
  `rs_property_drawable_utils.cpp` / `rs_property_drawable_foreground.cpp` / `rs_properties_painter.cpp`）。
- **产物**：HAP `75719c1d…`（95,188,068 B）；RS `librender_service_base.z.so` `1da7775b…`（→ `/system/lib64/platformsdk/`）；
  真机 `partdisk/media/ohos_part_pc_ptl.img` **`58fe658ba6…`**；备份 `…pre_outline2.img` `244b793f…`。
  QEMU 节点判据：`OutlineRadius[15]==CornerRadius[15]`，圆角处描边沿圆角（旧 RS 库+半径0 有灰直角，已 A/B）。
- QEMU 圆角验证需临时把 QEMU overlay 的 `window_manager_config.xml` `<float>` 改 `defaultCornerRadiusL`（**真机镜像未改**）。
  为腾空间删了 `route_diff/work/ovl_p2_run2.img`、`ovl_p2.img`（无引用的实验中间 overlay）。

## 21. 【已解决】bilibili 跳 m 站 = 自带浏览器强制移动 UA（2026-10-09）

> 报告：`out/x86_64_virt/ohos-dbg/fix_ua/SUMMARY.md`（产物含 HAP/补丁/镜像 sha、QEMU UA 抓包与 bilibili 桌面版截图、回退）。
- **根因**：**浏览器 app 自己**在 `applications/standard/browser/feature/browser_core/src/main/ets/web/WebPageController.ets:41-58`
  `ensureMobileUserAgent()` **无条件 `setCustomUserAgent(ua + " Mobile")`**（调用点 `feature/web/.../BrowsePageView.ets:1470`）；
  ArkWeb 引擎默认 UA 的 DeviceType 也硬编码 `Phone`（`chromium_arkweb .../arkweb_user_agent_ext.cc:70`；框架配置
  `base/web/webview/ohos_nweb/etc/web_config.xml:52` `<userAgentValue>Phone</userAgentValue>`）。→ bilibili `302 → m.bilibili.com`。
- **上游结论**：`applications_browser` 的 master/OpenHarmony-7.0-Release/weekly 各分支该函数**逐字节相同**，
  **无**桌面模式实现；`BrowserSettings.uaMode`('mobile'/'desktop') 定义了但**从未被消费**（死代码）。
- **修法**：改 `ensureMobileUserAgent()`——2in1/PC 时把默认 UA 去 `Mobile` 且 `Phone;`→`PC;`；手机/其它形态不变。
  在副本 `out/.../ohos-dbg/porting/browser_src/`（未动仓库）用 hvigor 重编 `Browser.hap`（补丁 `fix_ua/browser_ua.patch`，日志 `build_browser.log`）。
- **产物**：新 HAP `4177f282280ae78d92624648e45e1791330f958f02a466480f59394beb9dbe9e`（2,581,772 B，**与旧 HAP 同签名/profile**）；
  真机 `partdisk/media/ohos_part_pc_ptl.img` **`cb6092c7…`**（仅换 p2 内 `/system/app/com.ohos.browser/Browser.hap`）；
  备份 `…pre_ua.p2.img.zst`（777 MiB，改前 p2，精确回退）/ `…post_ua.img.zst`（825 MiB）。
- **实测**：新 UA `Mozilla/5.0 (PC; OpenHarmony 7.0) … Chrome/114.0.0.0 … ArkWeb/4.1.6.1`（**无 Mobile**）；
  对照：移动 UA `302→m.bilibili.com`、本 UA `200`；QEMU 内已开 bilibili **桌面版**（`fix_ua/bili_desktop.jpeg`）。
- **回退**：`zstd -d pre_ua.p2.img.zst` → `dd … of=ohos_part_pc_ptl.img bs=1M seek=513 count=2048 conv=notrunc`。
- **遗留**：tablet 仍为移动 UA（未改，控制影响面）；引擎仍为社区旧 x86_64（UA 显示 Chrome/114、ArkWeb/4.1.6.1）；
  其它 ArkWeb 应用 UA 不变（仅改自带浏览器）。

## 22. 【已实现】真 PTY 交互式终端（pc_ptl / x86_64，2026-10-09）

> 报告：`out/x86_64_virt/ohos-dbg/fix_hish/SUMMARY.md`（含 sha、QEMU 截图、回退）。
- **背景**：旧自研终端（`fix_shell`）是 TCP 管道 + 命令行 REPL，**非 tty 风格、不可用**；用户要求"移植 HiSH 做真正可用终端"。
- **HiSH 结论**：**本仓库没有 HiSH**；上游 `harmoninux/HiSH` 是 **qemu-ohos VM（arm64 内核 + Alpine）**、原生库仅 arm64，
  **不适合也无需移植**（我们已 root、标准 Linux 内核、同架构）。树里可用的是 `third_party/mksh`（`/system/bin/sh`）+ toybox。
- **方案**：① 真 PTY 守护进程 `ohosptyd`（`posix_openpt`+`fork`+`setsid`+`TIOCSCTTY`+`dup2`，pty↔TCP 分帧；
  子进程进 `proot Debian /bin/bash -l`，回退 mksh；沿用旧 `ohosshd.cfg`/`/system/bin/ohosshd` 路径）；② **原生 ArkTS 终端**
  （自写 VT100/xterm 解析 `model/terminal.ets` + Canvas 网格渲染 + TextInput 逐键输入，**不用 ArkWeb**）。
- **ArkWeb 不可用（教训）**：`$rawfile` + xterm.js 方案中，`javaScriptProxy`/`registerJavaScriptProxy` 均注入失败
  （`ohosBridge` undefined），且 **Web 内容不上屏**（`RosenWeb` surface 无 buffer，纯白）——该 x86_64 ArkWeb 引擎合成不通，**别再走 Web**。
- **关键 sha**：镜像 `partdisk/media/ohos_part_pc_ptl.img` = `0b695898ab6a995a3332e144a80af63b1e93ae201e3d4ae3c7f3cf39f7e45565`；
  daemon `/system/bin/ohosshd` = `b332543d546f605ef9fc6129260ed6c1da5303d0f1d40ca509c4a0d7775bc89b`；
  HAP `/system/app/Terminal/Terminal.hap` = `c6307e56431913f135e7f95794270ec874e70005fc304a096b6d0864f55f619f`；
  备份 `pre_hish.img.zst`（解压=`2b2211b2…`，仅 p2 改动）。
- **QEMU 回归**：桌面→Terminal 出现 **`root@localhost:~#`** 真提示符；`^C` 按钮生效；on-device ptycat 验 `tty=/dev/pts/0`、`TERM=xterm-256color`、`id`=root、Debian 12、Ctrl-C、SIGWINCH。
- **判据/回退/遗留**：见 `fix_hish/SUMMARY.md`（`onKeyEvent` 本镜像不触发已用 TextInput+按钮替代；软键盘 resize churn 为 QEMU 测试特有；
  Node/opencode 需在 rootfs 内 `apt install nodejs` 等）。

## 23. 【已解决】设置调“触控板灵敏度”闪退 = MMI 输入 socket 背压 + 触控板页只写 settingsData（2026-10-13）

> 报告：`out/x86_64_virt/ohos-dbg/fix_touchpad_mmi/SUMMARY.md`（含 sha、QEMU 证据、真机判据、回退）。产品 `pc_ptl`。

- **根因（file:line）**：`INPUT_EVENT_SOCKET_TIMEOUT / remote client buffer full` 只从 MMI 服务端
  `util/socket/src/uds_session.cpp:132 ReportSocketBufferFull()`（由 `:63` 重试循环 + `:85` EWOULDBLOCK 触发）上报，
  表示**客户端（设置 app）没在读自己的 MMI 输入事件 socket**。syswarning 栈显示设置主线程卡在同步 IPC：
  `BinderConnector::WriteBinder ← LoadSystemAbility ← WifiSaLoadManager::LoadWifiSa`
  （`foundation/communication/wifi/wifi/utils/src/wifi_sa_manager.cpp:54,60`，最长阻塞 2.5s）→ 拖触控板滑条的高频
  pointer 事件灌满缓冲；`INPUT_UI_TIMEOUT_TIME=8s`（`util/common/include/proto.h:62`）后 `ANRManager`（`anr_manager.cpp:175`）
  发 `APPLICATION_BLOCK_INPUT` → 冻结/闪退（无 native faultlog）。
- **触控板页修法**：`MousePage.ets`/`TouchpadPage.ets`/`TouchpadPointerSpeedController.ets` **落回 `applications/standard/settings`
  源码树**并登记 `product/phone/build-profile.json5` 的 `runtimeOnly.sources`；controller 改走
  `pointer.get/setTouchpadPointerSpeed`（**异步 promise + 显式 catch**，范围 [1,11]），**UI 线程零同步 IPC**
  （本地值只放 `AppStorage`，不再 `Settings.setValueSync`）。另 `PageRouter.ets` 的 `await router.loader()` 包 `try/catch`。
- **MMI 背压修法**：`uds_session.cpp::SendMsg` 先 `poll(POLLOUT,0)` 探测可写，**对端满就丢弃该事件并上报**（不再重试 50 次/拖住分发线程）；写半包风险由“先探测”规避。只改 `libmmi-util`（`platformsdk/`）。
- **产物**：镜像 `partdisk/media/ohos_part_pc_ptl.img` = **`c366d6d5717b8a70d2731bacef6e6a8ae735487e7fbba83ac40059f91d4c23b5`**（仅 p2：
  `Settings.hap ee8bf810…` + `libmmi-util.z.so fdc8a15d…`）；备份 `pre_touchpad_mmi.img.zst`（`9aca389c…`，1 个 .zst）。
- **QEMU**：触控板页正常，连续 6 次拖滑条**不闪退**；`INPUT_EVENT_SOCKET_TIMEOUT`/`APPLICATION_BLOCK_INPUT`/设置 faultlog 均 **0**；
  日志 `syncPointerSpeed 6` + `setTouchpadPointerSpeed {1,11,2,10,1} ok`（真写入 MMI）。证据 `fix_touchpad_mmi/verify/`。
- **遗留**：诱因 Wi-Fi SA 同步加载未改（属 `communication/wifi`）；MMI 流控只改服务端→客户端方向；触控板整页功能仍待 I2C-HID 适配。

## 24. 【已修】桌面空白真因（跑的是旧镜像）+ Aira 预装（2026-10-15）

> 报告：`out/x86_64_virt/ohos-dbg/fix_desktop_aira/SUMMARY.md`（含 sha、QEMU 证据、回退）。产品 `pc_ptl`。

- **问题1 桌面空真因**：用户真机 `/mnt/od/ohos-log/zzpslog.log` 头部 build_id=**`20261004-030120`**、GRUB sha `d60f9a93…`
  （来自 `partdisk/tmpfs_images`）——**用户跑的是 10-04 旧镜像**，其 SceneBoard `layoutInfo.json` rawfile 为空且无空 RDB 回退。
  **交付镜像（`1f1f9402`）早已含修复**（§16.7/fix_desktop_bt_grub/fix_cleanup：24 项预置布局 + 空 RDB 回退）。
  本轮再加兜底：`porting/scb_src/.../PcPageDesktopLayoutConfig.ets` 覆写 `dealNotInCCMApp()`——**仅当布局为空**时用全部已装 app 补位（正常仍是精选布局）。
  QEMU：桌面出图标（`evidence/final_desktop2.png`）、`gridlayout_info` 24 行、自由窗口可用（`ac4.png`）。
- **问题2 Aira 预装**：把 HAP 放 `/system/app/org.aira.browser/` + 加 `install_list.json`（源 `vendor/ohemu/virt/preinstall-config/`）。
  **拦路虎**：带 x86 `.so` 的第三方 HAP 会被**预装代码签名**拒绝——`CODE_SIGN: IsSupportFsVerity statx EINVAL` → `EnforceCodeSignForAppWithPluginId ret=-256`(`CS_ERR_FILE_INVALID`) →
  `install system bundle fail`（`installd_host_impl.cpp:3078-3117` / `code_sign_utils.cpp:117-131`）；`entryPathMap` 恰=HAP 里 `.so` 数量（0 个库才过）。`hdc install` 不受影响。
  → 交付用**去原生库的精简版** `Aira-v3.7.1-x86native-slim-nolibs-signed.hap`（60,099,637 B，首启预装成功、进应用中心）；
  **原生版**（adblock/download）另供 `hdc install -r fix_aira_native/Aira-v3.7.1-x86native-signed.hap`。
- **交付镜像** `partdisk/media/ohos_part_pc_ptl.img` = **`90579d5ad90902d04818986fcb0f20429b44f2cbce7f6e1260ed75a73a36d018`**；
  备份 `pre_desktop_aira.img.zst`（`1f1f9402…`）。仅改 p2（新 `SceneBoard.hap 972c50df…` + `Aira.hap` + `install_list.json`）。
- **QEMU 提示**：GTK 后端锁 640x480；要用 `-cpu host -rtc clock=host`（`-cpu max` 会让 guest 时钟跑飞触发 reboot.panic）；
  截图用宿主 `scripts/gtk_shot.py`（GDK_BACKEND=x11）；触摸 Y 轴**反向**（`raw_y=(H-guest_y)/H*32767`）。

## 25. 【已打通】Secure Boot MOK-only —— 自建 GRUB 固化进管线（2026-10-20）

> 报告：`out/x86_64_virt/ohos-dbg/fix_secure_boot2/SUMMARY.md`；根因报告：
> `out/x86_64_virt/ohos-dbg/fix_secure_boot_bisect/SUMMARY.md`。产品 `pc_ptl`（U 盘镜像）。

- **根因（上一轮定位）**：Ubuntu 的 GRUB 2.14 补丁
  `debian/patches/secure-boot/disable-efi-fallback-to-legacy.patch` 删掉了 **legacy `shim_lock` 回退**
  ⇒ GRUB 只能让**固件** LoadImage 内核 ⇒ 固件只认 db ⇒ MOK-only 下 `error: cannot load image.`。
  **从上游源码构建 GRUB**（保留回退）后，GRUB 自己用 EFI handover 装载内核，固件 db 不再需要我们的证书。
- **GRUB 固化**：配方在**仓库** `device/pc/ptl/grub/`（`build_grub.sh` + 2 个补丁 + `grub.sbat` + README），
  构建工作区/产物在 `out/x86_64_virt/ohos-dbg/partdisk/grub/`（`dist/grubx64.efi{,.signed}`）。
  补丁：① 保留 legacy `shim_lock` 装载回退（+ `ohos_force_legacy_loader=1` 开关）② `kern/dl.c` 的 `.bss` 只读修复
  （否则 legacy x86-64 handover `#PF`）③ `.sbat` 段（`grub,100,OpenHarmony GRUB`，shim ≥15 强制要求）。
  `build_grub.sh` 自检：tarball sha256、legacy 回退在不在、`.bss` 修复在不在、`.sbat` 段在不在。
- **管线改动**：`partdisk/make_partition_disk.sh` 新增 `GRUB_SOURCE`（默认 `ours`=自建 GRUB；`system`=宿主 `grub-mkimage`，仅对比）。
  `SECURE_BOOT=1` 用 `dist/grubx64.efi.signed`（同一把 MOK 私钥，build_grub.sh 里签）；`SECURE_BOOT=0` 保持旧 ESP 布局。
  ESP 布局 / `sbverify` 四项自检 / 内核签名全部保留。
- **OVMF MOK-only 端到端（已通过）**：`AuthenticodeVerify() succeeded` ×2（GRUB+内核，都走 MokListRT）、
  `Verification succeeded`、**`cannot load image`=0**、**`part_init: found 5/5`**、OHOS init 起来并发布 SA。
  ⚠️ 上一轮 `found 0/5` 的原因是**交付镜像被截断**（SMALL_IMAGE=1，备份 GPT 缺失 ⇒ 内核
  `GPT PMBR size mismatch` 不认分区表）；真机靠 `dd_and_verify.sh` 的 `sgdisk -e` 修，QEMU 里用
  `fix_secure_boot2/mktestdisk.sh` 复刻同一步即可。
- **非 SB 回归**：普通 OVMF 同一块盘 → 同样 5/5 + init（未搞坏引导）。
- **显示模式结论**：legacy handover **不设视频模式**（内核继承固件留下的模式，QEMU 里 800×600）且**早期屏幕无控制台**
  （`Console: colour dummy device 80x25`）；EFI stub 路径则由 stub 设成 1280×800 且屏幕可见。
  **真机不受影响**：面板由 Intel `xe` 驱动 modesetting；显示 HDI（`drm_node_utils.h::FindPreferredDrmNode`）
  会枚举 `/dev/dri/card*` 选连接器最多的卡（simpledrm 的 `Unknown-1` 得分 0，xe 的 eDP `connected` 得分 ≥1）。
  真机判据：桌面正常显示；`dmesg|grep "selected DRM node"` 指向 xe 那张卡；`/sys/class/drm/card*-*/status` 为 `connected`。
- **交付镜像** `partdisk/media/ohos_part_pc_ptl.img` = **`92274c80ddd2ee19b62516d71dadf578156890937ebe11b24328035a3b2f9b44`**
  （仅改 p1 的 ESP）；备份 `media/ohos_part_pc_ptl.pre_selfbuilt_grub.img.zst`（解压=`1342c590…`）。
- **用户操作**：只需 `mokutil --import partdisk/sb_keys/ohos-uefi.cer` → 重启进 MokManager 输密码 → 插盘启动；
  **不需要动 BIOS 的 db**。流程见 `partdisk/README_SECURE_BOOT.md`（已更新为最终版）。
- **遗留**：① handover 路径开机最初几秒黑屏（预期）② 补丁跟上游 2.14 走，升级需重新 apply
  ③ 自建 GRUB 不在发行版 SBAT 治理里（generation=100）④ 未在真机验证本轮镜像。

## 26. 【已交付】SOF/IPC4 固件路径对齐 + 构建期断言（2026-10-20，fix_sof_fw2）

> 报告：`out/x86_64_virt/ohos-dbg/fix_sof_fw2/SUMMARY.md`（含 file:line、校验输出、真机判据、回退）。
> **未改交付镜像** `partdisk/media/ohos_part_pc_ptl.img`（sha 仍 `92274c80…`）；验证在 `fix_sof_fw2/scratch.img`
> （`cp --sparse` 副本）上做。

- **内核实际请求的路径**（linux-7.2，SOF 在**顶层** `sound/soc/sof/`，不是 `drivers/sound/soc/sof/`）：
  `sound/soc/sof/intel/pci-ptl.c:42-53` → `intel/sof-ipc4/ptl/sof-ptl.ri`、
  `intel/sof-ipc4/ptl/sof-ptl-openmodules.ri`（`ipc4-loader.c:296`，前缀取自 `core.c:310`）、
  `intel/sof-ipc4-tplg/<topo>.tplg`（本机用 `sof-hda-generic-4ch.tplg`）。
  搜索根：`firmware_class.path`（cmdline `/system/lib/firmware`）+ `/lib/firmware`
  （`drivers/base/firmware_loader/main.c:471-478`）。**`intel/` 前缀是路径的一部分。**
- **修掉的真 bug**：`device/pc/ptl/firmware/BUILD.gn` 里 196 个 SOF 目标的 `module_install_dir`
  **缺 `intel/` 前缀** → 重编 `out/ptl` 会把固件装到内核不去找的目录（"重编一次就退化"）。
  已全部补成 `lib/firmware/intel/sof-ipc4*`（`gn format --dry-run` 通过；备份 `fix_sof_fw2/evidence/BUILD.gn.bak`）。
- **重要更正**："ramdisk 的 /lib/firmware 只有 12 个条目"说的是 **OHOS 构建产物**
  `out/ptl/packages/phone/images/ramdisk.img`（09-28 构建，SOF 目标是 10-14 才加的）；
  **交付镜像 ESP 里的 `ramdisk_bootmedia.img` 已有 189 拓扑 + 2 个 `.ri`**，路径也正确（461 条目）。
  p2 的 `/system/lib/firmware/intel/…` 也已齐全。
- **新增**：`partdisk/make_partition_disk.sh` 显式 staging `intel/sof-ipc4{,-tplg}` +
  **构建期断言** `assert_ramdisk_has_sof()`（缺 SOF 固件 → `exit 1`；正/负例已测）；
  `partdisk/tools/cpio_list.py`（能列拼接 cpio——GNU `cpio -t` 只能看到第一个 archive）。
- **`fix_sof_fw2/inject.sh <image>`**：幂等注入（重写 ESP ramdisk + 补 p2 固件 + 对齐 `zz_audio`）；
  字节级幂等（连跑两次镜像 sha 不变），只动 p1 的 ramdisk 与 p2 的 `zz_audioup.sh`。
- **`zz_audio` 对齐真实声卡名**：`sofhdadsp`（长名 `sof-hda-dsp`）→ 脚本先打印
  `/proc/asound/cards` 再按 `sofhdadsp` 解析卡号，不再写死 `amixer -c 0`；
  日志前缀 `ZZAUD:`。
- **更根本的问题（本轮未改内核，列为 Plan B）**：`CONFIG_SND_SOC_SOF_INTEL_PTL=y`（**内建**），
  在 initcall 阶段 probe，那时 `/system` 未挂载 → 固件只能来自 initrd；且 initrd 解包是异步的
  （`init/initramfs.c:783-792`），与 probe 存在竞态。真机 pstore 证据
  （`std_firmware/evidence/pstore_firmware_evidence.txt`）显示同一台机器上内建的
  `xe`/`iwlwifi`/`btintel` 在 t≈0.23–0.40 s 就报"固件找不到"。
  **标准解法**：驱动改 `=m`，由 OHOS init 在 switch_root 之后加载（`std_firmware` 已对 xe/i915 用过
  `zz_drmmod.sh` 那一套），固件从 p2 取。
- **QEMU 无法验证**（无 SOF 声卡），本轮只做结构化校验。

## 27. 【已修】PC 桌面页无 app 图标 = 桌面布局为空/越界（不是 pc_mode 表的问题）（2026-10-20，fix_desktop_layout）

> 报告：`out/x86_64_virt/ohos-dbg/fix_desktop_layout/SUMMARY.md`（含 file:line、注入脚本、RDB 行数证据、真机判据、回退）。
> 产品 `pc_ptl`。**交付镜像 `partdisk/media/ohos_part_pc_ptl.img` 本轮未改**（仍 `92274c80…`），验证在
> `fix_desktop_layout/scratch.img`（cp --sparse 自交付镜像；为在 QEMU 引导已把 GPT 扩到 20 GiB，见 fix_diag §4）。

- **先纠正前提**：`pc_mode_gridlayout_info = 0` **不是**桌面没图标的原因。PC 产品**不读**那张表
  （`RdbStoreManager.updateLayoutTableName` 只有 `DesktopLayoutState.PC_MODE_MODEL` 才切，
  而 `PC_MODE_MODEL` 需要 `const.window.support_window_pcmode_switch=true` **且**
  `persist.sceneboard.ispcmode=true`，pc_ptl 镜像都没设；显式切表的是 **pad** 产品的 PC 页
  `product/pad/src/main/ets/pages/pc/EntryView.ets:143`）。PC 桌面读 `gridlayout_info`。
- **真因**：桌面网格来自 `PcPageDesktopLayoutConfig.loadPersistConfig()`（RDB + 持久化 JSON + 预置
  rawfile `layoutInfo.json`）。只要这三条都空、或所有项坐标越界、或宫格行列=0，桌面就是 0 图标
  （应用中心走 `AppModel`/BMS，所以"应用中心有、桌面没有"）。
  真机旧 HAP（`643f0b7f…`）的 `resources/rawfile/layoutInfo.json` **就是空的** → 桌面空。
- **修法**（唯一改动文件 `porting/scb_src/product/pcbase/.../PcPageDesktopLayoutConfig.ets`）：
  ① `ensureDesktopIconsVisible()`：无可见项时——有元素则**只重排坐标**
  （`updateInfoPosition` 按 bundleName+appIndex 原地 UPDATE，**不新增行**），空表则用已装 app 重建并落库；
  ② `syncLayoutToPcModeTable()`：把最终布局写进 `pc_mode_gridlayout_info`（为空时写），两张表一致。
  ③ **删掉**上一版无效的 `dealNotInCCMApp()` 重写（它只在"RDB 为空"分支被调用，且 `isCellOccupied`
  因预置项无 `area` 字段而把新项放到 (0,0) 造成重位，触发 Launcher 重排 → 桌面行 17→31 重复）。
- **注入**：p2 空闲只有 23.9 MiB，但 **先 `rm` 旧 HAP 释放 91 MiB 再 `write`** 即可原地替换，
  **不必挪到 p3(/vendor)，不必改 install_list.json**（路径/包名/签名都没变）。
  脚本 `fix_desktop_layout/inject.sh <image> [hap]`（幂等 + 镜像内 HAP sha 自校验）。
- **QEMU 证据**：`pc_mode_gridlayout_info` **0 → 17**；`gridlayout_info` 24（17 桌面+7 dock，无重复）；
  `app_center_layout_info` **18 不变**；故障注入 A（坐标全挪到 99,99）→ 重启后自动归位且不重复；
  故障注入 B（预置 rawfile 置空 + 空 RDB）→ 用 18 个已装 app 兜底重建，桌面 18 图标。
- **新 HAP**：`6d2557b2760d8b4404d13cefabddef887363798215de27c9cd769ff7e04a3cfa`（95,234,974 B）。

## 28. 【已修】输入框 focus 卡顿（MMI 关键事件被丢 + 客户端不读 socket） + AIRA「自建」闪退（HDS 依赖）（2026-10-21，fix_input_aira）

> 报告：`out/x86_64_virt/ohos-dbg/fix_input_aira/SUMMARY.md`（根因 file:line、修法、真机判据、回退、遗留）。
> **交付镜像 `partdisk/media/ohos_part_pc_ptl.img` 本轮未改**（sha 仍 `92274c80…`）；
> 验证用 `fix_input_aira/scratch.img`（交付镜像稀疏副本 + GPT 扩 20 GiB）。

### 28.1 输入框 focus 卡顿（MMI）
- **根因不是 IME**：(a) 上一轮 `fix_touchpad_mmi` 的「客户端缓冲满就丢事件」**把点击（DOWN/UP）也丢了**
  → 丢一次点击 = 输入框永远不 focus（用户表现为"要点好几下"）；
  (b) MMI **客户端读 socket 与事件回调同线程**，回调里的 **TF_SYNC** IPC（session manager→app 的
  `TransferKeyEventForConsumed`）一阻塞就停止读 socket → 服务端缓冲满 → 回到 (a)；
  (c) 全链路**没有分段耗时埋点**，现场无法定位。
- **修法**（`foundation/multimodalinput/input`，补丁 `fix_input_aira/patch/mmi_input_focus.patch`）：
  - `util/socket/src/uds_session.cpp:52` `SendMsg(buf,size,critical)`：**critical 事件（pointer/key DOWN/UP 等）
    最多等 150 ms** 让对端腾缓冲，**不再丢**；只有 motion/hover 才丢。
  - `service/event_dispatch/src/event_dispatch_handler.cpp:70/86/633/711`：判定并透传 critical。
  - `frameworks/proxy/module_loader/src/mmi_client.cpp:203/229/275`：**读 socket 与回调解耦**
    （新增 `OS_mmi_Dispatch` 线程；用 `pthread_create` —— 该 target 是 `-fno-exceptions`）。
  - `frameworks/proxy/event_handler/src/client_msg_handler.cpp:163/261/278`：**事件年龄**埋点 +
    过期 hover 丢弃（慢消费者保护）。
  - 埋点统一前缀 **`MMI_PERF`**：`slow dispatch`（服务端耗时）/ `slow consumer`（端到端排队）/
    `drop event …critical:0|1`（丢事件）/ `drop stale hover event`。
- **QEMU 回归**：新库生效、注入触摸后**同毫秒**送达（`evidence/mmi_input_flow.log`），
  `MMI_PERF` 计数 **0**（健康链路不误报）。

### 28.2 AIRA「数据同步 → 自建」闪退
- **根因**：`自建`页用的 `SettingsHdsScaffold` **静态导入 HMS `@kit.UIDesignKit`（HdsNavDestination/HdsTabs）**；
  OpenHarmony **没有 HDS 运行库**（`out/ptl` 无任何 hds 库，OH SDK 26.0.0 的 kit 列表里也没有 UIDesignKit）
  → 模块加载失败 → `build()` 里调用组件抛**未捕获**异常 → **进程被杀**。
  页面是按需加载的，所以「应用能启动、能进主页」，唯独这 68 个 HDS 页面一打开就死。
- **ArkTS 静态具名导入的两类失败（重要判据）**：模块**存在但缺导出名** → `SyntaxError: does not provide an export name`
  → **致命**；native 模块**根本不存在** → `W … Load native module entry is not a JSObject` → 绑定 undefined，
  **只有访问点没有 try/catch 才致命**（`build()` 里的组件调用就是这种）。
- **修法**：新增 `platform/huawei/OpenHarmonyHdsMaterialShim.ets`（材质恒「不可用」→ 走应用**本来就有的**
  普通 ArkUI 降级路径）；`HdsNavDestination`→普通 ArkUI 标题栏、`HdsTabs`→`Tabs`。
  改动 3 文件 + 1 新文件（补丁 `fix_input_aira/patch/aira_hds_fallback.patch`）。
  新 HAP `Aira-v3.7.2-x86-selfhost-fix-signed.hap`，41,530,309 B，sha256 `04a5b97ac7ffcc02ee1d2a18ae86888f27d68997db6b02401cca7d3d62f5b48c`。
- **顺带修的镜像缺陷**：`install_list_capability.json` 缺 `org.aira.browser` → BMS 以 8519888 拒装
  → **Aira 根本没预装上**；`inject.sh --with-aira` 会幂等补上。
- **遗留**：`ManagementHdsScaffold.ets`、`SettingsNavigationScreen.ets` 仍用 HDS（设置中心两栏导航页仍会崩）。

### 28.3 交付与踩坑
- `fix_input_aira/inject.sh <image> [--with-aira]`（幂等、镜像内 sha256 自校验；只动 p2 的 4 个文件 +
  可选的能力条目；先 `rm` 再 `write` 以适配 p2 只有 ~24 MiB 空闲）。
- **并发会话会互杀 QEMU**：别的会话 `pkill -9 -f 'qemu-system-x86_64 -[m]achine'`；
  本轮改用 `work/qemu-pcptl`（符号链接，argv[0] 变了 → 不会被命中），VNC/hdc 挪到 :26 / 5557。
- guest 的 `hdcd` 在 TCP 模式下不监听 5555 → 用**串口**交互（`ser.py`/`gsh.py`），
  截图 `snapshot_display` + base64 回传（`fix_input_aira/scripts/snap_ser.py`）。
- `INPUT_EVENT_SOCKET_TIMEOUT` 的去重窗口写错：`GetSysClockTime()` 是**微秒**，
  `MINUTEINMILLIS=60000` 实际是「每 60 ms 一次」而非每分钟（未改，值得单独修）。

## 29. 【已合入】真机六问题一轮修完 + Secure Boot 默认化（2026-10-21）

> 报告：`out/x86_64_virt/ohos-dbg/fix_{desktop_layout,sof_fw3,bt_hci,input_aira,net_perf}/SUMMARY.md`。
> **交付镜像 `partdisk/media/ohos_part_pc_ptl.img` = `e848e34c512c6a1606824a53f32f154580d3415020fc23d02fc3809e79e7bcf0`**
> （基线 `92274c80…`；备份 `media/ohos_part_pc_ptl.pre_batch6.img.zst`；Secure Boot 链保持完好：shim=微软 CA、grub/bzImage=OpenHarmony 签）。

### 29.1 六个真机问题的根因与修法（**都是真 bug，不是环境问题**）
| 现象 | 真因 | 修法 |
|---|---|---|
| **桌面无 app 图标** | PC 桌面读 `pc_mode_gridlayout_info`（**0 行**），而数据在 `gridlayout_info`(24)/`app_center_layout_info`(18)；旧 `dealNotInCCMApp()` 只在"RDB 为空"分支且首行 `length>0 就 return`，还因预置项无 `area` 造成重位 | `PcPageDesktopLayoutConfig.ets`：`ensureDesktopIconsVisible()`（有元素只重排坐标、**不新增行**；空表用已装 app 重建）+ `syncLayoutToPcModeTable()`；HAP `6d2557b2…` |
| **完全无声**（无 `sofhdadsp` 卡） | SOF 内建驱动 initcall 期 probe：`i915_gfx_present()` 尚无结果 → `snd_hdac_i915_init()` 返回 **-ENODEV** → `hda.c:527` 容忍 -ENODEV **但不 defer** → 硬失败**不会被内核重试**（10-16 那版是 defer 后被 `driver_deferred_probe_trigger()` 重试成功）。**固件从来不是问题**（initrd 与 p2 都有） | 新增 init 服务 `zz_sof_reprobe`：**unbind+bind** SOF PCI 设备（按 PCI id `8086:E428` 定位，非硬编码 BDF）复现延迟重试 |
| **蓝牙打不开** | **三个叠加断点**：①协议栈 dlopen `libbluetooth_hdi_adapter.so`，真名是 `.z.so` → 栈在碰到 HDI 前就退出，vendor HAL 根本没机会加载；②镜像里 `hdf_devhost.cfg` 陈旧、`blue_host` 只有 `NET_ADMIN`（RAW 通道需 `CAP_NET_RAW`）；③旧 vendor HAL 三个协议错（`HCIDEVUP` ioctl 号用了旧 `_IO(0,3)`、`-EALREADY` 当致命、RAW 通道不投递 H4 类型字节） | 修 `hdi_wrapper.c` 库名；用 `hc-gen` 重生成带 `NET_RAW` 的 cfg；重写 `bt_vendor_linux.c`（5 个 raw socket + `SO_HCI_FILTER.type_mask` 还原类型 → socketpair 单 fd H4 通道，`H4ScanFrames()` 按类型回发避免自吞 TX） |
| **输入框 focus 卡顿** | ①上一轮"客户端满就丢事件"**不区分事件类型**，把 `POINTER_ACTION_DOWN/UP` 也丢了 → 丢一次点击=永远不 focus；②`MMIClient::OnRecvMsg()` **读 socket 与回调同线程**，回调里的 TF_SYNC IPC 一阻塞就停读 → 服务端缓冲满 → 回到① | 关键事件最多等 **150ms** 不丢（只丢 motion/hover）；客户端新增 `OS_mmi_Dispatch` 独立线程解耦；`MMI_PERF` 埋点（服务端耗时/端到端事件年龄/丢事件数/过期 hover 丢弃） |
| **AIRA 引导"自建"闪退** | `自建`页静态导入 HMS `@kit.UIDesignKit`（`HdsNavDestination`/`HdsTabs`），**OpenHarmony 无 HDS 运行库** → 模块加载失败 → `build()` 里组件调用抛未捕获异常 → 进程被杀 | 材质能力改本地垫片（恒"不可用"→走应用原有的普通 ArkUI 降级路径）；`HdsNavDestination`→普通标题栏、`HdsTabs`→`Tabs`；HAP `04a5b97a…`；顺带补 `install_list_capability.json` 的 `org.aira.browser`（否则 BMS 8519888 拒装） |
| **apk 下载极慢** | 通用 nl80211 路径**从不设内核 regulatory domain**：国家码只给了 wpa_supplicant（其 `country=` 只用于 AP），chip HAL 走 vendor netlink（**只有 hdfwifi 认识**，iwlwifi 忽略）→ 内核一直用 world 域：**5GHz 只 20MHz、52~144 是 DFS(60s 雷达 CAC)**、功率受限；且 `regulatory.db` 不在镜像里（内核 late_initcall 加载时 `/system` 未挂载）；iwlwifi 省电也从未关 | HAL 加 `NL80211_CMD_REQ_SET_REG`/`RELOAD_REGDB`/`SET_POWER_SAVE(off)`；注入 `regulatory.db`；加 root init 服务 `zz_wifi_regdomain`（Wi-Fi 进程无 `CAP_NET_ADMIN`）。QEMU 验证：reg `00`→**CN**、`reg reload` ok、`power_save: off` |

### 29.2 B 站直播"只播一两帧"——**已定性，暂无法根治（如实记录）**
- 社区 Chromium 114 x86_64 引擎**无 libva → H.264 纯软解**，CPU 打满 → 直播几乎不动。
- **更正一个此前的误判**：Mesa 的"每帧全屏回读+CPU 行翻转"**只在 virgl(QEMU) 生效**（`ohos_needs_host_sync()` 仅对 virtio_gpu 返回 true），**真机 iris 根本不走这段** → 不是真机卡顿原因。实测 virgl 每帧 map 6.9ms + 翻转 1.95ms ≈ 8.9ms（≈54 swap/s 上限）；SSE2 行翻转 A/B：**1939µs vs 1961µs → 翻转算法不是瓶颈**（耗时在 4MiB dma-buf 的页错误+带宽）。**优化收益≈0**；根治需把扫描缓冲换成 hostmem blob（改显示 HDI，QEMU-only，真机用不到）。
- 真机判据脚本：`scripts/arkweb_live_probe.sh`（GL renderer / `hidumper -s RenderService -a hitchs` / `web_render` 进程 %CPU）。

### 29.3 Secure Boot 已默认化（见 §25/§29.4）
- 管线 `make_partition_disk.sh`：`SECURE_BOOT=1` **默认**（`SECURE_BOOT=0` 为退路）；`GRUB_SOURCE=ours`（自建上游 2.14 GRUB）默认。
- **根因（曾长期卡住）**：Ubuntu 给 GRUB 2.14 的补丁 `secure-boot/disable-efi-fallback-to-legacy.patch` 删掉了 legacy `shim_lock` 回退分支 → shim 只验签不装载 → GRUB 退回固件 `LoadImage` → 固件只认 db → 内核加载失败。**自建 GRUB 恢复该分支后 MOK-only 即可启动**（固件 db 不需要我们的证书）。
- 用户只需一次 `mokutil --import partdisk/sb_keys/ohos-uefi.cer` → 重启进 MOK Manager 输密码 → 插盘启动。
- 自建 GRUB 配方在**仓库** `device/pc/ptl/grub/`（`build_grub.sh` + 2 补丁 + `grub.sbat`），可复现（裸 core 逐字节可重建）。

### 29.4 遗留
- 蓝牙三个断点修完但**无真机运行期证据**（QEMU 无 BT 硬件）；真机判据：开关可开、`hidumper -s 1130`（**蓝牙 SA id 是 1130，不是 `-s Bluetooth`**）有输出、能扫到设备、`/data/local/tmp/bt_vendor.log` 有链路日志。
- SOF reprobe 只有结构化验证（QEMU 无 SOF 声卡）；真机判据：`/proc/asound/cards` 出现 `0 [sofhdadsp]`、dmesg `Firmware file: intel/sof-ipc4/ptl/sof-ptl.ri`、`ZZSOF:` 诊断行。
- 设置中心两栏导航页仍用 HDS（`ManagementHdsScaffold.ets`/`SettingsNavigationScreen.ets`）→ 仍会崩，下一轮处理。
- 真机 focus **分段耗时数字**待采集（判据见 `fix_input_aira/SUMMARY.md` §1.5）。
- 直播软解无解，除非换带硬解的引擎/加 libva。

## 30. 【系统级性能取证】真机"所有操作都卡" —— 三个真 bug + 一键取证（2026-10-21，fix_sysperf）

> 报告：`out/x86_64_virt/ohos-dbg/fix_sysperf/SUMMARY.md`（含每条线索的 file:line、QEMU 证据、
> **真机判据**、回退、遗留）。交付：`fix_sysperf/inject.sh <image>`（幂等）、`fix_sysperf/scratch.img`。
> **未改交付镜像** `partdisk/media/ohos_part_pc_ptl.img`（sha 仍 `e848e34c…`）。

### 30.1 【重大发现】hidumper 在真机上**完全不可用**（取证最大阻塞）
- 真机 `hidumper -ls` / `-s RenderService` / `-s 4606` **全部** `request error`
  （`diagwork/d2/A_hidumper_*.txt`、`B/C_hidumper.txt` 全是 14 B 的 "request error"）；
  QEMU 上同样复现 → **不是真机独有**。
- hilog 实证：`DumperService: HasDumpPermission# No dump permission, please check!, uid:0`。
- **根因链**：
  `dump_manager_service.cpp` → `AccessTokenKit::VerifyAccessToken(tok, "ohos.permission.DUMP")` 失败；
  native token 的 APL 由 init cfg 决定，**默认 `"system_basic"`**
  （`base/startup/init/services/init/standard/init_service.c:300`），
  而 `ohos.permission.DUMP` 的 `availableLevel` 是 **`system_core`**
  （`base/global/system_resources/systemres/main/module.json:2723`）→ 权限被 APL 过滤掉；
  `console.cfg` / `zz_diag.cfg` **既无 `apl` 也无 `permission`** → 连 root 都拿不到。
- **修法**（两个 cfg 加 `"apl": "system_core"` + `"permission": ["ohos.permission.DUMP"]`）：
  `base/startup/init/services/etc/console.cfg`、`base/startup/ohos_diag/etc/zz_diag.cfg`。
  QEMU 实测：`hidumper -s RenderService -a gles` → `GL_RENDERER: virgl (Mesa Intel(R) Graphics (PTL))`；
  `-a screen` → activeMode；`-a hitchs` → 掉帧计数。**真机判据：刷完必须能出 GL_RENDERER。**

### 30.2 【真 bug】RS 每 surface 每帧打 ERROR 日志（渲染关键路径上刷屏）
- `rs_surface_watermark.cpp:29`：`DrawCommSurfaceWatermark()` 在**没有水印**（正常情况）时
  **每 surface 每帧** `RS_LOGE("...water mark count is zero")`；调用点
  `rs_surface_render_node_drawable.cpp:269` / `rs_draw_window_cache.cpp:237` / `rs_sub_thread_cache.cpp:1250`。
  **没有"水印开关"**——这是把正常状态当错误报。
- 同类：`rs_base_render_util.cpp:1277` `RS_LOGE("...GetSurfaceBufferOpaque:0")`（uni-render 每 surface 每帧）。
- **量化**（真机 hilog 24 分钟）：水印 592 条 / Opaque ~460 条 / `SetBufferColorSpace fail` 81 /
  `SetMetadata -5` 243；动画期总日志 **~230 行/秒**，其中 RS 的 E 级占 ~75%。
- **修法**：`RS_LOGE` → `RS_LOGD`（2 文件各 1 行）。重编
  `build.sh --product-name pc_ptl --build-target librender_service`（**2 分 08 秒**，非全量）。
  真机判据：动画期 `hilog | grep -c DrawCommSurfaceWatermark` 从 ~500/秒 → **0**。

### 30.3 【真 bug】Mesa 的驱动选择/回退诊断**被静默丢弃**（所以"是不是软渲染"查不出来）
- `mesa_build26/mesa3d-src/.../platform_ohos.c`（副本，仓库 `third_party/mesa3d` 未动）：
  旧 `mesa_dbg()` 写 `/data/mesa_dbg.txt`，而 **render_service 以 uid `graphics` 运行**、
  `/data` 是 `root:data_reserve 0770` → **fopen 失败 → 所有日志消失**；
  且 `ohos_load_driver()` 失败后**无条件**回退 `swrast`（软件渲染），**没有任何提示**。
- **修法**：`mesa_ohos_log()`（`MESA-OHOS:` 前缀）→ hilog(`libhilog.so`! 不是 libhilog_ndk.z.so)
  + stderr + **文件**（首个可写路径 = `/data/service/el0/render_service/mesa_ohos.log`，
  `graphic.cfg` 里 `mkdir … 0711 graphics graphics`）；
  驱动选择全程打点（PCI id / `loader_get_driver_for_fd` / `dri2_create_screen` 成败+errno /
  `pscreen->get_name()`）；回退时显式打印 `SOFTWARE RENDERING`；
  `MESA_OHOS_NO_SWRAST_FALLBACK=1` 可禁用兜底；`MESA_OHOS_DRIVER=iris` 可强制驱动。
- **只改 `libEGL.so.1.0.0`**（`libgallium/libGLES/libgbm` 字节级未变）→ 注入面最小。
- **真机判据**：`cat /data/service/el0/render_service/mesa_ohos.log`
  → 有 `loader_get_driver_for_fd -> iris` 且**无** `SOFTWARE RENDERING` = 硬件 GL 正常。
  （静态推演：`loader.c:790` + `pci_id_driver_map.h:60` + `loader.c:139 iris_predicate` → PTL(0x8086:0xb080)
  会选 **iris**；但**必须实测**。）

### 30.4 `ohos-diag` 新增 **perf** 段（必收，一次性取证）
`base/startup/ohos_diag/ohos-diag`（本地文件，非 manifest 仓）新增 F/perf 段：
F1 `hidumper -a gles/screen/fps/hitchs`；F2 **CPU 频率/governor/intel_pstate/cpuidle**；
F3 loadavg/free/top/**自算每进程 CPU%**（设备无 `awk`/`tr`，用 sed/cut 实现）；
F4 DRM/xe（`/sys/kernel/debug/dri/*/state`、`lsmod`、`dmesg|grep xe`）；
F5 **Mesa 日志文件** + RS 每帧日志噪声计数。
QEMU 端到端验证通过（`ohos-diag perf` → 12.8 KB 归档）。
**真机用法**：开机 ~240 s 自动抓一次（`zz_diag_boot.sh`），或手动 `ohos-diag perf`。

### 30.5 显示 HDI 路径（已核实：**无每帧 CPU 拷贝**）
`device/qemu/common/virt_full/hardware/display/src/display_device/`：
`drm_node_utils.h:146 FindPreferredDrmNode()`（按 connected 连接器数选卡，真机只有 xe 的 card0 → 正确）、
`hdi_drm_layer.cpp:57 DrmGemBuffer::Init()` → **`drmModeAddFB2` 把客户 dma-buf 直接变 DRM FB**、
`hdi_drm_composition.cpp:119 ApplyPlane()` → `drmModeAtomicCommit` 挂 plane
→ **GPU 直通扫描输出**。真实开销点是**每帧**一次 `drmPrimeFDToHandle`+`AddFB2`+`RmFB`+`GEM_CLOSE`
（失败时还有多格式探测循环 `hdi_drm_layer.cpp:101-111`），以及 `SetMetadata` 未实现导致
`SetMetadata Failed with -5`（**接口缺失，不是拷贝**）。

### 30.6 遗留
- 真机尚未跑过这批改动（本轮验证全在 QEMU，用的是**同一份** libEGL/ohos-diag/cfg）。
- `MESA-OHOS` 目前只在**文件**里（`HiLogPrint` 从 dlopen 的 `libhilog.so` 调用返回非 0，已做 domain 回退）。
- RS 每帧 `SetBufferColorSpace`/`SetMetadata` 失败仍在（81/243 条）→ 建议给 display HDI 补 `SetMetadata`。
- 其它每帧路径上的 `RS_LOGE` 值得再扫一遍。

## 30. 【系统级性能】"所有操作都卡" —— hidumper 真机不可用 + RS 日志洪水 + Mesa 后端待定（2026-10-21，fix_sysperf）

> 报告 `out/x86_64_virt/ohos-dbg/fix_sysperf/SUMMARY.md`。
> **交付镜像 = `0e56e2716ecb9b844435cf4baa204a5f2213449d9dbc460baf2de4ba436eabdf`**
> （基线 `e848e34c…`；含 §29 六项 + 本轮 5 个文件）。备份 `media/ohos_part_pc_ptl.pre_batch6.img.zst`（= `92274c80…` 之前那版）。

### 30.1 三个真 bug
1. **hidumper 在真机完全不可用**（`request error`，连 `-ls` 都不行）→ **之前查不出真机性能根因的挡路石**。
   根因：init 给 native token 的默认 APL 是 `system_basic`（`base/startup/init/services/init/standard/init_service.c:300`），
   而 `ohos.permission.DUMP` 的 `availableLevel` 是 **`system_core`**（`base/global/system_resources/systemres/main/module.json:2723`）；
   `console.cfg`/`zz_diag.cfg` **既无 `apl` 也无 `permission`** → 连 root 都被挡。
   修：两个 cfg 加 `"apl":"system_core"` + `"permission":["ohos.permission.DUMP"]`；QEMU 实测 `hidumper -a gles` 立刻出 `GL_RENDERER`。
2. **RS 每 surface 每帧打 ERROR**：`rs_surface_watermark.cpp:29`（"water mark count is zero"=**正常态**却报 ERROR）、
   `rs_base_render_util.cpp:1277`（`GetSurfaceBufferOpaque:0`）。真机 24 分钟 592+460 条，**动画期 ~500 行/秒**（≈1080 次/秒 × 18 surface 的日志 I/O，本身即显著开销）。
   修：`RS_LOGE` → `RS_LOGD`（2 文件各 1 行），重编 `librender_service` **2 分 08 秒**。
3. **Mesa 驱动选择/回退诊断被静默丢弃**：`mesa_dbg()` 写 `/data/mesa_dbg.txt`，而 render_service 以 uid `graphics` 运行、
   `/data` 是 `root:data_reserve 0770` → fopen 失败 → 日志全丢；且 `ohos_load_driver()` 失败后**无条件**回退 `swrast`（软件渲染）**无任何提示**。
   修：`mesa_ohos_log()`（`MESA-OHOS:` 前缀）→ hilog(`libhilog.so`) + stderr + **文件**（首个可写路径 = `/data/service/el0/render_service/mesa_ohos.log`，
   `graphic.cfg` 里 `mkdir … 0711 graphics graphics`）；驱动选择全程打点（PCI id / `loader_get_driver_for_fd` / `dri2_create_screen` 成败+errno / `pscreen->get_name()`）；
   回退时显式打印 `SOFTWARE RENDERING`；`MESA_OHOS_NO_SWRAST_FALLBACK=1` 可禁用兜底；`MESA_OHOS_DRIVER=iris` 可强制驱动。
   **只改 `libEGL.so.1.0.0`**（`libgallium/libGLES/libgbm` 字节级未变）→ 注入面最小。

### 30.2 `ohos-diag perf` 段（必收，一次性取证）
`base/startup/ohos_diag/ohos-diag` 新增 F/perf 段：F1 `hidumper -a gles/screen/fps/hitchs`；F2 **CPU 频率/governor/intel_pstate/cpuidle**；
F3 loadavg/free/top/**自算每进程 CPU%**（设备无 `awk`/`tr`，用 sed/cut 实现）；F4 DRM/xe（`/sys/kernel/debug/dri/*/state`、`lsmod`、`dmesg|grep xe`）；
F5 **Mesa 日志文件** + RS 每帧日志噪声计数。QEMU 端到端验证通过（`ohos-diag perf` → 12.8 KB 归档）。

### 30.3 显示 HDI 路径（已核实：**无每帧 CPU 拷贝**）
`device/qemu/common/virt_full/hardware/display/src/display_device/`：
`drm_node_utils.h:146 FindPreferredDrmNode()`（按 connected 连接器数选卡，真机只有 xe 的 card0 → 正确）、
`hdi_drm_layer.cpp:57 DrmGemBuffer::Init()` → **`drmModeAddFB2` 把客户 dma-buf 直接变 DRM FB**、
`hdi_drm_composition.cpp:119 ApplyPlane()` → `drmModeAtomicCommit` 挂 plane
→ **GPU 直通扫描输出**。真实开销点是**每帧**一次 `drmPrimeFDToHandle`+`AddFB2`+`RmFB`+`GEM_CLOSE`
（失败时还有多格式探测循环 `hdi_drm_layer.cpp:101-111`），以及 `SetMetadata` 未实现导致 `SetMetadata Failed with -5`（**接口缺失，不是拷贝**）。

### 30.4 遗留
- 真机尚未跑过本批改动（QEMU 无法覆盖真 GPU 路径）。
- **首要待定项**：真机 RS 到底用 **iris（硬件）还是 swrast（软件）** → 看 `/data/service/el0/render_service/mesa_ohos.log`：
  出现 `-> iris` 且无 `SOFTWARE RENDERING` = 硬件 GL 正常；若 `SOFTWARE RENDERING` → 3072×1920 纯软件渲染，
  这就是"全系统都卡"的主因，续做：修 iris 建屏失败原因（`dri2_create_screen` errno 已打点），
  兜底可先把 eDP 降到 1920×1200（像素量 1/2.5）再排查。
- `SetBufferColorSpace`/`SetMetadata` 失败仍在 → 建议给 display HDI 补 `SetMetadata`。

## 31. 【系统级"卡"】真机其实没跑错镜像；真正嫌疑=每帧 DRM FB 重建（2026-10-21，fix_perf2）

> 报告 `out/x86_64_virt/ohos-dbg/fix_perf2/{SUMMARY.md,FINDINGS.md}`。
> **交付镜像 = `f8486d46512b363aaa624b774c7ad718fe2e9fab9e06cc0baf2fbddf738e33e2`**
> （含 §29 六项 + §30 的 hidumper/RS/Mesa + 本轮 4 项；备份 `media/ohos_part_pc_ptl.pre_batch6.img.zst`）。

### 31.1 先纠正一个错误结论
"真机跑的不是交付镜像"——**不成立**。真机 diag 头里的 `ESP_PART_SHA256`/`P2_KEYFILES_SHA256` 之所以对不上，
是因为 **`/system/etc/ohos-image-id` 这个身份戳从 fix_alsa_bt_desktop 那轮之后再没重生成**（一直写着 10-17 的旧值）。
**真机确实跑的是我们的镜像**。已新增 `partdisk/update_image_id.sh`：每次注入都重算 p1/p3/p4/p5 分区哈希 +
P2_KEYFILES 哈希（**与设备端 `zz_imageid.sh` 同算法：符号链接跟随、格式 `"<hash>  /<path>"`**）并写回 p2，
以后 `cat /system/etc/ohos-image-id` 即可确认在跑哪一版。

### 31.2 真机实测：CPU/GL/帧率/内存**全都正常**（此前几轮怀疑全部排除）
- **GL 是硬件加速**：`MESA-OHOS: loader_get_driver_for_fd -> iris` / `renderer='Mesa Intel(R) Arc(tm) B390 (PTL)'` → **不是 swrast**。
- CPU 96% idle、load 1.15、0% iow；内存 31GB 用 4.6GB。
- 动画期 61.2fps（静止期 2~5fps 属按需重绘）。
- 显示 HDI 是 DRM/KMS 直通（`drmModeAddFB2` 导入客户 dma-buf + atomic commit），**无每帧 CPU 拷贝**。
- `scaling_cur_freq=400000` 是**读数假象**（`cpufreq.c:713` 空闲超 20ms 就回落到 `cpufreq_quick_get()`，
  而 `intel_pstate.c:2926` 明说 `policy->cur` 从不更新）；`scaling_available_governors=performance powersave`
  是 intel_pstate **主动模式**的硬编码串（`cpufreq.c:847`），不是"governor 缺失"。→ 升频救不了"卡"。

### 31.3 真正的每帧固定开销（已修）
1. **每帧销毁+重建 23.6MB 的 DRM FB**（`hdi_drm_layer.cpp:57/120`：`drmPrimeFDToHandle`+`AddFB2`/`RmFB`+`GEM_CLOSE`）
   → 改为**按 buffer 身份缓存复用**（3 个 buffer 轮转，命中≈100%）。
2. **每帧 ~500 条 ERROR 级 hilog**（显示 HDI "is not supported" 等每帧入口）→ 降级为 DEBUG。
3. `hidumper` 仍 `request error` 的**真因**：`accesstoken_info_manager.cpp:1419` ——
   `native.apl < availableLevel` 且不在 `nativeAcls` 里 → 权限被**静默丢弃**；
   DUMP 是 system_core，**必须同时写 `permission_acls`**（`hdcd.cfg` 就是这么写的）。上一轮只加了 `permission` ⇒ 没生效。
4. `zz_perf` init 服务：所有核 governor=performance + EPP + `no_turbo=0`（缓解唤醒爬坡，非主因）。

### 31.4 降分辨率退路（用于切分"每帧像素量"类瓶颈）
`param set persist.display.resolution 1920x1200`（像素量 1/2.6）。若降分辨率后明显变快 ⇒ 瓶颈在每帧成本；
若不变 ⇒ 在输入延迟或引擎侧。

### 31.5 遗留
- **"卡"的具体形态仍未与用户对齐**（滚动卡 / 点击延迟 / 动画掉帧 / 只有浏览器卡 / 输入框卡）——不同形态根因完全不同。
- `intel_pstate=passive`（根治 cpufreq ramp）**未做**：无 `_PCC`/`_CST` 时会退化成"完全无 cpufreq"，风险高（§7.2 有前置检查命令）。
- 直播软解（Chromium 114 无 libva）仍无解，见 §29.2。

## 32. 【已定性】ArkWeb 引擎编解码能力体检：H.264/AAC/VP9/AV1 有，**HEVC 没有**（2026-10-21，fix_web_codec）

> 报告：`out/x86_64_virt/ohos-dbg/fix_web_codec/SUMMARY.md`。
> **未改交付镜像**。用户症状：B 站视频"解码器只看到 mp4a"、**直播只播一两帧 + 极卡**。

### 32.1 引擎实际能力（硬证据，宿主运行期探测）
引擎 = 社区预编译 `ArkWebCore-x86_64.hap`（`50cd246f…`，ArkWebCore 5.1.0.107，**Chrome/114.0.5735.197** = M114）。
`libffmpeg.so`（`74ecc73d…`，NEEDED 只有 `libc.so`）→ **可在宿主 glibc 直接 dlopen 调 `avcodec_find_decoder_by_name()`**
（脚本 `fix_web_codec/scripts/probe_ffmpeg_codecs.sh`，需 `LD_PRELOAD=libm.so.6` + `libc.so→libc.so.6` 软链）。
结果：**h264 ✅ / aac ✅ / vp8 ✅ / mp3 ✅ / libopus ✅ / vorbis ✅ / flac ✅ / theora ✅ / vp3 ✅ / PCM ✅**；
**hevc ❌ / vp9(ffmpeg) ❌ / av1(ffmpeg) ❌ / ac3 ❌ / eac3 ❌ / alac ❌**。
- VP9 靠 **libvpx 1.13**（引擎串 `WebM Project VP9 Decoder v1.13.0-243-g27171320f`、`LibvpxVp9Decoder`）✅
- AV1 靠 **dav1d**（`Dav1dVideoDecoder` / `dav1d_open`）✅
- OpenH264 只有**编码**（`OpenH264VideoEncoder`），不是解码。
- ffmpeg 的 H.264 **x86 SIMD 在**（`ff_h264dsp_init_x86` / `ff_h264qpel_init_x86`）→ 软解不算特别慢。
- `avutil_license = LGPL` → 不是 Chrome 品牌 ffmpeg，但**刻意编进了 H.264 + AAC**（对国内站点够用），**独缺 HEVC**。

### 32.2 HEVC 为何彻底没有（三重堵死）
1. ffmpeg 无 `ff_hevc_decoder`（导出符号表实测）；
2. Chromium **M114** `media/media_options.gni` 的 `enable_hevc_parser_and_hw_decoder` **默认仅 win/mac/android/fuzzer 开** → Linux/OHOS 连 HEVC **解析器**都没有（引擎里搜不到 `h265_parser`/`hevc_parser`）；
3. OHOS 平台解码（`OhosVideoDecoder::CreateCodec video/hevc`）也救不了：`drivers/peripheral/codec/hal/` 在本树**只有 `idl_service`**，无厂商解码器实现（vendor.img 也无 codec 库）→ 设备**没有任何硬件解码器**。

### 32.3 「只看到 mp4a」= 只剩 AAC 音频轨在解，视频轨一条都没成
B 站 DASH **同一清晰度同时给 AVC(codecid 7) 与 HEVC(codecid 12)**，`fnval=4048` 还加 AV1(13)。
前端按 `MediaSource.isTypeSupported()` 挑；**若引擎对 hev1 谎报支持** → 站点挑 HEVC → 我们解不了 →
视频轨被 `FFmpegDemuxer` 丢弃（引擎串 `OhMedia::FFmpegDemuxer unsupported video decoder type with codec`）
或 `FFmpegVideoDecoder` 失败（`HEVC decoding is not supported.`）→ **只剩 `mp4a.40.2` 音频**。
「一两帧」= 能解出的 AVC 首帧，之后被丢弃 / 或软解跟不上（AV1 dav1d 软解打满 CPU）。
**判据（真机）**：`hilog | grep -iE 'unsupported video decoder type|HEVC decoding is not supported|OhosVideoDecoder::CreateCodec|FFmpegVideoDecoder|Dav1dVideoDecoder'`
（`fix_web_codec/scripts/device_codec_check.sh` 可一键自检，已在宿主用同批库自测通过）。

### 32.4 解法（推荐顺序）
- **立即可用（零改动）**：B 站清晰度选 1080P/720P（AVC 轨），别选 4K/8K/杜比/HDR；直播降到"流畅/高清"；
  用 APP/手机浏览器对比排除站点因素；看 `chrome://media-internals` 的 `video_decoder`。
- **改自带浏览器 `Browser.hap`（有现成 hvigor 管线，§21）**：
  (a) 注入 JS 把 **HEVC 从 `MediaSource.isTypeSupported` / `canPlayType` 里屏蔽**（只挡 `hev1|hvc1|h265`，AV1/VP9 别挡）→ 站点自动降级 AVC；
  (b) `onInterceptRequest` 改写取流参数：点播 `fnval=4048`→`fnval=16` 且加 `prefer_codec_type=1`；
  直播 `codec=0,1,2`→`codec=0`、`format` 钉 `2`(fmp4)（**Chromium 没有 FLV 解封装器**，FLV 完全播不了）。
  参数表见 SUMMARY.md §4。
- **换带 HEVC 的引擎**：社区**没有**现成 x86_64 带 HEVC 的 ArkWeb；自建需 chromium_arkweb 源码（树里没有）、
  ~100GB 磁盘、M144 对齐、重签 → **不建议**。
- **卡顿（独立问题）**：**完全无硬解**（无 libva/VAAPI，OHOS 无 codec HDI）→ 100% CPU 软解；
  `--enable-accelerated-video-decode` **在引擎里不存在**（只有 `--disable-...`）→ **没有开关能开硬解**。
  立即降载：直播降清晰度、`param set persist.display.resolution 1920x1200`（§31.4）、关"高帧率/高码率"。
  中期：给 Chromium OHOS 分支开 VA-API（需自建引擎）或补一个 OHOS codec HDI。

### 32.5 教训
- `libffmpeg.so` 的 `NEEDED` 只有 `libc.so`（musl 名字）→ **可在宿主直接 dlopen 探测**，不必上真机/QEMU 就能
  判定编解码器能力；`ldconfig -p` 会先命中 `/usr/libx32` 的 32 位版本，要用 `gcc -print-file-name=libc.so.6`。
- Chromium 的 ffmpeg 把每个 AVCodec 描述符作为**动态数据符号**导出（`nm -D | grep ' [DB] ff_.*_decoder$'`）
  → 这张表**就是**编进库的解码器全集。

## 33. 【已实现】自带浏览器 Browser.hap：屏蔽 HEVC + 改写取流参数（2026-10-21，fix_browser_avc）

> 报告 `out/x86_64_virt/ohos-dbg/fix_browser_avc/SUMMARY.md`。
> **承接 §32**（引擎无 HEVC 解码 → B 站只出 mp4a 音轨）。产品 `pc_ptl`。
> **本轮未改交付镜像** `partdisk/media/ohos_part_pc_ptl.img`（sha 仍 `adc97d2a…`），只提供注入脚本。

- **改动**（副本 `out/.../ohos-dbg/porting/browser_src/`，仓库 `applications/standard/browser` **未动**）：
  - 新增 `feature/web/src/main/ets/WebMediaCodecGuard.ets`；
  - 改 `feature/web/src/main/ets/BrowsePageView.ets`（`:24` import、`:200` 注入脚本数组、
    `:1453` `javaScriptOnDocumentStart`、`:1498` `onInterceptRequest`）。
  - 三层：①**页面层 JS**（HEVC 屏蔽 + fetch/XHR 取流改写 + DASH 响应剔除 HEVC/AV1 轨）
    ②**网络层 `onInterceptRequest`**（引擎侧请求才走：原生 http 拉改写后的 URL 并回填）
    ③**WBI 签名保护**（带 `w_rid` 的请求**不改参数**，否则 -403 会导致“完全播不了”）。
- **新 HAP** `fix_browser_avc/Browser.hap` sha256 **`1430bc9422095725f9a34f1cfed208d9d9ba3cc1b933ad7d6f2d4073c941a5f9`**
  （2,595,967 B）；**同签名**（内嵌 profile 与 `fix_ua/PRE.p7b` 逐字节相同）→ 预装授权条目不用改。
- **QEMU 回归通过**（`evidence/probe_requests.log`）：`guardInstalled=true`；
  `isTypeSupported(hev1/hvc1)=false`、`canPlayType(hev1)=""`；`avc1` 仍 `true`/`"probably"`；
  直播请求被改成 `codec=0&format=2`；DASH 响应过滤后 `video=[7] formats=[7]`（只剩 AVC）；
  `onInterceptRequest` 回调有 hilog（`[CodecGuard] intercept pass/rewrite`）；上一轮桌面 UA 未被破坏。
- **注入**：`fix_browser_avc/inject.sh <disk-image>`（p2 原地 `rm`+`write`+`e2fsck`+读回校验，
  **镜像参数必填**以免误改交付镜像；已用 `cp --sparse` 副本验证，p1/p3+ 字节级未变）。
- **重要教训**：
  1. **ArkWeb 的 `onInterceptRequest` 不能改写请求 URL**（回调只给只读 `WebResourceRequest`）→
     改写取流参数的**真正生效路径是页面层 JS**；`onInterceptRequest` 只能原生拉流回填（兜底）。
  2. **注入脚本是 TS 字符串常量，ArkTS 编译器不检查里面的 JS 语法** —— 本轮因多一个 `)`
     导致整个脚本静默失效（页面里 `guardInstalled=false`）。
     → `build_browser.sh` 末尾强制 `check_guard_js.py`（从 HAP 抽脚本跑 `node --check`），不过就构建失败。
  3. guest 里驱动浏览器导航页面可用：`hdc shell "aa start -a MainAbility -b com.ohos.browser -U <url>"`
     （ability 名是 **MainAbility**，不是 EntryAbility）；触摸坐标 `raw = px*32767/尺寸`（**Y 不反转**）。
- **遗留**：点播 `/x/player/wbi/playurl` 的 `fnval` 改写对 **WBI 签名请求无效**（有意跳过）；
  点播落 AVC 靠 ①HEVC 屏蔽 + ②DASH 响应剔除；直播 `format=2` 能否播取决于站点是否发 fmp4 流；
  真机未做运行期验证（判据见 SUMMARY §5）。

## 32. 【已定性】宿主 Intel PTL 硬解能力取证：H.264/HEVC 都能硬解，走 VA-API+iHD→xe（2026-10-21，hwdec）

> 报告：`out/x86_64_virt/ohos-dbg/hwdec/SUMMARY.md`（含全部命令/输出/strace 证据/移植清单）。
> **纯宿主验证，未碰真机、未改交付镜像。**

- **结论**：Ubuntu 26.04 / Intel PTL(8086:0xb080) / xe 上，**H.264 与 HEVC 都能硬件解码**；
  用户态通路 = `libva(2.23) → iHD 26.3.2 → libdrm → /dev/dri/renderD128 → xe 原生 ioctl`
  （strace 见 `DRM_IOCTL_XE_EXEC` 606 次；**无 /dev/video\***，不是 i915 老路）。
  oneVPL（dispatcher 2.17.0 源码构建 + Intel GPU Runtime `libmfx-gen.so.1.2` 26.3.2）同样能解，
  其实现内部也是 VA-API 模式（`accel=0x400 MFX_ACCEL_MODE_VAAPI`）。
- **关键更正**：公开仓 `github.com/intel/vpl-gpu-rt` **没有实现源码**（无 `source/` 目录，
  CMakeLists 末尾 `include(sources_ext.cmake OPTIONAL)` 私有）⇒ **oneVPL 的 "DRM 插件" 无法从
  公开源码构建**，只能取 Intel 预编译二进制 → **不适合移植到 OHOS musl**。
- **硬解 vs 软解（3 次重复，ffmpeg 软解对照）**：1080p H.264 CPU 时间 0.54s vs 1.16s；
  1080i HEVC 0.25s vs 1.43s（**硬解只用 ~0.6 核，软解要 4~6 核**）。墙钟上软解反而更快
  （ffmpeg SIMD+多线程），**硬解的价值是 CPU 余量，不是延迟**；硬解每帧固定开销 1.2~3.0 ms。
- **Chrome 现状**：本机 Chrome 153 的 GPU 进程退化成 SwiftShader（`No suitable EGL configs found`），
  `chrome://gpu` 报 `video_decode: disabled_software` ⇒ **当前没硬解**，但根因是 EGL 初始化失败，
  **不是硬件不支持**（Firefox 未安装）。
- **移植建议（按性价比）**：①最高性价比 = 往 OHOS 镜像塞 `libva.so.2` + `libva-drm.so.2` +
  `iHD_drv_video.so`（放 libva 编译期 dri 目录，OHOS 交叉编译时指向 `/system/lib64/dri`），
  ArkWeb/Chromium 的 `OzoneVaapiVideoDecoder` 即可自动硬解 H.264/HEVC/VP9/AV1
  （`vainfo` 显示这些 profile 都有 VLD），**不改任何 OHOS C++ 代码**；②中期 = 新增
  `drivers/peripheral/codec/hal/va`（现只有 `idl_service`，无厂商实现；`zcodec/` 是软解 VDI 模板）；
  ③不推荐 oneVPL（闭源 + musl 无源码）。
- **OHOS 侧前提已就绪**：内核 `linux-7.2` 已有 xe（`XE_ENGINE_CLASS_VIDEO_DECODE` + exec queue），
  固件已注入（§17）；`third_party/libdrm` 树里已有（**只缺 libva 与 iHD 驱动**）。
- **踩坑**：①`gstreamer1.0-vaapi` 1.26 的 element 叫 `vaapih264dec`/`vaapih265dec`（不是 `vaapidecode`）；
  ②TS demux 叫 `tsdemux`（不是 `mpegtsdemux`）；③`libgstlibav.so` 缺一串运行库要逐个
  `apt-get download`+`dpkg-deb -x`（无 root 不装系统包）；④libva **2.24 删了经典 API**
  （无 `vaRenderBuffer`/`vaMapSurface`），独立 libva 探针在宿主上因此没跑通
  （能力证据由 GStreamer vaapi + strace 给出）；⑤`h265parse` 解析不了 `Sintel_272p_logo.265` 的 SPS
  （但 oneVPL 能解）⇒ **不能只用 GStreamer 判据**。

## 33. 【已移植】oneVPL 硬解链路（dispatcher + GPU runtime + libva + iHD）→ 探针 + init 服务（2026-10-21，fix_hwdec_probe）

> 报告：`out/x86_64_virt/ohos-dbg/fix_hwdec_probe/SUMMARY.md`（含全部命令/日志/证据/回退）。
> 树内新增：`device/pc/ptl/hwdec_probe/{hwdec_probe.c,hwdec_probe.sh,init.hwdec_probe.cfg,README.md}`。
> **交付镜像未改**（`partdisk/media/ohos_part_pc_ptl.img` 原样），验证在 `fix_hwdec_probe/scratch.img`（cp --sparse 副本）。

- **重要更正（推翻 §32 的"oneVPL 没有实现源码"）**：`github.com/intel/vpl-gpu-rt` **有完整实现**
  （`_studio/` + `api/` + `contrib/`），CMake 可构建；本轮用 **OHOS SDK clang 15
  （--target=x86_64-linux-ohos, musl sysroot）交叉编译成功**，产出 `libmfx-gen.so.1.2`（oneVPL
  GPU Runtime，26.4.1）= dispatcher 认的"实现插件"。dispatcher 用 `github.com/intel/libvpl`
  （Apache-2.0，2.17.0）→ `libvpl.so.2`。**两者必须版本配对**（本轮都是 main：mfxdefs MFX_VERSION 2.17）。
- **真实链路**（"DRM 插件"其实不存在这个独立组件）：
  `libvpl.so.2` → `libmfx-gen.so.1.2` → `libva.so.2`/`libva-drm.so.2`/`libdrm.so.2` →
  `dri/iHD_drv_video.so`（Intel media-driver 26.4.1）→ `libigdgmm.so.12`（gmmlib，**直接做 DRM
  ioctl，不经 libdrm**）→ 内核 xe（`DRM_IOCTL_XE_EXEC` + `XE_ENGINE_CLASS_VIDEO_DECODE`，**内核不用改**）。
  media-driver 26.4.1 已含 `agnostic/Xe_M/Xe_XPM/codec`（xe 专用 codec 路径）与 `Xe3P_M_plus`（PTL）。
- **本轮移植的 5 个上游组件**（都在 `out/.../fix_hwdec_probe/src/`，仓库源码未动）：
  libdrm 2.4.134 / libva 2.25.0 / media-driver 26.4.1 / gmmlib master / libvpl 2.17.0 /
  vpl-gpu-rt 26.4.1。交叉文件：`ohos_x86_64.cmake`(CMake) + `ohos_x86_64_cross.ini`(Meson)；
  C++ 静态（`-static-libstdc++`）→ 注入的 .so 不依赖设备 libc++.so ABI。
- **4 个真坑（都修了）**：
  ①media-driver 26.x 需要**兄弟目录**放 `gmmlib`（`BS_DIR_GMMLIB=${BS_DIR_SOURCE}/gmmlib/Source/GmmLib`），
    否则 `pkg_check_modules(igdgmm>=12)` 失败；②media-driver 把 `-std=c++14` 放在**通用** compile
    options 里 → **clang 拒绝 C 文件用 `-std=c++14`**（GCC 只警告）；③`bs_set_defines()` 硬编
    `-std=c++11` 覆盖掉 `-std=c++1y` → `std::make_unique` 编不过（补丁 `src/media-driver-ohos-port.patch`，2 文件 7 行）；
    ④交叉编译时 gmmlib 的 **ULT 单测**会在宿主跑 OHOS musl 二进制而失败 → 只 build
    `--target iHD_drv_video igfx_gmmumd_dll`。
- **OHOS init 的 `import` 必须是绝对路径**：`init_config.c:ParseAllImports()` 先当**参数名**查、
  相对路径相对 init 的 cwd → 写 `"init.hwdec_probe.cfg"` 会导致**服务根本没注册**
  （症状：`param get init.svc.hwdec_probe` 报 106）。正确写法 `"/vendor/etc/init.hwdec_probe.cfg"`。
- **放哪个分区**：pc_ptl 的 p2(system) 只剩 **23 MiB**，这堆库约 70 MB → 全放 **p3(vendor)**
  `/vendor/lib64`（~477 MiB 空闲，且 `/vendor/lib64` 在 musl namespace 搜索路径
  `/system/etc/ld-musl-namespace-x86_64.ini` 里）。p2 只放探针二进制+脚本+样本（~200 KB）。
- **交付物**：`inject.sh <image>`（幂等；p2/p3 各 `e2fsck`；逐文件 sha256 自校验；并 patch
  `/etc/init.pc_ptl.cfg`：import + boot job 加 `start hwdec_probe`，**放在 /dev/dri chmod 之后**）。
  产物 13 个文件 ≈ 69 MB（iHD 驱动 42 MB、runtime 18 MB、dispatcher 4.9 MB…）。
- **探针** `hwdec_probe`：oneVPL 2.x API，自己按 Annex-B 切 NAL 逐个投喂；输出
  `HWDEC: impl/header/frame N/SUMMARY frames=.. fps=.. cpu_ratio=../RESULT=OK|FAIL reason=..`；
  **永不 panic**，所有失败路径都 `return 0`；日志双写 `/sys_prod/hwdec_probe.log`
  （只读则回落 `/data/local/tmp/hwdec_probe.log`）+ `OH_LOG_Print`（tag `HWDEC`，domain 0xD003C00；
  **LOG_DEBUG 会被 hilog 级别过滤掉**，用 LOG_INFO）。
- **QEMU 结构化验证（x86_64_virt）**：探针在 OHOS musl 上跑起来、**优雅失败退出 0**；
  dispatcher/runtime/libva/iHD 全部可 dlopen；唯一失败点是 **QEMU 没有 Intel GPU**
  （`/dev/dri/card0` 是 virtio-gpu → `vaInitialize rc=3` → `implementations found=0`）；
  **init 服务开机自动跑通**（`/sys_prod/hwdec_probe.log` 被创建）。
- **真机判据**：`/sys_prod/hwdec_probe.log` 出现 `HWDEC: RESULT=OK decoded_frames=N` +
  `SUMMARY frames=.. fps=.. cpu_ratio=..%`（cpu_ratio 低 = 真走硬件）；失败看 `reason=`。
- **遗留**：真机硬解未验证（本轮无 Intel GPU 机器）；还没写 OHOS codec HDI（下一步）；
  只有 H.264 样本（HEVC 走同一路径但没样本）；iHD 驱动 42 MB 可用
  `-DENABLE_NONFREE_KERNELS=OFF` 裁剪。

## 33. 【硬解】oneVPL/iHD 整栈已移植到 OHOS musl，探针待真机验证（2026-10-21，fix_hwdec_probe）

> 报告：`out/x86_64_virt/ohos-dbg/hwdec/SUMMARY.md`（宿主实测）、`out/x86_64_virt/ohos-dbg/fix_hwdec_probe/SUMMARY.md`（移植）。
> **交付镜像 = `494fbb475d52f9ce47bd18327864523023a26429b0958e8eb5f953e4377b4065`**（含 §29~§32 全部 + 本轮硬解栈）。

### 33.1 宿主实测：这台机器**能**硬解 H.264 与 HEVC
- **oneVPL 路线**：`libvpl` 2.17.0（dispatcher，Apache-2.0）+ `libmfx-gen`（GPU Runtime 26.4.1）→ `impl[0] name='mfx-gen' accel=0x400(VAAPI)`；H.264 解 600 帧、HEVC 解 198 帧。
- **VA-API 路线**：GStreamer `vaapih264dec`/`vaapih265dec` 全绿。
- **内核通路（strace 实测）**：`libva→iHD→libdrm→/dev/dri/renderD128→**xe 原生 ioctl**`，`DRM_IOCTL_XE_EXEC` **606 次**，**无 /dev/video\***。
- **硬解 vs 软解**（3 次重复）：1080p H.264 CPU **0.54s vs 1.16s**；1080i HEVC **0.25s vs 1.43s**（硬解≈0.6 核，软解 4~6 核）。每帧硬解固定开销 1.2~3.0 ms。
- ⚠️ **更正 §32 的两处错误**：
  ① `intel/vpl-gpu-rt` **有完整实现源码**（`_studio/`+`api/`），本轮已成功交叉编译，§32 说"无源码"是错的；
  ② 宿主 Chrome 的 GPU 进程退化成 **SwiftShader**（`No suitable EGL configs found`）→ `video_decode: disabled_software`，
  即**宿主浏览器其实在软解**，"Ubuntu 能正常看 B 站"并不代表浏览器在用硬解（硬件能力由上面的 gst/oneVPL 探针证明）。

### 33.2 内核侧结论（OHOS 不用改内核）
- `linux-7.2/drivers/gpu/drm/xe/xe_exec.c` → `DRM_IOCTL_XE_EXEC` / `DRM_IOCTL_XE_EXEC_QUEUE_CREATE`（oneVPL DRM 插件提交作业用）
- `xe_configfs.c:311` → `.cls="vcs", engine_class=XE_ENGINE_CLASS_VIDEO_DECODE`（解码引擎已在 xe 建模）
- **我们内核没有 V4L2 stateless**（只有 `VIDEO_V4L2_I2C/SUBDEV/TPG`）→ V4L2 路线在 OHOS 走不通，**xe EXEC 是唯一路径**。

### 33.3 已移植到 OHOS musl x86_64（树内 `device/pc/ptl/hwdec_probe/`）
```
libvpl.so.2 (2.17.0) → libmfx-gen.so.1.2 (26.4.1) → libva.so.2 / libva-drm.so.2 / libdrm.so.2
   → dri/iHD_drv_video.so (media-driver 26.4.1) → libigdgmm.so.12 (gmmlib) → 内核 xe exec queue
```
探针 `hwdec_probe`（Annex-B 切 NAL 逐帧喂）→ `/sys_prod/hwdec_probe.log`（`HWDEC: RESULT=OK decoded_frames=N` + `SUMMARY cpu_ratio=..%`）。
**4 个真坑**：media-driver 26.x 需兄弟目录放 gmmlib；`-std=c++14` 放在通用 flags 里 clang 拒 C 文件；`bs_set_defines` 硬编 `-std=c++11` 覆盖 c++1y；gmmlib ULT 交叉编译必失败（只 build 指定 target）。
**OHOS init 的 `import` 必须是绝对路径**（相对路径 → 服务不注册，`param get init.svc.hwdec_probe` 报 106）。

### 33.4 下一步（等真机探针结果）
1. 探针 `RESULT=OK` → 实现 **`drivers/peripheral/codec/hal/va`**（OHOS 视频解码 HDI 组件，包 oneVPL/VA-API）→ ArkWeb 的 `OhosVideoDecoder` 自动走硬解 → **直播 H.264/HEVC/VP9/AV1 不再软解**（直播"只播一两帧+极卡"应随之解决）。
2. 探针失败 → 看 `reason=`（多半是 `renderD128` 权限/dma-buf sandbox 映射 → 补 ueventd/SELinux）。
3. **HEVC 在 ArkWeb 内仍需重编引擎**（M114 的 `enable_hevc_parser_and_hw_decoder` 对 OHOS 关闭 → 连轨道都解析不了）；但有了 HDI 后，重编只需开 parser 开关，**不必把 HEVC 解码塞进 ffmpeg**（避开浏览器内的专利风险）。

## 34. 【已实现】一条命令诊断 + 一个文件看懂全部结论（2026-10-22，fix_diag3）

> 报告：`out/x86_64_virt/ohos-dbg/fix_diag3/SUMMARY.md`（含完整 VERDICT 样例、注入/回退、真机取包步骤）。
> **交付镜像未改**（`partdisk/media/ohos_part_pc_ptl.img` sha 仍 `494fbb47…`），本轮只给注入脚本。
> 树内改动：`base/startup/ohos_diag/ohos-diag`（该目录不是 manifest 仓，不用提交）。

### 34.1 用法
- **`ohos-diag` 不带参数 = 全量**（11 段：bootlog/fixes/desktop/bluetooth/audio/ime/system/perf/wifi/media/**hwdec**），
  产出 `tar.gz`（~3 MB，~100 s）。输出目录优先 `/ohoslog` → `/sys_prod/ohos-diag` → `/data/ohos-diag` → `/data/local/tmp`。
- **包首文件固定是 `VERDICT.txt`**（`tar -tzf` 第一行）：一张
  `项目 | 期望 | 实测 | PASS/FAIL/WARN/SKIP` 表，覆盖 9 类 58 个判据（桌面/音频/蓝牙/Wi-Fi/视频/性能/硬解/开机日志/修复清单）。
  未进表的检查项自动落到表尾 `[其它]` 段，不丢信息。
- 真机取包：`hdc file recv /sys_prod/ohos-diag/diag-<ts>.tar.gz .` → `tar -xzOf <包> VERDICT.txt`。
- 新增 **hwdec 段**：读 `/sys_prod/hwdec_probe.log`（回落 `/data/local/tmp/`、`/proc/1/root/`），
  解析 `RESULT=OK|FAIL` / `decoded_frames=N` / `SUMMARY cpu_ratio=X%` / `reason=…` / `implementations found=N`，
  出明确 PASS/FAIL；**原始日志原样打进包**（`H_hwdec_probe.log`）。
- 修复清单从 30 条扩到 **38 条**（补 §33 的 oneVPL/libva/libmfx/iHD 硬解栈），`fixes/all-match` 汇总判据。

### 34.2 本轮顺带修掉的 5 个真 bug（**都在真机上暴露，宿主测不出来**）
1. **设备没有 `tr`**（只有 toybox+mksh）→ 旧脚本 6 处 `tr` 全报错；新增 `oneline()`（`sed ':a;N;$!ba;s/\n/ /g'`），cmdline 用 `strings`。
2. **toybox grep 不认 BRE 的 `\|`** → `vgrep` 的 `'sof\|hda\|snd\|asoc'` 被当字面量 `|`，
   「开机 dmesg 含 SOF/BT/iwlwifi」永远 FAIL。改 `grep -aE` + ERE（另 3 处普通 grep 同改）。
3. **mksh 把 `${row%%|*}` 里的 `|` 吞掉**（实际退化成 `${row%%*}`）→ VERDICT 表两列错位。
   改 `vlookup()` 用两个全局变量返回。⚠️ **宿主 busybox ash 是对的，只有设备上才复现**。
4. **并发互杀**：开机服务 `zz_diag_boot.sh`（240 s 自动跑）与手动跑互相删对方的临时目录 → 两个空包（实测 4.6 KB）。
   现在有目录锁 `/sys_prod/.ohos-diag.lock`（owner pid，死锁自动接管）+ 临时目录 `.owner`。
5. **`param get` 对不存在的参数返回错误信息而非空串** → `once:1` 的 `init.svc.hwdec_probe` 跑完就被 init 删掉，
   被误判成「服务异常」。现在按 `fail|rror|not found|106` 识别为未注册，改用日志存在与否判定。

### 34.3 注入 / 验证
- `out/.../fix_diag3/inject.sh <image>`：**字节级幂等**（内容已是最新时「already up to date」，
  连 e2fsck 都不跑，镜像 sha 不变）；默认**拒绝**写交付镜像（要 `--force`）。
- QEMU 验证（pc_ptl 磁盘镜像，`cp --sparse` + `sgdisk -e` 补 GPT 备份头）：
  不带参数跑完 11 段、包首 `VERDICT.txt`、PASS=79/FAIL=9/WARN=4/SKIP=5（9 个 FAIL 全是 QEMU 缺硬件）；
  单跑 `ohos-diag hwdec` 其余段全 SKIP 不报错；开机自动触发那次的包也完整。
- **教训**：诊断脚本这类东西，**必须真机/真 guest 上跑一遍**——宿主 ash 与设备 mksh+toybox 差异很大。

## 35. 【已修】硬解探针 `DecodeHeader sts=-10` = `DataLength` 没赋值（不是 INVAL！）+ libva DRI 路径 + 音频判据（2026-10-22，fix_hwdec2）

> 报告：`out/x86_64_virt/ohos-dbg/fix_hwdec2/SUMMARY.md`（含 file:line、宿主真实 GPU 证据、QEMU 证据、回退）。
> 交付镜像 **未改**（`partdisk/media/ohos_part_pc_ptl.img` sha 仍 `575eefcc…`）；验证在 `fix_hwdec2/scratch.img`（cp --sparse）。

### 35.1 关键更正：`-10` 是 `MFX_ERR_MORE_DATA`，不是 `MFX_ERR_INVAL`
- `onevpl_src/api/vpl/mfxdefs.h:285` → `MFX_ERR_MORE_DATA = -10`（"Expect more data at input"）。
- 真机 `HWDEC: FAIL DecodeHeader sts=-10` 的真因：**v1 探针从未给 `mfxBitstream.DataLength` 赋值**
  （旧 `hwdec_probe.c:434-438` 只给了 `MaxLength`；`:495-496` 的每个 NAL 同样没给）
  → 运行时看到的是**空码流** → "数据不足"。
- 修法：按官方 oneVPL 喂流方式（未消费数据 memmove 到头部 + 从文件追加），补齐
  `CodecId/FrameRateExtN,D/NumThread/IOPattern`，`DecodeHeader` 失败时退回"最小参数集"再试一次。
- **决定性验证**：用**设备同一份样本**（`moonlight.264` 191 113 B）在本机真实 Intel PTL GPU 上
  编译 glibc 版探针 → `vpl header w=512 h=384 fourcc=NV12` + **60 帧** +
  `cpu_ratio≈45%`、`0.34~6 ms/帧`、`RESULT=OK decoded_frames=60`（修复前是 sts=-10）。

### 35.2 libva 编译期 DRI 路径（真 bug，已修）
- `strings libva.so.2.2500.0` 里是**宿主暂存目录** `.../fix_hwdec_probe/stage/usr/lib/dri`
  （来自 meson 选项 `driverdir` → `src/libva/va/meson.build:79` 的 `-DVA_DRIVERS_PATH=`）。
- 修：**重编 libva 加 `-Ddriverdir=/vendor/lib64/dri`**（新串 `/vendor/lib64/dri`）
  + `LIBVA_DRIVERS_PATH=/vendor/lib64/dri:/system/lib64/dri`、`LIBVA_DRIVER_NAME=iHD` 兜底
  （**只在目录真实存在时才设**，否则会破坏宿主/系统里已有的正确配置——踩过）。
- QEMU 证据：`libva info: Trying to open /vendor/lib64/dri/iHD_drv_video.so` + `Found init function` ✓。

### 35.3 上一版 `vaInitialize rc=3` 是**假警报**
- v1 调 `vaInitialize(&dpy)` 且 `dpy==NULL` → `CHECK_DISPLAY` 必然返回
  `VA_STATUS_ERROR_INVALID_DISPLAY=3`（`src/libva/va/va_internal.h:49`、`va.h:267`）→ **根本没测到驱动**。
- v2：open `renderD128`→`card0`→`card1`，`vaGetDisplayDRM(fd)`→`vaInitialize(dpy,&maj,&min)`，
  打印**完整 rc + vaErrorStr**、节点权限、`vaQueryVendorString()`；
  并把 **stderr 重定向进日志文件**，libva/iHD 自己的 "Trying to open…" 也能进日志。

### 35.4 纯 VA-API 备路（部分可用，留作遗留）
- `vaCreateBuffer(VASliceDataBufferType)` 必须 `num_elements==1`
  （media driver `media_ddi_decode_base.cpp:980`）；且**一帧多 slice 时必须拼进同一个 buffer**。
- 即便如此，iHD AVC VLD 仍要求经典 slice 参数缓冲（`m_numSlices` 只在
  `VASliceParameterBufferType` 分支累加，`media_ddi_decode_avc.cpp:442`）→ `vaEndPicture rc=18`。
  → **oneVPL 主路可用，VA 通路留作将来写 codec HDI 的参考**。

### 35.5 `ohos-diag` 音频判据（顺手修）
- 真机 `aplay -D default` → `audio open error: Resource busy`（**audio_host 独占设备**，不是故障）→ 原判 FAIL。
- 改：新增 `audio/aplay-null-playback`（`-D null` 判 alsa+PCM 通路）、
  `audio/device-exclusive-owner`（`audio_host` 在跑 ⇒ PASS）；
  `audio/aplay-default-playback` 遇 "Resource busy" 且 audio_host 在跑 ⇒ **PASS（注明独占）**，
  没有 audio_host ⇒ WARN，其它 ⇒ FAIL。修复清单期望值同步更新。
- QEMU 实测（设备 shell mksh+toybox）见 `fix_hwdec2/evidence/qemu_verdict_audio.txt`。

### 35.6 产出
- `device/pc/ptl/hwdec_probe/hwdec_probe.c`（v2：帧数/每帧耗时/`CLOCK_PROCESS_CPUTIME_ID` 的 cpu_ratio）、
  `device/pc/ptl/hwdec_probe/hwdec_probe.sh`（环境变量）。
- `out/.../fix_hwdec2/{inject.sh,package.sh,build_probe.sh,prepare_qemu_test.sh,launch_qemu_test.sh,scratch.img}`
  （幂等、逐文件 sha256 自校验、不碰交付镜像）。
- **真机判据**：`/sys_prod/hwdec_probe.log` 出现 `RESULT=OK decoded_frames=N` + `cpu_ratio` 很低
  + `vpl header w=512 h=384 fourcc=NV12`。

## 36. 【已定性】蓝牙链**没断**，断的是「没人按开关」+ vendor HAL 日志落不了盘（2026-10-22，fix_bt2）

> 报告 `out/x86_64_virt/ohos-dbg/fix_bt2/SUMMARY.md`；证据 `fix_bt2/evidence/{qemu_bt_chain.txt,qemu_VERDICT.txt}`。
> 产品 `pc_ptl`。**交付镜像未改**（`partdisk/media/ohos_part_pc_ptl.img` 原样），
> 验证在 `fix_bt2/scratch.img`（`cp --sparse` 副本）上做。

### 36.1 三个结论（推翻上一轮"链断了"的判断）
- **HDF 侧是好的**：真机 `blue_host`(pid 1744) 在跑，日志有 `HdfHciInterfaceDriverBind/Init`
  （`drivers/peripheral/bluetooth/hci/hdi_service/hci_interface_driver.cpp:118/129`）。
  **不需要**补 `bluetooth_chip` 节点；`/dev/hdf` 不存在与本链无关。
- **协议栈从未进 HCI 初始化**：`HCI_Initialize()`（`stack/src/hci/hci.c:172`）整段开机日志里
  **一次都没有**。它只能由 `BTM_Enable()`（`stack/src/btm/btm.c:255/302`）触发，
  `BTM_Enable` 只能由 `ClassicAdapter::StartUp()`（`classic_adapter.cpp:73`）触发
  ⇒ **根因是没人调 `enableBluetooth()`**。
  真机日志里 `bt_napi_access: GetState` 有 58 次，**`bt_napi_access: (EnableBluetooth:77)enter` 0 次**
  （`js/napi/src/access/napi_bluetooth_access.cpp:77`）⇒ 设置应用/SceneBoard 只读状态、从未开蓝牙。
- **"BT hilog 域为空"是假阴性**：`/sys_prod/zz_bt_hilog.log`（144 KB）里**有**完整 C00101/C00102/C00105。
  上轮 VERDICT 只看 `hilog -x` 环形缓冲（覆盖 09:32–09:51），而 BT 日志在 09:27–09:31 已被冲掉。

### 36.2 第二个真 bug：vendor HAL 的日志**落不了盘**
vendor HAL 由 **`blue_host`（uid 3021）** dlopen，但它只往文件写 + stderr：
`/sys_prod`=root:root 0755、`/data/local/tmp`=shell:shell 0770、`/mnt/od` 未挂载 ⇒ **一个都写不了**；
stderr 也不进 hilog。⇒ **HAL 明明跑了，日志一条都没有**（上轮"改好 vendor HAL 就该出日志"的预期是错的）。
- **修**（`vendor/pc/pc_ptl/bluetooth/src/bt_vendor_linux.c`）：加 **hilog** 落点
  （懒 `dlopen("libhilog.so")` → `HiLogPrint(LOG_CORE, LOG_INFO, 0xD000105, "bt_vendor", ...)`），
  文件落点保留 + 加 `/data/vendor/bluetooth/bt_vendor.log`。

### 36.3 新增工具（让"链"可以被一键跑起来）
- **`/system/bin/bt_enable`**（`fix_bt2/tools/bt_enable.cpp`）：调**和 ArkTS 完全相同**的入口
  `OHOS::Bluetooth::BluetoothHost::GetDefaultHost().EnableBle("bt_enable", false)`，
  链接镜像里现成的 `/system/lib64/platformsdk/libbtframework.z.so`（无新依赖）。
  打印 `IsBluetoothSupported` / 前后状态 / 返回码。
  ⚠️ 构建：`--target=x86_64-linux-ohos --sysroot=out/ptl/obj/third_party/musl`；
  **不要**再加 `-isystem <clang resource include>`（会盖掉 libc++ 自带的 C++ 版 `<stddef.h>`，`<string>` 编译不过）。
- **`/system/bin/bt_diag.sh`**：一条命令出断点（L0..L5，见 SUMMARY §2.2）。
- `ohos-diag` 蓝牙段：跑 `bt_diag.sh`、收流式采集器、**新增 7 条链路判据**；
  `bt/hilog-domain-has-lines` 改为先看流式采集器（修假阴性）；
  `bt/libbt-vendor-mapped` 改查 **blue_host** 的 maps（vendor HAL 在 HDF host 里，不在 bluetooth_service）。
- `zz_hilog_persist.sh` 新增**内容过滤**采集器 `hilog -e "<regex>"` → `/sys_prod/zz_bt_all.log`
  （**不限域**，因此能抓到设置应用/SceneBoard/blue_host 的行——这正是判断"开关有没有被按"的证据）。

### 36.4 QEMU 端到端（**链是通的**）
`bt_enable` 返回 0（REQUEST_ACCEPTED），hilog 里 L0..L5 **全部命中**，
止步于 `BT_OP_HCI_CHANNEL_OPEN: could not obtain raw HCI sockets`（**QEMU 无 BT 硬件，预期**）。
⇒ 上一轮修的库名/`NET_RAW`/H4 切帧**全部生效**；真机唯一缺的是"有人按开关"。

### 36.5 真机判据（下一轮照跑）
```sh
hdc shell "/system/bin/bt_diag.sh 8"     # L0..L5 + FIRST MISSING LINK
hdc shell "cat /sys_prod/zz_bt_all.log | grep -a bluetooth | tail -100"   # app 侧有没有调 enableBluetooth
hdc shell "hidumper -s 1130 -a '-br'"     # ★SA id 是 1130，不是 -s Bluetooth
```
真机成功的标志：hilog 出现 `C00105/bt_vendor: BT_OP_HCI_CHANNEL_OPEN ok: returning 1 channel` 与
`HCIDEVUP hci0 ok`。
⚠️ **`bt_vendor.log` 文件在真机上仍然不会有**（blue_host 没权限建文件）——看 hilog tag `bt_vendor`。

## 37. 【已定性】真机"完全没声音" = 拓扑/音量都不是问题，嫌疑只剩 DAI 混音器与框架侧（2026-10-22，fix_sof_topo）

> 报告：`out/x86_64_virt/ohos-dbg/fix_sof_topo/SUMMARY.md`（事实出处 file:line、判据、真机判据、回退）。
> **交付镜像未改**（`partdisk/media/ohos_part_pc_ptl.img` sha 仍 `c2bc9d68…`）；验证在 `fix_sof_topo/scratch.img`。

### 37.1 关键事实（推翻"要换 sof-ptl-*.tplg"的假设）
- 本机模拟 codec 是 **Realtek ALC256，挂在 HDA 链上**（`ehdaudio0D0`），**不是 cSSP/SDW**：
  `hda codecs found, mask 5` + `using HDA machine driver skl_hda_dsp_generic now`。
  → 正确拓扑就是当前的 **`sof-hda-generic-4ch.tplg`**（HDA 族），`sof-ptl-*` 全是 cSSP 机器的，换上去会没模拟输出。
- 拓扑名**不是** ACPI/匹配表定的：内核按 `soc-acpi-intel-hda-match.c:16`（基名 `sof-hda-generic`）
  + `sound/soc/sof/intel/hda.c:1556-1607`（`-<dmic_num>ch` fixup，NHLT DMIC=4）算出来，
  目录 `sound/soc/sof/intel/pci-ptl.c:48`；可用模块参数 `sof_tplg_filename=` 覆盖。
- **没有名为 "Speaker" 的 PCM**：`00-00 HDA Analog` 就是扬声器通路；`Speaker`/`Headphone` 是 **codec 的 mixer 控件**。
- 音量控件**已修好并在交付镜像里**（p3 的 `libaudio_render_adapter.z.so` 15-Oct 版含
  "Render volume control probed"）——但真机 Master=56 是 **codec 上电默认值**，说明**框架从没调过 SetVolume**。
- ⚠️ **内核语义（上一版文档写反了）**：`snd_ctl_find_id()` **numid 优先于 name**
  （`kernel/linux/linux-7.2/sound/core/control.c:855`）。老代码硬编码 `numid=1` 在本机会打到
  **`Headphone Playback Volume`**，扬声器音量永远不动；修法是 `numid=0` + 按名字解析。
- **同机 Ubuntu 是决定性对照**：同一份拓扑、同一块 ALC256，PipeWire 的 `Speaker` sink `RUNNING`，
  DAI 混音器 numid 31/32 = 45/45（max），`Auto-Mute Mode` = Disabled ⇒ **SOF/固件/codec 侧是好的**。

### 37.2 本轮改动
- `base/startup/ohos_diag/ohos-diag`：新增 4 个判据（`audio/master-ctrl-unmuted`、
  `audio/speaker-output-pcm-present`、**`audio/pcm-data-flowing`**（hw_ptr 是否在动 = 框架有没有喂 PCM）、
  `audio/sof-dai-mixer-nonzero`）；并修掉 `oneline "$X"` 误用（`oneline` 读 stdin，不是参数）。
- `base/startup/ohos_diag/zz_audioup.sh`：DAI 混音器**强制拉 max**（max 从控件解析）、打印完整 mixer map。
- `base/startup/ohos_diag/zz_audioguard.sh`（**新**）：**常驻守护**，每 2 s 复查并按需拉满 DAI 混音器
  （SOF 建流时会重新初始化 DAI-link 控件，开机一次性写入会被覆盖）+ 保持 `Auto-Mute Mode` Disabled。
- `etc/zz_audio.cfg` + `BUILD.gn`：注册该守护服务。
- `fix_sof_topo/inject.sh`：幂等注入（幂等判据=**载荷内容**，ext4 镜像本身不逐字节相同），末尾打印 payload manifest。

### 37.3 真机下一步（一条命令）
```sh
hdc shell "ohos-diag audio"        # 14 个音频判据
hdc shell "ohos-diag audiotest"    # 破坏性：内核通路(hw:0,0 放音) vs 框架通路
```
判读表见 SUMMARY §5：`kernel-tone-hw0` PASS + `pcm-data-flowing` FAIL ⇒ **框架开了 PCM 却没写数据**
（查 HPAE / hdiadapter_new 的 hilog）；`kernel-tone-hw0` FAIL ⇒ SOF DAI 混音器/codec 侧
（`zz_audioup`+`zz_audioguard` 已开机自动拉满，仍 FAIL 则查 IPC4 pipeline/hw_params）。

## 38. 【已修】PC 桌面页无 app 图标 = 桌面项没有 page（integrateSwiper 丢弃） + hidumper root 放行（2026-10-22，fix_desktop2）

> 报告：`out/x86_64_virt/ohos-dbg/fix_desktop2/SUMMARY.md`（含 file:line、A/B 截图、注入脚本、回退）。
> 产品 `pc_ptl`。**交付镜像 `partdisk/media/ohos_part_pc_ptl.img` 本轮未改**（sha 仍 `c2bc9d68…`），
> 验证在 `fix_desktop2/scratch.img`；产物：`evidence/pc_sceneboard-default-signed.hap`
> （`be809690…`）+ `evidence/libhidumperservice.z.so`（`c9fa5a3f…`）+ `evidence/ohos-diag`（`72e5f9f5…`）。

- **根因（★ 与真机现象完全对上）**：预置 `layoutInfo.json` 的条目**没有 `page` 也没有 `area`**
  → 落库 `page_index`/`width`/`height` 全 NULL → 读回 `item.page===undefined`
  → `PageDesktopViewModel.integrateSwiper()`（`PageDesktopViewModel.ets:2591-2640`）
  `if (mPage === undefined || mPage < 0 || ...) { logError } else { push }`
  → **没有 page 的桌面项不放进任何一页** → 桌面 0 图标（RS 里只有壁纸+任务栏）。
- **为什么 QEMU 一直不复现**：布局校正器只重排**坐标越界**的项（顺带写 page/area）。
  QEMU 1280x800 → 宫格 3x7，预置坐标（16 列）越界 → 被重排 → page 有值 → 图标出现；
  **真机 3072x1920 → 宫格 10x19，预置坐标全在格内 → 不重排 → page 保持 NULL → 桌面空白**。
  本轮用 **3072x1920（宫格 10x19）** 在 QEMU 里**完整复现**了真机故障（旧 HAP：RS 图标节点 1、屏幕 0 图标）。
- **修法**：`PageDesktopLayoutConfig.normalizeDesktopItemArea()` 运行时把 area 归一为 [1,1]、
  **page 归一为 0** 并落库（两张布局表）；预置 rawfile 每项补 `"area":[1,1]`、`"page":0`；
  `filterItemExceedCurrentScreen()` 对非法 area 按 1x1 处理；桌面渲染 0 图标时兜底
  `rebuildDesktopLayoutFromInstalledApps()`（用已装 app 重建，`DESKTOPREPAIR` 日志）。
  ⇒ **真机那张已经写坏的 DB 不用刷机，开机自愈**（实测 areaFixed=17 → null page/area 归 0 → 17 图标）。
- **自证日志**（30s 周期，环形缓冲冲不掉）：
  `SwiperPage: DESKTOPICONS page=0 list=17 rendered=17 areaOk=17 grid=10x19`、
  `SCBDesktop: DESKTOPICONS ... layoutVisible=17 withArea=17 areaFixed=N`、
  `DESKTOPFILTER kept=/dropped=`、`DESKTOPLAYOUT: normalizeDesktopItemArea fixed= pageFixed=`。
- **ohos-diag 新判据**（真机一条 `ohos-diag desktop` 即可判定）：
  `desktop/db-page`（★根因）、`desktop/db-area`、`desktop/icons-rendered`、
  `desktop/area-normalize`、`desktop/filter-dropped`、`desktop/integrate-swiper`（★丢页现场）、
  `desktop/rs-icon-nodes`（★RS 树里 `SwiperPage_AppItem_*` 计数）、`hidumper/dump-permission`。
- **hidumper 无 DUMP 权限**：§30.1/§31.3 的 `apl`+`permission`+`permission_acls` 在真机**仍失败**
  （`accesstoken_info_manager.cpp:1419` 静默丢弃）；本轮改用
  `dump_manager_service.cpp::HasDumpPermission()` **对 root(uid 0) 放行**（重编 `hidumperservice`
  2 分钟，产物 `out/ptl/hiviewdfx/hidumper/libhidumperservice.z.so`）→ QEMU 实测
  `hidumper -s RenderService -a screen` 正常、`-a RSTree` 能看到桌面图标节点。
- **交付**：`bash out/x86_64_virt/ohos-dbg/fix_desktop2/inject.sh <image>`（幂等：三个文件 sha 自校验 +
  同步 `fix_manifest.txt`；ext4 元数据导致镜像整体 sha 每次不同，属正常）。

## 39. 【已实现】AIRA 浏览器（org.aira.browser）加"屏蔽 HEVC + 取流参数改写"保护（2026-10-22，fix_aira_avc）

> 报告：`out/x86_64_virt/ohos-dbg/fix_aira_avc/SUMMARY.md`。承接 §32/§33（引擎无 HEVC 解码器）
> 与 §33 的 `fix_browser_avc`（**系统浏览器** `com.ohos.browser` 已有保护，**本轮给 AIRA 补上**）。
> 产品 `pc_ptl`。**交付镜像 `partdisk/media/ohos_part_pc_ptl.img` 本轮未改**（sha/时间戳未变）。

- **AIRA 完全可改**（不用换思路）：源码在 `out/x86_64_virt/ohos-dbg/fix_aira_guide/aira_src`
  （公开仓克隆的 **ArkTS 源码树**，非二进制），hvigor 管线已通（§28.2 用它重编过）。
  Web 容器 = ArkUI `Web` 组件 + `WebviewController`，**已支持** `runJavaScriptOnDocumentStart`
  （`core/web/HostedWebNode.ets` → 脚本由 `core/web/BrowserHostedWebDocumentStartScriptCoordinator.ets` 统一产出）
  与 `onInterceptRequest`（`app/pages/BrowserShellPage.ets:12837`）。
- **改法**（1 新增 + 2 小改，全在副本里）：
  新增 `AiraBrowser/entry/src/main/ets/services/web/WebMediaCodecGuardScriptService.ets`（422 行：
  页面层屏蔽 `hev1|hvc1|h265`（isTypeSupported/canPlayType/decodingInfo）+ 改写 fetch/XHR 取流参数
  （点播 `fnval=16`/`prefer_codec_type=1`，直播 `codec=0`/`format=2`，**带 `w_rid` 的 WBI 签名请求不改**）
  + 过滤 DASH 响应里的 HEVC/AV1 轨；网络层 `onInterceptRequest` 兜底用原生 http 拉取回填）；
  `BrowserHostedWebDocumentStartScriptCoordinator.ets`（:13/:62/:91(v3→v4)/:123/:132 挂守卫脚本 + 写运行期标记）；
  `BrowserShellPage.ets`（:116/:12103 网络层兜底）。
- **产物**：新 HAP `fix_aira_avc/Aira-v3.7.2-x86-codecguard-signed.hap`
  sha256 **`db9ce1bb3885e423fa863a678ba7077056048e09f67d2610c3203b37c2f74077`**（41,550,570 B），
  **同一签名/profile**（预装授权条目不用改）；**保留** §28.2 的 HDS 垫片（未回退）。
  补丁 `fix_aira_avc/patch/aira_codec_guard.patch`。
- **注入**：`fix_aira_avc/inject.sh <image> [hap] [--with-diag]`（幂等 + 镜像内 sha 自校验 +
  **拒绝对交付镜像动手**）；落地 p2 的 `/system/app/org.aira.browser/Aira.hap` +
  `/system/etc/aira_codec_guard.conf`（标记）+（可选）`/system/bin/ohos-diag`。
- **"解码器显示"来自页面侧**（B 站播放器自己的"播放信息"，取自 DASH 选中轨的 codecid；
  AIRA 自己**没有** codec UI）⇒ 屏蔽 HEVC + 剔除 HEVC 轨后，页面必然改选 AVC ⇒ 播放信息显示 H.264/AVC。
- **ohos-diag 媒体段新增 2 条判据**（`base/startup/ohos_diag/ohos-diag`，非 manifest 仓）：
  `media/aira-hevc-guard`、`media/browser-hevc-guard`；QEMU 实测 **PASS**（`evidence/VERDICT_media.txt`）。
- **QEMU 已验证**：新 HAP 注入 → 镜像可引导 → AIRA 能装能启动（截图）→ 守卫脚本 `node --check` +
  16 条行为单测全过 → ohos-diag 新判据 PASS。
- **QEMU 未验证（环境限制，与改动无关，如实记录）**：AIRA 首次启动的 FeatureIntro 页在 QEMU 里
  点不动（该页黑色区域是 ArkWeb 渲染、无外网加载失败；"跳过"点不中），故**没能在 AIRA 的 ArkWeb 里
  打开探针页**读页面侧数值；且 AIRA 在 QEMU 冷启动 ≈40 s 会撞 SceneBoard `handleForegroundTimeout`
  被杀（第二次启动才活）。真机判据见报告 §7。
- **顺带发现（调试镜像专用）**：console（native token）调 `aa start` 一律报 10103601
  "bundleName does not exist"，真因是 AMS `ResolveUnknownCallerBackgroundCall` 要求
  `ohos.permission.START_ABILITIES_FROM_BACKGROUND`；给 `/system/etc/init/console.cfg` 加上即可
  （`fix_aira_avc/scripts/patch_console_apl.sh`，**仅调试镜像用，别带进交付**）。

## 40. 交付镜像重建（2026-10-22 深夜）—— dd 血泪坑 + 一键重建链

> **当前交付镜像**：`out/x86_64_virt/ohos-dbg/partdisk/media/ohos_part_pc_ptl.img`
> = **`f1040921bede65a86985fb3b3dc886dbed68cccde21105bea15f6fe5af83ae15`**
> （tag `pc_ptl-b2-rebuild-20261022-2350`；ESP_PART_SHA256 `5576fced…`、P2_KEYFILES `53003bbd…`）。
> 含 §29/§30/§31/§33/§35/§36/§37/§38/§39 全部修复 + `fix_desktop2`（桌面图标）
> + `fix_sof_topo`（音频守护）+ `fix_aira_avc`（AIRA 屏蔽 HEVC）。

### 40.1 【严重】dd 把分区写回整盘时 `skip` 是"输入"，输出要用 `seek`
```sh
# 错（我的错）：skip 只跳输入，输出仍从 offset 0 写 → 冲掉 GPT/ESP
dd if=copy.img of=disk.img bs=512 skip=1050624 count=4194304 conv=notrunc
# 对：
dd if=copy.img of=disk.img bs=512 skip=1050624 seek=1050624 count=4194304 conv=notrunc
```
后果：p1(ESP, Secure Boot 链) 与 GPT 被覆盖。**恢复办法见 40.2**（已验证）。

### 40.2 从基线一键重建（16 个注入脚本，幂等）
`out/x86_64_virt/ohos-dbg/rebuild_chain.sh`：
```sh
zstd -d partdisk/media/ohos_part_pc_ptl.pre_batch6.img.zst -o rebuild.img  # = SB 版基线 92274c80
sgdisk -e rebuild.img
# 依次：desktop_layout → sof_fw3 → bt_hci → input_aira(--with-aira) → net_perf → sysperf
#       → perf2 → diag2 → browser_avc → hwdec_probe → diag3 → hwdec2 → bt2
#       → desktop2 → sof_topo → aira_avc(--with-diag)
```
约 25 分钟，每步 rc 与 sha 写 `rebuild_chain.log`。完成后 `sgdisk -p` 应见 6 个分区、
ESP 四个文件用 `sbverify --list` 应分别显示 Microsoft / OpenHarmony / Canonical / OpenHarmony，
再 `bash partdisk/update_image_id.sh <img> <TAG>` 重算身份戳。
**注意**：注入脚本会拒绝对 `partdisk/media/ohos_part_pc_ptl.img` 动手（保护），
所以重建/试验一律用 `rebuild.img`、`fix_*/scratch.img` 这类副本名。

### 40.3 QEMU 冒烟测试的正确姿势（backing 必须来自交付镜像）
`scripts/run_gl_vnc.sh` 的 `dbg/*.qcow2` backing 是**构建产物**（不含注入）。要测交付镜像：
抽出 p2..p5 → 当 backing 新建 overlay → 用 `hardware=virt` 启动。
已验证结果：`SwiperPage: DESKTOPICONS page=0 list=17 rendered=17`、
`hidumper -s RenderService -a RSTree | grep -c SwiperPage_AppItem` = **17**、
`hidumper -s RenderService -a screen` 正常（root dump 权限修复生效）。
**QEMU 里 `hwdec_probe`/`zz_audio*` 不会注册属预期**：init 只 import
`/vendor/etc/init.${hardware}.cfg`，QEMU 传 `hardware=virt`，真机 grub 传 **`hardware=pc_ptl`**（已核实）。
`zz_audioup/zz_audioguard` 的日志在 **`/data/local/tmp/zz_audio*.txt`**（不是 /sys_prod）。
`snapshot_display` 在 QEMU 新 userdata 上可能报 `Error opening file`（不影响真机/判据已用 RS 树替代）。

### 40.4 真机待验证的四个症状（本轮已装好修复）
1. **桌面无图标** ← `fix_desktop2`：根因是桌面项缺 `page`/`area`（真机 3072x1920 宫格内不触发重排）。
2. **无声** ← 声卡已存在（`zz_sof_reprobe`）；剩 `audio/pcm-data-flowing` + `audio/sof-dai-mixer-nonzero` 判据定案。
3. **视频 HEVC 卡** ← AIRA 已装 codec guard（`db9ce1bb…`），引擎无 HEVC 解码为定论。
4. **蓝牙** ← 链已通，真机只需 `bt_diag.sh`（诊断会自动开开关）；看 hilog tag `bt_vendor`。

## 41. 【归档】改动/补丁全量归档（2026-10-23）

- 产物：`out/x86_64_virt/ohos-dbg/ARCHIVE_2026-10-22.tar.zst`
  **138 MiB**，sha256 **`362f6bca3beb908d1081ae6ee87907fe0bdc511e90af975bed8ebb034596bdc9`**
  （同名 `.sha256` 文件；解压后目录 329 MiB / ~1160 文件）。
  2026-10-23 审计后**补录 3 处先前遗漏**（`applications/standard/app_samples` 的 KikaInput 宽屏键盘、
  `base/hiviewdfx/hiviewdfx_api_metrics` 的 histogram 静默禁用、`kernel/linux/common_modules/` 的
  `apply_ohos_modules.sh`+`ashmem/`——`kernel.mk:139` 依赖它），`REPO_HEADS.txt` 同步为 25 个仓；
  旧 sha `c88b85f9…` 作废。
- 生成脚本：`out/x86_64_virt/ohos-dbg/make_archive.sh`（可重跑）。内含：
  `00_MANIFEST.md`（总说明+逐项作用+回退）、`REPO_HEADS.txt`、`01_tree_patches/`（23 仓 git diff）、
  `02_tree_new_files/`（仓库新增文件 + 6 个整目录 + 内核 defconfig）、`03_out_patches/`（41）、
  `04_scripts/`（45 个 inject.sh + partdisk + tools + debug）、`05_reports/`（98 份 SUMMARY + AGENTS.md）、
  `06_artifacts/delivered/p2|p3/`（**从交付镜像直接抽取的权威产物**）+ `builds/` + `source/mesa/`。
- **归档不含 5.5 GB 镜像本身**，只记 sha：交付镜像 `f1040921…`（tag `pc_ptl-b2-rebuild-20261022-2350`）。
- 23 个树内补丁已用 `git apply --check -R` **全部反向校验通过**（与工作区逐字节一致）。
- 注意：`06_artifacts/delivered` 里 `libva.so.2`/`libvpl.so.2`/`libmfx-gen.so.1.2`/`libigdgmm.so.12`
  在镜像中是符号链接，debugfs 抽出为 0 字节（sha `e3b0c442…`），复制时需重建软链。

## 42. 【归档】纯源码 git 仓（可直接推 GitHub，2026-10-23）

- 路径：`out/x86_64_virt/ohos-dbg/GITHUB_OHOS_PTL/`（已 `git init -b main` + 单次提交，
  444 文件 / 4.3 MiB，最大单文件 204 KiB）。
- 生成脚本：`out/x86_64_virt/ohos-dbg/make_src_repo.sh`（可重跑，会重建仓库）。
- 结构：`patches/tree-ohos/`（23 仓 diff + `REPO_HEADS.txt`）、`patches/components/{sceneboard,aira,browser,media-driver}/`、
  `patches/ohos-diag/`、`patches/experiments/`、`sources/`（**按 OHOS 树原路径**放新增源码：
  `device/pc/ptl`、`vendor/pc/pc_ptl`、`applications/standard/{terminal,rime_ime}`、
  `base/startup/ohos_diag`、`third_party/aira`、内核 defconfig、`third_party/mesa3d-ohos/`）、
  `scripts/`（45 inject + partdisk + tools + debug + `apply-tree-patches.sh`）、`docs/`、`README.md`。
- **刻意排除**：HAP/`.so`/Intel 固件/`hdf_hcs.hcb`/镜像、`partdisk/sb_keys`（Secure Boot 私钥，**绝不可提交**）、
  `.hvigor`/`build`/`local.properties` 等构建垃圾。
- 应用：`bash scripts/apply-tree-patches.sh <OHOS 树根>`（跳过已打/冲突的仓）→ `cp -a sources/* <OHOS 树根>/`。
