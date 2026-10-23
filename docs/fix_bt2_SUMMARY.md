# fix_bt2 —— pc_ptl 蓝牙：链路其实**没断**，断的是「没人去开蓝牙」+ vendor HAL 日志落不了盘（2026-10-22）

> 产品 **`pc_ptl`**（Intel PTL / HONOR XWC-P，x86_64，2in1，OpenHarmony 7.0，linux-7.2）。
> 输入证据：`out/x86_64_virt/ohos-dbg/diagwork/d4/`（真机 diag，2026-10-22 09:27–09:51）。
> **交付镜像 `partdisk/media/ohos_part_pc_ptl.img` 本轮未改**（sha 仍 `92274c80…`/`e848e34c…` 那一版）；
> 全部验证在 `fix_bt2/scratch.img`（`cp --sparse` 副本）上做。
> 未写 `/tmp`、未动 `/dev/sda*`、构建与 QEMU 串行。

---

## 0. TL;DR

上一轮（`fix_bt_hci`）的结论是「vendor HAL 从未被 dlopen」。**本轮把整条链在 QEMU 里跑通后证明：
链是好的，断点在链的**最上游**——真机上从来没有人调用过 `enableBluetooth()`。**

三个结论（都有硬证据）：

| # | 结论 | 证据 |
|---|---|---|
| **F1** | **HDF 侧完全正常**，不需要补 `bluetooth_chip` 节点 | 真机 `blue_host`(pid 1744) 在跑，日志有 `HdfHciInterfaceDriverBind enter` / `HdfHciInterfaceDriverInit enter`（`drivers/peripheral/bluetooth/hci/hdi_service/hci_interface_driver.cpp:118/129`）。`/dev/hdf` 不存在与本链**无关**（HDF 的设备节点不是 `/dev/hdf`） |
| **F2** | **协议栈从未进入 HCI 初始化**，因为**控制器从未被 enable** | 真机整段开机日志里**没有** `HCI_Initialize start`（`stack/src/hci/hci.c:172`）。`HCI_Initialize` 只能由 `BTM_Enable()`（`stack/src/btm/btm.c:255`/`302`）触发，而 `BTM_Enable` 只能由 `ClassicAdapter::StartUp()`（`service/src/classic/classic_adapter.cpp:73`）触发 ⇒ **`enableBluetooth()` 从未被调用** |
| **F3** | **"BT hilog 域为空" 是假阴性** | `/sys_prod/zz_bt_hilog.log`（144 KB）里**有**完整的 C00101/C00102/C00105 日志。上一轮的 VERDICT 只看了 `hilog -x` 的环形缓冲（覆盖 09:32–09:51），而 BT 日志在 09:27–09:31 已被冲掉 |

另外发现并修掉**第二个真 bug**：

| # | 结论 | 证据 |
|---|---|---|
| **F4** | **vendor HAL 的日志落不了盘**：`blue_host`（uid 3021 `blue_host`）**没有权限**在 `/sys_prod`（root:root 0755）、`/data/local/tmp`（shell:shell 0770）、`/mnt/od`（未挂载）里建文件 | QEMU 实测 `/proc/790/root/sys_prod` = `root root 0755`、`/proc/790/root/data/local/tmp` = `shell shell 0770`；vendor HAL 自己的 probe 输出（`probe: sink /sys_prod/bt_vendor.log NOT present`）。⇒ 上一轮"改好 vendor HAL 就应该能出日志"的预期是错的 |

**一句话**：链没断，**开关没被按**；而且**就算按了，日志也会丢**。本轮交付的就是
「一键把链跑起来 + 把日志抓住」的工具与判据。

---

## 1. 完整的蓝牙开启链（file:line）

```
（用户/APP）  access.enableBluetooth()                     js/napi/src/access/napi_bluetooth_access.cpp:76
              → host->EnableBle()                          frameworks/inner/src/bluetooth_host.cpp:903
              → switchModule->ProcessEnableBluetoothEvent  frameworks/inner/src/bluetooth_switch_module.cpp:51
（SA 1130）   BluetoothHostServer::EnableBle()             bluetooth_service/.../server/src/bluetooth_host_server.cpp:946
              → AdapterManager::Enable()                   bluetooth_service/.../service/src/common/adapter_manager.cpp:349
              → MSG_USER_ENABLE_REQ → BleAdapter/ClassicAdapter::StartUp()
              → BTM_Enable(LE_CONTROLLER / BREDR)         bluetooth_service/.../service/src/classic/classic_adapter.cpp:73
（协议栈）     HCI_Initialize()                             bluetooth_service/.../stack/src/hci/hci.c:172
              → LoadHdiLib()                               bluetooth_service/.../stack/src/hci/hdi_wrapper.c:44
              → dlopen("libbluetooth_hdi_adapter.z.so")    ← 上一轮修的库名
              → HdiInit() → IHciInterface::Init()          bluetooth_service/.../hardware/src/bluetooth_hdi.cpp:25
（HDF）        blue_host / libbluetooth_hci_hdi_driver.z.so
              → HciInterfaceImpl::Init()                   drivers/peripheral/bluetooth/hci/hdi_service/hci_interface_impl.cpp:64
              → VendorInterface::Initialize()              drivers/peripheral/bluetooth/hci/hdi_service/implement/vendor_interface.cpp:107
              → dlopen("libbt_vendor.z.so")                vendor_interface.cpp:116   ← 我们自己的 vendor HAL
              → op(BT_OP_HCI_CHANNEL_OPEN) → hci0
```

**唯一的上游入口是 `enableBluetooth()`。** 整条链其余部分（`hdi_wrapper.c` 的库名、
`hdf_devhost.cfg` 的 `NET_RAW`、vendor HAL 的 H4 切帧）**只有在开关被按下去之后才会被执行到**。

### 1.1 真机为什么没按下去

真机 2026-10-22 的开机日志（`/sys_prod/zz_bt_hilog.log`，144 KB，C00101 域）里：

```
09:28:10.545  6881  6881 D C00101/bt_napi_access: (DefineAccessJSFunction:41)enter     ← SceneBoard(pid 6881) 打开蓝牙模块
09:28:11.809  6881  6881 I C00101/bt_napi_event_subscribe: (Register one stateChange callback in bluetooth.access module ...)
09:28:57.143 15762 15762 D C00101/bt_napi_access: (StateChangeInit:141)enter            ← 设置应用打开蓝牙页
09:30:54.121 15807 15807 D C00101/bt_napi_access: (GetState:118)enter
...
```

* 有 `GetState`（读状态）**58 次**，
* 有 `StateChangeInit`（注册状态回调），
* **没有一次** `bt_napi_access: (EnableBluetooth:77)enter`（`napi_bluetooth_access.cpp:77`，I 级）。

⇒ **设置应用和 SceneBoard 都只"看"蓝牙状态，从来没有"开"过蓝牙。**
（可能的原因：用户没点开关；点了但 UI 没派发；PC 形态下开关被 `isUnavailable` 置灰。
本轮把 app 侧日志也纳入采集（见 §4.2），下一次真机跑就能区分。）

---

## 2. 本轮改了什么

### 2.1 新增 `/system/bin/bt_enable`（C++，8872 B）

调用**和 ArkTS 完全相同**的框架入口：

```cpp
BluetoothHost &host = BluetoothHost::GetDefaultHost();   // OHOS::Bluetooth::BluetoothHost
int rc = host.EnableBle(std::string("bt_enable"), false);
```

* 链接镜像里现成的 `/system/lib64/platformsdk/libbtframework.z.so`（`NEEDED: libbtframework.z.so, libc++.so, libc.so`），
  **不新增任何运行时依赖**；ABI 用最小化的类声明复刻（mangled name 已用 `llvm-nm` 逐个核对）。
* 输出：`IsBluetoothSupported` / 开关前后状态 / `EnableBle` 返回码 / vendor HAL 日志是否存在。
* 退出码：0 = 请求被框架接受；1 = 被拒绝（并打印错误码）；2 = 工具自身跑不起来。

构建：`out/x86_64_virt/ohos-dbg/fix_bt2/tools/build_bt_enable.sh`
（`--target=x86_64-linux-ohos --sysroot=out/ptl/obj/third_party/musl`，**不要**再加 `-isystem <clang resource include>`，
否则 clang 的 C 版 `<stddef.h>` 会盖掉 libc++ 自带的那份，`<string>` 编译不过）。

### 2.2 新增 `/system/bin/bt_diag.sh`（一条命令定位断点）

```
1. 打印当前状态
2. dump 一次 hilog 环形缓冲（PRE）
3. 调用 bt_enable 触发开关
4. 再 dump 一次（POST）→ /sys_prod/zz_bt_trigger.log
5. 按 L0..L5 逐环统计，并指出**第一处断链**
```

| 环节 | 判据（grep） |
|---|---|
| L0 客户端 → SA 1130 | `EnableBle\|enableBluetooth\|BluetoothHostServer.*Enter\|AdapterManager::Enable` |
| L1 服务 → 适配器 | `ClassicAdapter.*Enable\|BleAdapter.*Enable\|BTM_Enable\|MSG_USER_ENABLE_REQ` |
| L2 协议栈 → HDI 适配层 | `HCI_Initialize\|LoadHdiLib\|libbluetooth_hdi_adapter` |
| L3 协议栈 → HDF 代理 | `HciInterfaceImpl\|hdiInit` |
| L4 HDF host → vendor HAL | `VendorInterface dlopen` |
| L5 vendor HAL 在跑 | `bt_vendor`（hilog tag，域 0xD000105） |

### 2.3 修 vendor HAL 的日志落点（`vendor/pc/pc_ptl/bluetooth/src/bt_vendor_linux.c`）

**问题**：vendor HAL 只往文件里写（`/sys_prod`、`/mnt/od`、`/data/local/tmp`）+ stderr。
但它是被 **`blue_host`（uid `blue_host` = 3021）** dlopen 的，这些路径它**一个都写不了**；
stderr 也不会进 hilog（init 把服务的 stdout/stderr 丢掉了）。
⇒ **HAL 明明跑了，日志一条都没有。**

**修法**：加一个 **hilog** 落点（懒加载 `libhilog.so`，`HiLogPrint(LOG_CORE, LOG_INFO, 0xD000105, "bt_vendor", ...)`），
文件落点保留（万一哪天由特权进程加载）。新增 `/data/vendor/bluetooth/bt_vendor.log` 作为第 4 个落点。

> 0xD000105 = Bluetooth HDF host 域（`vendor_interface.cpp:43` 的 `LOG_DOMAIN`），
> 所以这些行会自动被 `zz_hilog_persist` 的域采集器收走。

### 2.4 采集增强

| 文件 | 改动 |
|---|---|
| `base/startup/ohos_diag/zz_hilog_persist.sh` | 新增**内容过滤器**采集器 `hilog -e "<regex>"` → `/sys_prod/zz_bt_all.log`（**不限域**，因此能抓到设置应用 / SceneBoard / blue_host 的行）；把 persist 任务报告也写到 `/sys_prod/zz_hilog_persist.txt` |
| `base/startup/ohos_diag/ohos-diag` | 蓝牙段：先跑 `bt_diag.sh`（带 hilog 窗口）、收集 4 个流式日志文件；判据 `bt/hilog-domain-has-lines` **改为先看流式采集器**（原来只看环形缓冲 → 假阴性）；新增 7 条链路判据 `bt/bt-enable-tool`、`bt/chain-enable-request`、`bt/chain-adapter-enabled`、`bt/chain-hci-init`、`bt/chain-hdi-init`、`bt/chain-vendor-hal-dlopen`、`bt/chain-vendor-hal-alive`；`bt/vendor-hal-log` 改为看 hilog tag 而不是文件 |

---

## 3. QEMU 端到端验证（**链是通的**）

QEMU（x86_64_virt 无 BT 硬件，`/sys/class/bluetooth` 为空）里跑 `bt_enable`：

```
bt_enable: IsBluetoothSupported=1
bt_enable: state before = STATE_OFF
bt_enable: calling BluetoothHost::EnableBle("bt_enable", false) ...
bt_enable: EnableBle returned 0 (BT_NO_ERROR)          ← 请求被框架接受
bt_enable: RESULT=REQUEST_ACCEPTED
```

对应的 hilog（`evidence/qemu_bt_chain.txt`，368 行，C00101/C00102/C00105/C02510）：

```
C00101/bt_fwk_host: (EnableBle:905)enter                                   ← L0 客户端→框架
C00102/Bluetooth: [bluetooth_host_server.cpp(EnableBle:948)]Enter!          ← L0 请求到达 SA 1130
C00102/Bluetooth: AdapterManager::Enable ... start transport is 1          ← L1 服务受理
C00102/Bluetooth: [BleAdapter] EnableTask / BTM_Enable start                ← L1 → 协议栈
C00102/Bluetooth: HCI_Initialize start                                      ← L2 协议栈进入 HCI
C00105/HDF_LOG_TAG: HciInterfaceImpl Init                                   ← L3 HDF 代理
C00105/HDF_LOG_TAG: VendorInterface Initialize
C00105/HDF_LOG_TAG: VendorInterface dlopen                                  ← L4 vendor HAL 被 dlopen ✔
C00105/bt_vendor: init: cb=0x... bdaddr=00:11:22:33:44:55                 ← L5 vendor HAL 在跑 ✔
C00105/bt_vendor: probe: pid=790 uid=3021
C00105/bt_vendor: op BT_OP_POWER_ON (controller is owned by the kernel)
C00105/HDF_LOG_TAG: VendorInterface BT_OP_HCI_CHANNEL_OPEN begin
C00105/bt_vendor: no usable hciN found under /sys/class/bluetooth
C00105/bt_vendor: BT_OP_HCI_CHANNEL_OPEN: could not obtain raw HCI sockets  ← ★QEMU 无 BT 硬件，止步于此
C02510/hci_interface_proxy: Init_ failed, error code is -1
C00102/Bluetooth: hdiInit failed: 2
C00102/Bluetooth: [BleAdapter] EnableTask:BTM enable failed!
```

`bt_diag.sh` 的判读：

```
L0 client -> SA 1130 (EnableBle / enableBluetooth) : 6 hits
L1 service -> adapter (BTM_Enable)                 : 10 hits
L2 stack -> HDI adapter (HCI_Initialize)            : 4 hits
L3 stack -> HDF proxy (HdiInit)                     : 8 hits
L4 HDF host -> vendor HAL (VendorInterface dlopen) : 2 hits
L5 vendor HAL log lines                             : 40 hits
→ the whole chain is intact
```

**⇒ 结论（在真机上也应当成立）**：协议栈 → HDF → vendor HAL 的这条链**完全正常**，
上一轮修的库名、`NET_RAW`、H4 切帧**都生效了**（vendor HAL 真的被 dlopen 并执行到了
`BT_OP_HCI_CHANNEL_OPEN`）。真机上唯一缺的就是"有人去按那个开关"。

### 3.1 诊断器本身的 VERDICT（QEMU，`evidence/qemu_VERDICT.txt`）

```
[蓝牙]
hci0 蓝牙设备          | /sys/class/bluetooth 可见   | ...there is no hci0   | FAIL   ← QEMU 无 BT 硬件
vendor HAL 日志        | bt_vendor.log 存在          | the vendor HAL logged (hilog tag bt_vendor) | PASS
协议栈已加载            | libbtstack 已映射           | matched x5 (libbtstack)               | PASS
vendor HAL 已加载       | libbt_vendor 已映射         | matched x4 (libbt_vendor)             | PASS
bluetooth_service      | 运行中                      | pid 672                              | PASS
BT 栈日志内容          | 非空                        | 8243 lines in the BT collectors (streamed), 360 in the ring buffer | PASS
蓝牙开关触发器          | /system/bin/bt_enable 已安装 | /system/bin/bt_enable is installed  | PASS
链路 L0 请求到达框架     | 有                          | the enable request reached the framework (6)  | PASS
链路 L1 服务使能适配器   | 有                          | the service enabled the adapter (10)         | PASS
链路 L2 协议栈 HCI_Initialize | 有                   | the stack entered HCI_Initialize (4)         | PASS
链路 L3 HDF 代理初始化   | 有                          | the HDF proxy was initialised (8)            | PASS
链路 L4 vendor HAL 被 dlopen | 有                   | blue_host dlopen()ed the vendor HAL (2)      | PASS
链路 L5 vendor HAL 有日志 | 有                        | the vendor HAL logged (40 lines)             | PASS
开机 dmesg 含 BT probe  | 有                          | matched x16 (bluetooth|btintel|hci)          | PASS
```

### 3.2 验证过程中顺手修掉的**诊断器自己的**两个 bug

1. **`bt/libbt-vendor-mapped` 查错了进程**：vendor HAL 是被 **HDF host（`blue_host`）** dlopen 的，
   不是被 `bluetooth_service` 加载的 ⇒ 原来的判据**永远**是 FAIL。已改成查 `blue_host` 的 maps。
2. **新加的判据块让整个 diag 脚本中途夭折**（`${$_v}` 这种间接展开在设备的 **mksh** 上是
   "Bad substitution"，脚本直接退出 ⇒ 后面 audio/wifi/media 段全没跑）。
   已改成显式的 `case` 归一化。**教训（沿用 §34.2 的结论）：诊断脚本必须在设备 shell 上跑一遍。**


---

## 4. 真机判据（**下一轮照这个跑**）

### 4.1 最短路径（3 条命令）

```sh
# 1) 注入本轮的东西（先在副本上试）
cd /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/fix_bt2
cp --sparse=always ../partdisk/media/ohos_part_pc_ptl.img scratch.img
bash inject.sh scratch.img            # 交付镜像需要 --force

# 2) 真机上（hdc 或串口）
hdc shell "/system/bin/bt_diag.sh 8"   # 一条命令给出 L0..L5 的断点

# 3) 如果 L0 = 0，再看 app 侧到底有没有调 enableBluetooth
hdc shell "hilog -x | grep -a 'bt_napi_access'"
hdc shell "cat /sys_prod/zz_bt_all.log | grep -a 'bluetooth' | tail -100"
```

### 4.2 逐条判据

| 判据 | 期望 | 不满足说明 |
|---|---|---|
| `bt_enable` 返回码 | **0**（REQUEST_ACCEPTED） | 返回 801/899 ⇒ 框架/SA 层拒绝（看 `bt_napi_access` / `bt_fwk_switch_module`） |
| `/sys_prod/zz_bt_trigger.log` 里 `bt/chain-enable-request` | 有 | L0 断 ⇒ **开关没被按**（UI/APP 侧问题） |
| `bt/chain-adapter-enabled` | 有 | L1 断 ⇒ 服务没让适配器起来 |
| `bt/chain-hci-init` | 有 | L2 断 ⇒ 协议栈没进 HCI（回头查 `LoadHdiLib`） |
| `bt/chain-hdi-init` | 有 | L3 断 ⇒ HDF 代理失败（`hdiInit failed: N`） |
| `bt/chain-vendor-hal-dlopen` | 有 | L4 断 ⇒ `dlopen("libbt_vendor.z.so")` 失败（看 `hdf_devhost` 的 `blue_host` 段） |
| `bt/chain-vendor-hal-alive` | 有 | L5 断 ⇒ vendor HAL 起来了但没日志（hilog 落点问题） |
| hilog 里 `C00105/bt_vendor: BT_OP_HCI_CHANNEL_OPEN ok: returning 1 channel` | 有 | **真机成功的标志**（QEMU 里必然没有） |
| hilog 里 `C00105/bt_vendor: HCIDEVUP hci0 ok` | 有 | hci0 没被拉起来（rfkill / `NET_ADMIN`） |
| `/sys/class/bluetooth/hci0` | 存在 | 内核侧（真机已有） |
| `hidumper -s 1130 -a '-br'` | `Bt enable state: enabled` | ⚠️ `-s` 的参数是 **SA id**，不是名字；`-s Bluetooth` 一定是 "request error" |
| `bt_vendor.log` 文件 | **仍然不会有** | 这是**预期的**：blue_host 没权限建文件。看 hilog tag `bt_vendor` |

### 4.3 日志落点实测（真机 d4 + QEMU）

| 落点 | 谁写的 | 实测 | 结论 |
|---|---|---|---|
| hilog **域** `0xD000100/101/102/105` | 蓝牙栈 / HDF host | 真机 144 KB、QEMU 943 行 | **域过滤是有效的** ✔（上轮"域为空"是**看错了地方**：只看了 `hilog -x` 的环形缓冲） |
| hilog **内容**（不限域） | 任意进程 | 本轮新增 `hilog -e` → `/sys_prod/zz_bt_all.log`（QEMU 709→772 行） | 这是抓"设置应用/SceneBoard 有没有调 enableBluetooth"的唯一办法 |
| `/data/bluetooth/log/` | `bluetooth_service` 的 init job 建的目录 | 真机：**空** | 协议栈**不写文件**，只写 hilog |
| `/data/log/hilog/` | hilogd 的持久化任务 | 真机：**空**；`hilog -w query` → "No running persistent task" | `hilog -w start` 的持久任务**没起来**（本轮已让它把**失败原因**记进 `/sys_prod/zz_hilog_persist.txt`）。**流式采集器不依赖它**，所以不影响取证 |
| `/data/local/tmp/bt_vendor.log` 等 | 我们的 vendor HAL | 真机**没有**、QEMU **也没有** | `blue_host`（uid 3021）**没有权限**在这些目录建文件 ⇒ **改成 hilog 落点**（本轮修） |
| `/sys_prod/zz_bt_trigger.log` | 本轮新增的 `bt_diag.sh` | QEMU：840 KB | **开关尝试的精确窗口**（环形缓冲不清空，避免破坏其它证据） |

**⇒ 结论**：OHOS 蓝牙栈**只有 hilog 一个日志落点**；域过滤有效；文件落点（协议栈的、vendor HAL 的、
hilog 持久任务的）**全是空的或不可写**。所以取证必须靠
（a）**流式采集器**（域 + 内容）和（b）**先清空/再 dump 的窗口**。

### 4.4 顺带修好的两个"诊断自身"的毛病

1. `hidumper -s 1130` 才是蓝牙 SA（1130），`-s Bluetooth` 永远 "request error"；
2. `bt/vendor-hal-log` 判据改成看 hilog tag（文件落点对 blue_host 不可写）。

---

## 5. 怎么用（注入 & 回退）

### 注入

```sh
cd /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/fix_bt2
cp --sparse=always ../partdisk/media/ohos_part_pc_ptl.img scratch.img
bash inject.sh scratch.img
```

`inject.sh` 会：
1. `dd` 出 p2(/system) / p3(/vendor)；
2. 写入
   * p2 `/system/bin/bt_enable`、`/system/bin/bt_diag.sh`、
     `/system/bin/ohos-diag`、`/system/bin/zz_hilog_persist.sh`；
   * p3 `/lib64/libbt_vendor.z.so`（带 hilog 落点的新版本）；
3. 检查链上其它零件是否在位并打印 sha256
   （`libbtstack.z.so`、`libbluetooth_hdi_adapter.z.so`、`blue_host` 的 `NET_RAW`）；
4. `e2fsck -f -y` 两个分区 → `dd` 回写 → 逐文件 `cmp` 校验；
5. **已经是修复版就一步不动镜像**（字节级幂等）。

交付镜像默认**拒绝写入**（要 `--force`）。

### 回退

```sh
# 源码
git -C /home/katax/Public/OHOS checkout -- vendor/pc/pc_ptl/bluetooth/src/bt_vendor_linux.c
# vendor/pc/pc_ptl 不在 git 管理内的话：把 hilog 那段删掉即可
# base/startup/ohos_diag 不是 manifest 仓：把 ohos-diag / zz_hilog_persist.sh 改回去
#
# 镜像：直接用交付镜像 partdisk/media/ohos_part_pc_ptl.img
```

---

## 6. 遗留 / 如实说明

1. **真机尚未验证**。QEMU 能证明"链是通的"，但**证明不了真机上开关为什么没被按**。
   下一轮真机跑 `bt_diag.sh` + `zz_bt_all.log` 才能定位到 UI/APP 那一侧。
2. **QEMU 里 BLE 也开不起来**（`hci0` 不存在 → `BT_OP_HCI_CHANNEL_OPEN` 失败 →
   `hdiInit failed: 2` → `BTM_Enable` 失败 → 适配器回到 OFF）。
   这是**预期的**，QEMU 没有 BT 控制器；但它也说明：**vendor HAL 拿不到 hci0 时，
   整条链会干净地失败并回滚，不会把 bluetooth_service 打死**
   （`hci.c:81` 那个 5 秒 SIGTERM 只在 `hdiInit` 返回 SUCCESS 但回调不来时才会触发）。
3. **`hdiInit failed: 2`** = `INITIALIZATION_ERROR`（`bluetooth_hdi.cpp:33/45/53`），
   即 HDF 侧 `Init()` 返回了失败；真机上如果 L3 断，看 `hdi_interface_proxy: Init_ failed, error code is -1`。
4. **`ConvertBTStateIDToBluetoothState` 的 `switch` 少一个 `break`**
   （`bluetooth_host_server.cpp:860-868`：`STATE_TURN_OFF` 分支 fall through 到 `default`），
   所以每次读状态都会打一条 `Invalid bt state`。这是**上游的小 bug**，不影响功能，本轮没改
   （改了要重编 `libbluetooth_server.z.so`，收益很小）。→ 见到这条日志不用慌。
5. **vendor HAL 与内核 core 双主**：内核 `btintel_pcie` 已经把控制器拉起来了，我们再通过
   RAW socket 下 HCI 命令，内核 core 也会收到。BlueZ 的 raw 用法同构，但**真机未验证**。
6. **权限**：真机上 `bt_enable` 由 root shell 运行，没有 `ohos.permission.ACCESS_BLUETOOTH`，
   所以状态变化**回调**会被服务端拒掉（日志 `permission(ohos.permission.ACCESS_BLUETOOTH) result(-1)`），
   但**开关请求本身是通的**（`EnableBle returned 0`）。想看状态变化请用 `hidumper -s 1130 -a '-br'`。
7. `zz_hilog_persist` 的 `hilog -w start` 持久任务**仍然起不来**（"No running persistent task"），
   但流式采集器（域采集 + 内容采集）工作正常，本轮不依赖持久任务。

---

## 7. 产物清单

```
out/x86_64_virt/ohos-dbg/fix_bt2/
├── SUMMARY.md                     本报告
├── inject.sh                      幂等注入脚本（p2 + p3 + 校验）
├── qemu_boot.sh                   pc_ptl 磁盘镜像的 QEMU 启动脚本（QEMU 用）
├── scratch.img                    验证用镜像副本（cp --sparse 自交付镜像）
├── tools/
│   ├── bt_enable.cpp              开关触发器（链接 libbtframework.z.so）
│   ├── build_bt_enable.sh         它的构建脚本
│   ├── bt_diag.sh                 一条命令的链路诊断（L0..L5）
│   ├── ser_collect.py             串口采集（QEMU 用）
│   └── ser_cmd.py                 串口发命令（QEMU 用）
├── work/
│   ├── bt_enable                  8872 B
│   ├── libbt_vendor.z.so          14912 B（带 hilog 落点的 vendor HAL）
│   ├── e2fsck_p2.log / e2fsck_p3.log
│   └── inject_p2.img / inject_p3.img
└── evidence/
    └── qemu_bt_chain.txt          QEMU 里整条链的 hilog（368 行）
    └── qemu_VERDICT.txt           QEMU 里 ohos-diag 的 VERDICT（蓝牙段 L0..L5 全 PASS）
```

### 源码改动清单

| 文件 | 改动 |
|---|---|
| `vendor/pc/pc_ptl/bluetooth/src/bt_vendor_linux.c` | vendor HAL 增加 hilog 落点（`HiLogPrint`，域 0xD000105，tag `bt_vendor`）+ 第 4 个文件落点 + `#include <dlfcn.h>` |
| `base/startup/ohos_diag/zz_hilog_persist.sh` | 新增 `hilog -e` 内容采集器 → `/sys_prod/zz_bt_all.log`；persist 报告落到 `/sys_prod`；记录 persist 任务的**失败原因** |
| `base/startup/ohos_diag/ohos-diag` | 蓝牙段跑 `bt_diag.sh`、收集流式日志、修 `bt/hilog-domain-has-lines` 假阴性、新增 7 条链路判据、修 `bt/vendor-hal-log` 与 `bt/libbt-vendor-mapped` 判据 |
| （新增，非仓内）`fix_bt2/tools/bt_enable.cpp`、`bt_diag.sh` | 诊断工具 |

### 产物 sha256

| 文件 | sha256 | 大小 |
|---|---|---|
| `work/bt_enable` | `e8dd80a50b550672daba01e23ac6cf6d1f8dd621a9e3761fe5c9b651c2452d0d` | 8872 B |
| `work/libbt_vendor.z.so` | `c229685eb1dff6fbdc918e016c40de33ecfa199c5594955374f2366b82318b5d` | 14912 B |
| `tools/bt_diag.sh` | 见 `inject.sh` 输出 | 6703 B |
| `base/startup/ohos_diag/ohos-diag` | `e80385c16552542c…` | 120361 B |
| `base/startup/ohos_diag/zz_hilog_persist.sh` | `ed0916b6d6a24c30…` | 6980 B |
| `scratch.img`（验证用） | `37badcc7cfc93c5eb5d9ba240ba6c6a0bd1280fd19309cf151f2c5a0dd694330` | 21 GiB（稀疏 2.4 GB） |
| **交付镜像（未改）** | `575eefcc45fe0146c3a57f4fb9d8cb4bf8e42f76a75fff7fcb8c4c6082e1a129` | 5.2 GB |
