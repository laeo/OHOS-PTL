# fix_bt_hci —— pc_ptl 蓝牙打不开：真正的 vendor HAL + 加载链修复（2026-10-20）

> 产品 **`pc_ptl`**（Intel PTL / HONOR XWC-P，x86_64，2in1，OpenHarmony 7.0，linux-7.2）。
> 输入证据：`out/x86_64_virt/ohos-dbg/diagwork/d2/B_bluetooth.txt`（真机 diag，2026-10-20 20:07）。
> 本轮**未改**交付镜像 `partdisk/media/ohos_part_pc_ptl.img`（仍 `92274c80…`），
> 全部验证在 `fix_bt_hci/scratch.img`（`cp --sparse` 副本）上做。
> 未写 `/tmp`、未动 `/dev/sda*`、构建与 QEMU 串行。

---

## 0. TL;DR

真机 diag 现象是「`hci0` 正常、`libbt_vendor.z.so` 在 `/vendor/lib64` 里、但**从头到尾没被 dlopen 过**」。
本轮定位到**三个互相叠加的断点**，前两个是致命的，第三个是"能连上但扫不到设备"的原因：

| # | 断点 | 位置 | 后果 | 状态 |
|---|---|---|---|---|
| **A** | x86_64 上 BT 协议栈去 dlopen 一个**根本不存在的库名** `libbluetooth_hdi_adapter.so`（真名是 `libbluetooth_hdi_adapter.z.so`） | `foundation/communication/bluetooth_service/services/bluetooth/stack/src/hci/hdi_wrapper.c:23-25`（改前） | `HCI_Initialize()` → `LoadHdiLib()` 返回 NULL → 协议栈在**还没碰到 HDI 之前**就退出 ⇒ **vendor HAL 永远没机会被 dlopen** ⇒ 蓝牙开关打不开、`bt_vendor.log` 不存在 | **已修**（改源码 + 重编 `libbtstack.z.so`） |
| **B** | 交付镜像里的 `/vendor/etc/init/hdf_devhost.cfg` 是**陈旧**的，`blue_host` 只有 `NET_ADMIN`、**没有 `NET_RAW`** | 镜像内 p3 vs `vendor/ohemu/virt/hdf_config/uhdf/device_info.hcs:48` | 内核 `hci_sock_sendmsg()` 对 RAW 通道的**每一条 HCI 命令**都要 `CAP_NET_RAW`（否则只放行 `hci_sec_filter` 里极小的白名单）；`SO_HCI_FILTER` 也会被内核收窄成"只收事件"⇒ 扫不到设备 | **已修**（inject.sh 用 `hc-gen` 重新生成 cfg 注入） |
| **C** | 上一版 vendor HAL（`bt_vendor_linux.c`）有 3 个**协议级**错误 | `vendor/pc/pc_ptl/bluetooth/src/bt_vendor_linux.c` | ① `HCIDEVUP` ioctl 号用了旧的 `_IO(0,3)`（本内核是 `_IOW('H',201,int)`）⇒ `-ENOTTY`；② `HCIDEVUP` 失败即致命（而 `btintel_pcie` 开机已把控制器拉起，返回 `-EALREADY`）⇒ 整条通道开不起来；③ **RAW 通道不投递 H4 类型字节**，旧实现原样透传 ⇒ HDI 把事件码当成包类型，整条流全乱 | **已修**（重写传输层） |

**一句话**：蓝牙打不开的**直接原因不在 vendor HAL**，而在 BT 协议栈在 x86_64 上加载 HDI 适配层时用错了库名；
vendor HAL 本身也有 3 个独立的协议错误会让人"即使前面都修好也还是扫不到设备"。三者都修了。

---

## 1. 接口约定（vendor HAL ↔ HDI）

### 1.1 HDI 侧怎么调我们

| 位置 | 内容 |
|---|---|
| `drivers/peripheral/bluetooth/hci/hdi_service/implement/bt_hal_constant.h:26` | `BT_VENDOR_NAME = "libbt_vendor.z.so"`（**裸名**，靠 musl 命名空间 ini 的搜索路径找 `/vendor/lib64`） |
| `bt_hal_constant.h:27` | `BT_VENDOR_INTERFACE_SYMBOL_NAME = "BLUETOOTH_VENDOR_LIB_INTERFACE"` |
| `drivers/peripheral/bluetooth/hci/hdi_service/implement/vendor_interface.cpp:116` | `vendorHandle_ = dlopen(BT_VENDOR_NAME, RTLD_NOW);` |
| `vendor_interface.cpp:122-123` | `dlsym(vendorHandle_, "BLUETOOTH_VENDOR_LIB_INTERFACE")` |
| `vendor_interface.cpp:137` | `vendorInterface_->init(&vendorCallbacks_, address.data())` |
| `vendor_interface.cpp:143` | `op(BT_OP_POWER_ON, nullptr)` |
| `vendor_interface.cpp:77` | `op(BT_OP_HCI_CHANNEL_OPEN, channel)` → **必须返回 fd 个数**（1..HCI_MAX_CHANNEL） |
| `vendor_interface.cpp:84` | `channelCount == 1` ⇒ 走**单 fd 的 H4 协议**（`h4_protocol.cpp`） |
| `vendor_interface.cpp:166` | `op(BT_OP_INIT, nullptr)` → **必须回调 `initCb(SUCCESS)`** |
| `vendor_interface.cpp:238 / :243` | `op(BT_OP_GET_LPM_TIMER,&ms)` / `op(BT_OP_LPM_ENABLE,nullptr)` |
| `vendor_interface.cpp:172-200` | `CleanUp()`：LPM_DISABLE → HCI_CHANNEL_CLOSE → POWER_OFF → `close()` → `dlclose()` |
| `drivers/peripheral/bluetooth/hci/hdi_service/implement/ohos_bt_vendor_lib.h` | ABI：`BtVendorInterfaceT{size, init, op, close}`、`BtVendorCallbacksT{size, initCb, alloc, dealloc, xmitCb}`、`BtOpcodeT` 枚举 |

### 1.2 H4 帧格式（HDI 侧 `hci_protocol.cpp:33-40` 的 `header_` 表）

| 类型 | 头 | len 偏移 | len 长度 | 整帧 |
|---|---|---|---|---|
| CMD(0x01) | 3（opcode[2]+plen[1]） | 2 | 1 | 1+3+plen |
| ACL(0x02) | 4（handle_flags[2]+dlen[2]） | 2 | 2 | 1+4+dlen |
| SCO(0x03) | 3 | 2 | 1 | 1+3+dlen |
| EVT(0x04) | 2（evt[1]+plen[1]） | 1 | 1 | 1+2+plen |
| ISO(0x05) | 4 | 2 | 2 | 1+4+dlen |

**HDI 写数据时把「类型字节」和「负载」分成两次 `write()`**（`h4_protocol.cpp:68-79`），
所以 vendor HAL 从 socketpair 读到的是**字节流**，必须自己重新切帧。

---

## 2. 加载链（谁 dlopen 谁、什么时候）

```
bluetooth_service (SA 1130)
  └─ btstack: HCI_Initialize()                       stack/src/hci/hci.c:172
       └─ LoadHdiLib()                               stack/src/hci/hdi_wrapper.c:43   ← ★断点 A
            └─ dlopen("libbluetooth_hdi_adapter.z.so")   ★ 改前是 ".so"（不存在）
                 └─ bluetooth_hdi_adapter: HdiInit()  hardware/src/bluetooth_hdi.cpp:25
                      └─ IHciInterface::Get()  → HDF proxy
                           └─ hdf_devmgr (SA 5100) → devhost "blue_host" (uid=blue_host, caps=[NET_ADMIN,NET_RAW])
                                └─ libbluetooth_hci_hdi_driver.z.so (HDF 驱动, hcs 里注册)
                                     └─ libhci_interface_service_1.0.z.so (HDI 实现)
                                          └─ HciInterfaceImpl::Init()  hci_interface_impl.cpp:64
                                               └─ VendorInterface::Initialize()  vendor_interface.cpp:107
                                                    └─ dlopen("libbt_vendor.z.so")  ★★ 我们在这里
                                                         └─ op(BT_OP_HCI_CHANNEL_OPEN) → 返回 1 个 fd
```

要点：
- `blue_host` 是 **init 服务**（`hdf_devhost.cfg`），**能力由 init 的 `caps` 决定**
  （`base/startup/init/services/init/init_common_service.c:245-270` 的 `SetCapabilities()`；
  能力名表 `base/startup/init/services/init/init_capability.c:48-49`，`NET_ADMIN`/`NET_RAW`）。
  HDF hcs 里的 `caps` 字段**只是装饰**——`drivers/hdf_core` 全树没有 `capset()`，
  真正生效的是 `hdf_devhost.cfg`。
- HDF 侧：设备 `preload` 默认 **0 = `DEVICE_PRELOAD_ENABLE`**（`drivers/hdf_core/interfaces/inner_api/host/shared/hdf_device_desc.h:81`），
  所以 `blue_host` **开机就被拉起**、驱动开机就 bind、`hci_interface_service` 开机就发布 ⇒
  **不需要**改 hcs 的 preload，也**不需要**"按需加载"改造。diag 里 `blue_host`(pid 1185) 在跑正是这个原因。
- HDF 找 HDI 实现库：`drivers/hdf_core/adapter/uhdf2/hdi/src/hdi_support.cpp:164`（`dlopen` 裸名）
  → 搜索路径靠 musl 的**命名空间 ini**：`/etc/ld-musl-namespace-x86_64.ini` 的
  `namespace.default.lib.paths` 里**含 `/vendor/lib64`**（已在 QEMU 里实测，见 §5.3）。
  ⇒ `dlopen("libbt_vendor.z.so")` 能找到 `/vendor/lib64/libbt_vendor.z.so`，**不需要**额外改配置。

**结论：host 栈并没有"强依赖 HDF 到无法绕开"**——HDF 链路是通的，坏的只是
(a) 协议栈自己的库名、(b) blue_host 的能力、(c) vendor HAL 自己的协议实现。

---

## 3. 实现要点（`vendor/pc/pc_ptl/bluetooth/src/bt_vendor_linux.c`，已重写）

### 3.1 传输方案

内核已经把控制器带起来了（`btintel_pcie` → `hci0` 已经是标准 HCI 设备），
所以 vendor HAL **直接用 Linux HCI socket（AF_BLUETOOTH / BTPROTO_HCI / HCI_CHANNEL_RAW）**，
不碰任何私有 ioctl：

```
OHOS H4Protocol  <--socketpair-->  vendor HAL  <--5 个 raw socket-->  hci0 (内核 btintel_pcie)
```

返回 **1** 个 channel（`HCI_CMD`），HDI 因此走单 fd 的 H4 路径（`vendor_interface.cpp:84`）。

### 3.2 关键内核 ABI（全部对着 `kernel/linux/linux-7.2` 核过）

| 事实 | 位置 | 对实现的影响 |
|---|---|---|
| `struct sockaddr_hci` = `{sa_family_t hci_family; u16 hci_dev; u16 hci_channel;}` | `include/net/bluetooth/hci_sock.h` | 旧代码写成 `hci_bdaddr`（本分支上位置恰好等价，但也只传了 4 字节）；新代码传完整 6 字节，`hci_dev`=设备号，`hci_channel`=0(RAW) |
| `HCIDEVUP` = **`_IOW('H',201,int)`** | `include/net/bluetooth/hci_sock.h:65` | 旧代码用 `_IO(0,3)` ⇒ `-ENOTTY`。**已修** |
| `HCIDEVUP` 要 `CAP_NET_ADMIN`；控制器已 up 时返回 **`-EALREADY`** | `net/bluetooth/hci_sock.c:1125-1128`；`net/bluetooth/hci_sync.c:5293+` (`test_bit(HCI_UP)` → `-EALREADY`) | 旧代码把失败当致命 ⇒ 直接放弃。**已修**（EALREADY 视为成功） |
| **RAW 通道投递的是"裸负载"，没有 H4 类型字节** | `net/bluetooth/hci_sock.c:201-230` `hci_send_to_sock()`：类型只存在 `hci_skb_pkt_type()` 元数据里 | 旧代码原样透传 ⇒ HDI 把事件码(0x0e 等)当成包类型，整条流错乱。**已修** |
| 本内核**没有 `SCM_CBFCPT`** | `grep -rn SCM_CBFCPT include/ net/bluetooth/` 无结果 | ⇒ 无法用 cmsg 拿类型。**改用 5 个 raw socket，每个用 `SO_HCI_FILTER` 的 `type_mask` 只收一种包**，从"哪个 socket 收到"反推类型 |
| 发的包会被内核**回显给其它 raw socket**（"Don't send frame to the socket it came from"） | `net/bluetooth/hci_sock.c:222` | 必须**按类型把帧发到对应类型的 socket**，否则会把自己的 TX 当 RX 收进来。**已修** |
| RAW 通道发命令要 `CAP_NET_RAW`（否则只放行 `hci_sec_filter.ocf_mask` 白名单） | `net/bluetooth/hci_sock.c:1881-1890`、`:1909` | ⇒ blue_host 必须有 `NET_RAW`（断点 B） |
| `SO_HCI_FILTER` 在**没有 `CAP_NET_RAW`** 时会被内核与 `hci_sec_filter` 求交（`type_mask` 变成 `0x10`，只剩事件；事件掩码也只剩一小撮） | `net/bluetooth/hci_sock.c:1988-1992` | ⇒ 没有 `NET_RAW` 就**收不到 LE Meta / 扫描结果**。同样靠断点 B 解决 |
| `hci_sock_sendmsg()` 期望数据的**第 1 字节就是包类型**（`hci_skb_pkt_type(skb)=skb->data[0]; skb_pull(skb,1)`） | `net/bluetooth/hci_sock.c:1854-1857` | ⇒ HDI→内核方向**原样带类型字节整帧 `send()`** 即可 |

### 3.3 实现结构

- **5 个 raw socket**：`cmd/acl/sco/evt/iso`，各带 `SO_HCI_FILTER{type_mask=1<<HCI_*_PKT, event_mask=全1, opcode=0}`。
- **kernel→HDI**：poll 5 个 socket → 读裸负载 → **补上该 socket 对应的 H4 类型字节** → 写 socketpair。
- **HDI→kernel**：从 socketpair 读字节流 → `H4ScanFrames()` 重新切帧 → **按类型**发到对应 raw socket（整帧一次 `send()`）。
- `H4ScanFrames()` 抽成独立函数 ⇒ 可在宿主机做单元测试（§5.1）。
- `BT_OP_GET_LPM_TIMER` 返回 **0**（不注入自己的 LPM 空闲超时，否则扫描会在事件间隙停掉）。
- `BT_OP_INIT` 里回调 `initCb(BTC_OP_RESULT_SUCCESS)`。
- **日志**同时写 `stderr`（被 `blue_host` 收进 hilog）+ `/sys_prod/bt_vendor.log` + `/mnt/od/bt_vendor.log` + `/data/local/tmp/bt_vendor.log`
  （`/sys_prod` 是常驻 rw 分区，diag 采集器一定能拿到）。
- 开机主动 **解 rfkill soft block**（OHOS 没有 rfkill agent，soft-block 会让 `HCIDEVUP` 返回 `-ERFKILL`）。

### 3.4 断点 A 的修法（`hdi_wrapper.c`）

```c
static const char *const HDI_LIBS[] = {
    "libbluetooth_hdi_adapter.z.so",   /* OHOS 5.0+ 组件化构建的规范名 */
    "libbluetooth_hdi_adapter.so",     /* 老名字，兜底 */
};
```
先试 `.z.so`，失败再试老的；两个都失败才报错。
（`.z` 后缀来自 `build/toolchain/toolchain.gni:73` `shlib_extension = ".z.so"`，**所有架构**都带，包括 x86_64。）

---

## 4. 改了什么

| 文件 | 改动 | 状态 |
|---|---|---|
| `foundation/communication/bluetooth_service/services/bluetooth/stack/src/hci/hdi_wrapper.c` | 库名改成"先 `.z.so` 再兜底"；加 `<stddef.h>` | **仓库改动**（已重编 `libbtstack.z.so`） |
| `vendor/pc/pc_ptl/bluetooth/src/bt_vendor_linux.c` | 传输层重写（5 socket + 类型恢复 + ioctl 号 + EALREADY + `H4ScanFrames`） | **仓库改动** |
| `vendor/pc/pc_ptl/bluetooth/include/bt_vendor_linux.h` | ABI 镜像 + Linux HCI 常量（`HCIDEVUP` 等） | **仓库改动** |
| `vendor/pc/pc_ptl/bluetooth/build_bt_vendor.sh` | 输出目录改成 `fix_bt_hci/work` | **仓库改动** |
| `vendor/ohemu/virt/hdf_config/uhdf/device_info.hcs:48` | 早已有 `caps = ["NET_ADMIN","NET_RAW"]`（上一轮加的），**本轮无需再改** | 未改 |
| `/vendor/etc/init/hdf_devhost.cfg`（镜像内） | 交付镜像里是**陈旧**的（`caps:["NET_ADMIN"]`）⇒ inject.sh 用 `hc-gen` 重新生成后注入 | **镜像改动** |

---

## 5. 验证

### 5.1 宿主机单元测试（H4 切帧逻辑）—— `tests/run_framing_test.sh`

```
=== bt vendor HAL H4 framing unit test ===
== H4 header geometry ==
   header geometry ok
== H4ScanFrames ==
   complete frames ok
   truncation + resync ok
=== ALL TESTS PASSED ===
```
覆盖：头几何与 HDI `header_` 表逐项一致；命令/事件/ACL 混流切帧正确；
**半帧不被吞掉**（必须留在缓冲区等剩下的字节）；**垃圾字节后能重新同步**。
（写测试时真的抓到一个 bug：EVT 帧 `plen` 与实际参数长度不一致时整帧会被正确地"等更多数据"，
说明切帧逻辑对 `plen` 敏感——这正是我们要的行为。）

### 5.2 QEMU 加载/ABI 自检 —— `tests/bt_vendor_selftest.c`

QEMU 的 x86_64_virt 内核 **`# CONFIG_BT is not set`**（`kernel/linux/config/linux-7.2/arch/x86/configs/x86_64_virt_standard_defconfig:1445`），
所以 **QEMU 里没有 BT 硬件**，只能做"编译 + 加载 + ABI + 优雅失败"自检（真机判据见 §6）。

在 QEMU guest 里（OHOS musl 运行时）实测（`evidence/qemu_selftest.txt`）：
```
[selftest] dlopen(/data/local/tmp/libbt_vendor.z.so)
[selftest] dlopen ok
[selftest] dlsym ok, size=32 (expected 32)
[selftest] init -> 0
[selftest] op(BT_OP_POWER_ON) -> 0
[selftest] op(BT_OP_GET_LPM_TIMER) -> 0, timer=0
[selftest] op(BT_OP_HCI_CHANNEL_OPEN) -> -1 (fd=-1)
[selftest] no HCI controller available - graceful failure (expected in QEMU)
[selftest] op(BT_OP_INIT) -> 0, initCb seen=1 result=0
[selftest] close ok
[selftest] === ALL CHECKS PASSED ===
```
即：**库能加载、符号导出且 size 正确(32B)、init/op/close 行为正确、init 回调送达、
无控制器时优雅失败而不是崩溃**。日志同时落到了 guest 的 `/sys_prod/bt_vendor.log` 与 `/data/local/tmp/bt_vendor.log`（`evidence/qemu_bt_vendor.log`）。

> 注意：测试程序**必须动态链接**。OHOS 的 musl 静态库里 `dlopen` 是桩
> （`third_party/musl/src/ldso/dlopen.c:6` "Dynamic loading not supported"），
> 静态链接的自检程序测不出任何东西——第一版就踩了这个坑。

### 5.3 搜索路径自检（证明 `dlopen("libbt_vendor.z.so")` 能找到 `/vendor/lib64`）

guest 里实测（`evidence/qemu_selftest.txt` 同批）：
```
[selftest] dlopen(libasound.so)
[selftest] dlopen ok
[selftest] FAIL dlsym(...): ... so=/vendor/lib64/libasound.so
```
裸名 dlopen **确实解析到了 `/vendor/lib64`** ⇒ 依赖 musl 命名空间 ini
（`/etc/ld-musl-namespace-x86_64.ini` 的 `namespace.default.lib.paths` 含 `/vendor/lib64`），
**不需要**额外配 LD_LIBRARY_PATH，也不需要把 `libbt_vendor.z.so` 复制到 `/system/lib64`。

### 5.4 镜像注入自检（`inject.sh`）

```
== partition geometry ==
   p2 system : start=1050624 sectors (2048 MiB)
   p3 vendor : start=5244928 sectors (512 MiB)
== regenerating hdf_devhost.cfg from .../hdf.hcs ==
   38:            "caps" : ["NET_ADMIN", "NET_RAW"],
== e2fsck ==
   p2: /: 5836/131072 files, 518170/524288 blocks
   p3: /vendor: 423/32768 files, 9037/131072 blocks
== verifying ==
   OK   libbtstack.z.so  (1702000 B)
   OK   libbt_vendor.z.so (14368 B)
   OK   hdf_devhost.cfg  (8283 B)
   OK   blue_host caps contain NET_RAW
```
**幂等性**：连跑两次，第二次识别出"已经是修复版"并**完全不动镜像**
（镜像 sha 保持 `80bcb00b…` 不变）——见 `evidence/sha256.txt`。

### 5.5 断点 A 的直接证据

交付镜像里**原有**的 `libbtstack.z.so`：
```
$ strings -a work/orig_btstack.so | grep hdi_adapter
Load libbluetooth_hdi_adapter.so failed, %{public}s
libbluetooth_hdi_adapter.so          ← 只有这个"不存在"的名字
```
注入后的新库：
```
$ strings -a work/verify_btstack.so | grep hdi_adapter
libbluetooth_hdi_adapter.z.so        ← 新增
libbluetooth_hdi_adapter.so
```

---

## 6. 真机判据（**本轮未验证**，需要在 HONOR XWC-P 上跑）

> QEMU 无 BT 硬件，**以上都不能替代真机验证**。以下按"能一次定性"排序。

### A 组：加载链（先确认断点 A 修好了）
```sh
hdc shell "hilog -r"                      # 清缓冲
# 然后在设置里点开蓝牙开关
hdc shell "hilog -x | grep -iE 'bluetooth_hdi_adapter|LoadHdiLib|hdiInit failed|HdiInited failed'"
```
* 期望**不再**出现 `Load libbluetooth_hdi_adapter.so failed`（旧镜像一定会出现）。
* 期望**不再**出现 `hdiInit failed` / `HdiInited failed: -1`
  （`stack/src/hci/hci.c:121-146`：HDI 5 秒不回就 `SIGTERM` 掉整个 `bluetooth_service`）。
* 期望出现 `HciInterfaceImpl Init`（`hci_interface_impl.cpp:66`）与 `VendorInterface dlopen`
  （`vendor_interface.cpp:115`）。

### B 组：vendor HAL 真被加载了
```sh
hdc shell "ls -l /sys_prod/bt_vendor.log /mnt/od/bt_vendor.log /data/local/tmp/bt_vendor.log"
hdc shell "cat /sys_prod/bt_vendor.log"
```
* 期望能看到 `init: cb=... bdaddr=...`、`op BT_OP_POWER_ON`、`BT_OP_HCI_CHANNEL_OPEN ok: returning 1 channel, fd=... (hci0)`、
  `SO_HCI_FILTER set: type_mask=0x00000010`（事件通道）等行。
* 若**没有**这个文件 ⇒ vendor HAL 仍没被 dlopen，回到 A 组。
* 若有 `bind hci0 failed: Permission denied` ⇒ `blue_host` 还是没有 `NET_RAW`
  （检查 `/vendor/etc/init/hdf_devhost.cfg` 里 `blue_host` 的 `caps` 是否含 `NET_RAW`，
  以及 `/proc/<blue_host pid>/status` 的 `CapEff`）。

### C 组：功能判据
```sh
hdc shell "hidumper -s 1130 -a '-h'"       # ★ 是 1130（SA id），不是 -s Bluetooth
hdc shell "hidumper -s 1130 | head -60"
```
* ⚠️ diag 里用的 `hidumper -s Bluetooth` **是错的命令**：`-s` 的参数是 **SA id**
  （`base/hiviewdfx/hidumper/frameworks/native/src/manager/dump_implement.cpp:900-903` → `isDumpSystemAbility_`），
  所以 "request error" **不能**作为"蓝牙服务坏了"的证据。蓝牙服务是 SA **1130**
  （`foundation/communication/bluetooth_service/sa_profile/1130.json`）。
* 期望能扫到设备：日志里 `k2u=… frames` 持续增长，且 `bt_vendor.log` 里能看到事件帧在流动。

### D 组：内核侧对照
```sh
hdc shell "ls /sys/class/bluetooth/hci0"          # 已有（diag 已证）
hdc shell "cat /proc/net/bluetooth/hci0 2>/dev/null"   # 有 socket 说明有用户态绑定
```

---

## 7. 怎么用（注入 & 回退）

### 注入
```sh
# 1) 先在 scratch 副本上试（绝不直接改交付镜像）
cd /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/fix_bt_hci
cp --sparse=always ../partdisk/media/ohos_part_pc_ptl.img scratch.img
bash inject.sh scratch.img

# 2) 真机：把 scratch.img 写进 U 盘（用既有的 dd_and_verify.sh 流程）
```
`inject.sh` 会做：
1. 从镜像里 `dd` 出 p2/p3；
2. 用 `hc-gen` 从 `vendor/ohemu/virt/hdf_config/uhdf/hdf.hcs` **重新生成** `hdf_devhost.cfg`（带 `NET_RAW`）；
3. `debugfs rm/write` 写入
   - p2 `/system/lib64/libbtstack.z.so`（协议栈库名修复）
   - p3 `/lib64/libbt_vendor.z.so`（新 vendor HAL）
   - p3 `/etc/init/hdf_devhost.cfg`（`NET_RAW`）
4. `e2fsck -f -y` 两个分区；
5. `dd` 回写、`sha256sum` 前后对比、逐文件 `cmp` 校验；
6. **已经是修复版就一步不动镜像**（字节级幂等）。

### 回退
```sh
# 只要回退 BT 部分：把交付镜像里的两个文件原样塞回去
#   p2 /system/lib64/libbtstack.z.so   ← 旧件可用 fix_bt_hci/work/orig_btstack.so
#   p3 /lib64/libbt_vendor.z.so        ← 旧件在交付镜像里（12,864 B 的上一版 shim）
# 最省事：直接用交付镜像 partdisk/media/ohos_part_pc_ptl.img（92274c80…）
```
源码回退：
```sh
git -C foundation/communication/bluetooth_service checkout -- services/bluetooth/stack/src/hci/hdi_wrapper.c
# vendor/pc/pc_ptl 不在 repo 管理内，直接删 bluetooth/ 目录即可
```

---

## 8. 遗留 / 风险（**如实说明**）

1. **本轮没有真机运行期证据**。以上全部是静态取证 + 宿主/QEMU 自检。
   "蓝牙开关可开、能扫到设备"**尚未被证明**，§6 是判定脚本。
2. **内核 HCI core 与 OHOS 协议栈双主**：`btintel_pcie` 在 probe 时已经把控制器拉起并跑完
   内核自己的 init 序列（`hci_dev_init_sync`）。我们再通过 RAW socket 下 `HCI_Reset`，
   内核 core 也会收到 Command Complete —— 行为上应当无害（BlueZ 的 raw 用法同构），
   但**未在真机验证**；若出现控制器状态异常，备选方案是改用 `HCI_CHANNEL_USER`
   （独占用户通道，但要求设备处于 down，本平台不满足，需改内核/驱动侧）。
3. **SELinux**：本产品 `selinux_adapter_enforce=false`（permissive），
   `blue_host` 的 `secon = u:r:blue_host:s0` 在 permissive 下不拦截 AF_BLUETOOTH socket；
   若将来开 enforcing，需要补 `blue_host` 的 `socket bluetooth` 策略。
4. **没有 `SCM_CBFCPT`**（本内核已移除），所以类型恢复只能靠"每类型一个 socket + type_mask"。
   如果将来内核恢复 cmsg，可以简化成一个 socket。
5. `BT_OP_EVENT_CALLBACK` / `xmitCb` 两条回调路径**没有使用**（我们直接持有传输层，
   HDI 侧的 `vendorSentOpcode_` 机制因此不生效）——这与 Broadcom/Realtek 参考实现的行为一致
   （它们也只用 fd 通道），但 `vendor_interface.cpp:291-308` 那段"把 Command Complete 回灌给 vendor lib"
   在我们这里不会发生。当前无影响（vendor HAL 不需要解析事件）。
6. `hdi_wrapper.c` 保留了老的库名作为兜底，理论上**老镜像**也能跑；但老镜像的
   `libbluetooth_hdi_adapter.so` 本来就不存在，所以兜底只是防御性代码。
7. **`hidumper -s Bluetooth` 是错误命令**（应为 `-s 1130`）。之前的 diag 报告把它当成
   "蓝牙服务无响应"的证据，属于误判——已在 §6 更正。

---

## 9. 产物清单

```
out/x86_64_virt/ohos-dbg/fix_bt_hci/
├── SUMMARY.md                     本报告
├── inject.sh                      幂等注入脚本（p2/p3 + cfg 重新生成 + 校验）
├── scratch.img                    验证用镜像副本（80bcb00b…，交付镜像未动）
├── build_btstack.log              libbtstack.z.so 重编日志（45s，成功）
├── work/
│   ├── libbt_vendor.z.so          新 vendor HAL（14,368 B，678a8a9e…）
│   ├── orig_btstack.so            交付镜像里的旧协议栈库（用于对比取证）
│   ├── e2fsck_p2.log / e2fsck_p3.log
│   └── cfg/.cfg                   hc-gen 重新生成的 hdf_devhost.cfg
├── tests/
│   ├── h4_framing_test.c          H4 切帧单元测试（宿主机）
│   ├── run_framing_test.sh
│   ├── bt_vendor_selftest.c       vendor HAL 加载/ABI 自检（guest 内）
│   └── build_selftest.sh
└── evidence/
    ├── qemu_selftest.txt          QEMU 加载/ABI 自检输出
    ├── qemu_bt_vendor.log         QEMU guest 里的 bt_vendor.log
    └── sha256.txt                 各产物 sha256
```
