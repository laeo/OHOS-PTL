# pc_ptl 真机 U 盘：真实 GPT 分区磁盘镜像（2026-10-02）

> 任务：把"单分区装 5 个 `.img` + 自定义 `boot_init` loop 挂载"改成**真实 GPT 分区**
> （GPT 名 = `system/vendor/sys_prod/chip_prod/userdata`）的单个可 dd 磁盘镜像，尽量
> 改用 **stock OHOS init**。产物全部在本目录，未写 `/tmp`，未碰内部硬盘/ESP。

---

## 0. 一句话结论

- 产出可 dd 的 UEFI/GPT 磁盘镜像：**p1 ESP + p2..p6 真实分区**，`.img` 用 `dd` 原样写入分区，
  **无 loop、无挂载写入**。QEMU 里 **OVMF→GRUB→USB 整盘引导到 OHOS 用户态**，并在**真实
  `/data` 分区**写下 335,442 B `zzpslog.log`；宿主侧可直接读该分区的完整目录树（含日志）。
- **但无法完全去掉引导辅助程序**：x86 上 stock init 不能挂载 U 盘真实分区（两个硬原因，§2），
  故保留一个**极小、不做 loop** 的 `part_init`（830 KB 静态程序，~130 行 C）：它挂 devtmpfs、
  等待真实 GPT 分区出现、建 `/dev/block/by-name/*` 链接，然后 **exec 真正的 stock `/init`**。
  真正的挂载/switch_root/服务全部由 stock OHOS init 完成。
- stock initramfs 已查明就是 `out/ptl/packages/phone/images/ramdisk.img`（`/init -> bin/init_early`，
  且已自带 `/lib/firmware/**`）。

---

## 1. 标准启动链（查证结果）

| 项 | 结果 |
|---|---|
| stock initramfs | `out/ptl/packages/phone/images/ramdisk.img`（5,549,496 B，gzip newc cpio）；根有 `/init -> bin/init_early`、`/bin/init`、`/lib/firmware/{xe,i915,intel}/**` |
| 内核内建 initramfs | `CONFIG_INITRAMFS_SOURCE=.../kernel_embedbi/initramfs_root`（**只含 `boot_init`**，已编进 `bzImage`）；外部 `-initrd` 叠加在其上，所以 stock 文件可用 |
| 旧 cmdline | `rdinit=/boot_init root=/dev/ram0`（自定义 helper） |
| 新 cmdline | `rdinit=/part_init root=/dev/ram0`；`part_init` 最后 `execl("/init")`，即 **stock 第一级 init** |
| stock 第一级 init 行为 | `bin/init_early`（`init_firststage.c`）读 cmdline `ohos.required_mount.*` → `StartUeventd` → 挂载 → `execv("/bin/init")` 第二级 |
| 固件 | stock ramdisk 已含 `device/pc/ptl/firmware`；本镜像 ramdisk 再追加一份，保证早窗口 |

**结论**：`rdinit` 仍需要一个入口程序，但那个程序不再是"loop 挂载器"，只做"等分区 + 建 by-name"。

---

## 2. 为什么 x86 上 stock init 不能自动挂载 U 盘真实分区（已实测，非猜测）

### 2.1 ueventd 的 `by-name` 只对 platform 总线设备生效
`base/startup/init/ueventd/ueventd_device_handler.c` 里，`/dev/block/by-name/<PARTNAME>`
只在 `GetBlockDeviceSymbolLinks()` 找到 **`/sys/bus/platform`** 祖先时才创建
（`BuildDeviceSymbolLinks` + `BootDeviceIsMatched`）。x86 的 U 盘链路是
`pci0000:00 -> xhci(PCI) -> usb -> scsi -> sda`，**没有任何 platform 祖先**，
所以 ueventd 不会建 by-name。实测（小盘 + stock `/init` + `required_mount.system=/dev/block/by-name/system`）：

```
[ 5.693664] wait for file:/dev/block/by-name/system failed after 5 second.
[ 5.694674] /dev/block/by-name/system: Can't lookup blockdev
```
（日志：`bynametest/ser2.log`）

### 2.2 一次性 uevent 触发早于 U 盘枚举
`init_early` 在 ~0.6 s 调 `StartUeventd()` 触发一次 `/sys/block|class|devices` 的 uevent；
QEMU 里 USB 盘在 ~1.8 s 才枚举出来。触发时设备还不存在，之后 ueventd 已关闭 socket、
不再重试 → 连 `/dev/block/sdaN` 也没有。实测：

```
[ 0.682959] Mount required partitions
[ 5.706632] wait for file:/dev/sda2 failed after 5 second.
```
（根因：`bzImage` 内建 initramfs 没有 `/dev` 目录 → 内核 `CONFIG_DEVTMPFS_MOUNT` 的自动
devtmpfs 挂载失败 → stock init 给 `/dev` 挂的是普通 tmpfs、设备节点完全依赖 ueventd。）

### 2.3 于是保留极小 helper（符合任务"若无法完全去掉，至少不依赖它做 loop"）
`part_init.c`：`mount devtmpfs /dev` → 轮询 `/sys/class/block/*/uevent` 的 `PARTNAME=`
→ `symlink(/dev/sdaN, /dev/block/by-name/<name>)` → `exec /init`。**没有任何 loop 设备**。
源码与编译产物在本目录。

---

## 3. 磁盘布局（最终镜像）

```
p1  ESP        512.0 MiB  EF00   FAT32：BOOTX64.EFI(GRUB2.14) + /boot/bzImage
                                 + /boot/ramdisk_bootmedia.img + /boot/grub/grub.cfg
                                 + /ohos_build_id
p2  system    2048.0 MiB  8300   原样 system.img     (fs == 分区)
p3  vendor     512.0 MiB  8300   原样 vendor.img     (fs == 分区)
p4  sys_prod    64.0 MiB  8300   原样 sys_prod.img   (fs == 分区)
p5  chip_prod   64.0 MiB  8300   原样 chip_prod.img  (fs == 分区)
p6  userdata  2064.0 MiB  8300   userdata.img +16MiB，resize2fs 撑满 (fs == 分区)
```
- 分区起始 1 MiB 对齐；`sgdisk -v` → **No problems found**；镜像最后扇区 = `EFI PART`。
- 原始 p6（未启动过）根下**只有 `lost+found`**，**没有任何 `.img` 文件**（证明是真实文件系统）。
- 所有 `.img` 都是 `dd ... conv=fsync` 直写分区，**没有 loop / mount**。

---

## 4. QEMU 端到端验证（串行，QEMU 单实例，用完即杀）

产物均是**整盘镜像 + qcow2 overlay**（不修改交付盘）。

### 4.1 Stage A：`-kernel/-initrd` + verbose 串口（细节证据）
脚本 `run_kernel_serial.sh`，日志 `stepA_serial.log`：
```
part_init: waiting for real GPT partitions (max 120s)
part_init: by-name links present: 0/5
part_init: linked /dev/block/by-name/sys_prod  -> /dev/sda4
part_init: linked /dev/block/by-name/system    -> /dev/sda2
part_init: linked /dev/block/by-name/chip_prod -> /dev/sda5
part_init: linked /dev/block/by-name/vendor    -> /dev/sda3
part_init: linked /dev/block/by-name/userdata  -> /dev/sda6
part_init: by-name links present: 5/5
part_init: listing /dev/block/by-name (like 'ls -l /dev/block/by-name/'):
part_init:   userdata -> /dev/sda6 (block 8:6)
part_init:   vendor   -> /dev/sda3 (block 8:3)
part_init:   chip_prod-> /dev/sda5 (block 8:5)
part_init:   system   -> /dev/sda2 (block 8:2)
part_init:   sys_prod -> /dev/sda4 (block 8:4)
part_init: handing off to /init
...
[Init][switch_root.c:191]SwitchRoot to /usr finish
Mount /dev/block/by-name/system    to /usr       successful
Mount /dev/block/by-name/vendor    to /vendor    successful
Mount /dev/block/by-name/sys_prod  to /sys_prod  successful
Mount /dev/block/by-name/chip_prod to /chip_prod successful
Mount /dev/block/by-name/userdata  to /data      successful
...
ServiceStart started info samgr / hilogd / zzpslog / storage_manager / hiview / appspawn
```
**运行 150 s 无 kernel panic**（`grep -c "Kernel panic"` = 0）。

### 4.2 Stage B：OVMF→GRUB→USB 整盘引导
脚本 `run_ovmf_usb.sh`，日志 `stepB_serial.log`：
```
BdsDxe: starting Boot0002 "UEFI QEMU QEMU USB HARDDRIVE ..."
GNU GRUB  version 2.14
*OpenHarmony 7.0 PC - normal boot [1]
 OpenHarmony 7.0 PC - verbose log (keep_bootcon) [2]
 ...
The highlighted entry will be executed automatically in ... 0s
```
（cmdline 用 `console=tty0`，所以 GRUB 之后内核日志走 EFI 屏、串口无内核日志；
故用宿主侧读真实 `/data` 证明已到用户态。）

### 4.3 真实 `/data` 分区被挂载并写日志（宿主侧只读取证，无需 loop/root）
对 Stage B 的 overlay 做 `qemu-img convert -O raw` 后切出 p6（**纯 dd，不 loop**），
`debugfs` 列出：
```
/data:  service system local log power samgr app chipset ohos-log misc vendor
        data nfc updater bluetooth update lost+found
/data/ohos-log/zzpslog.log   335872 B   (guest 运行中写入)
```
`zzpslog.log` 首行：`build_id=BUILD_ID=20261002-141259-89b1c0472b19 ... BUILD_SCRIPT=make_partition_disk.sh`。
→ **真实 /data 挂载成功、可写、日志落盘、宿主可直接读**。

---

## 5. 交付产物 / dd 步骤

| 产物 | 路径 | 大小(B) | sha256 |
|---|---|---|---|
| **★ pc_ptl 真实分区磁盘镜像** | `out/x86_64_virt/ohos-dbg/partdisk/media/ohos_part_pc_ptl.img` | **5,522,849,792** | **`dba862d78f9d64eb8fa5b4db0e79365ecedcf4e74ca1ed63aebbb6956b52d644`** |
| ramdisk（stock init + firmware + part_init） | `partdisk/media/ramdisk_bootmedia.img` | 8,850,929 | `4f45061a…` |
| part_init（不做 loop） | `partdisk/media/part_init` | 830,424 | `2e3536cd…` |
| BUILD_ID | — | — | `20261002-141259-89b1c0472b19` |

**上机前自检 + dd（会整盘覆盖 U 盘！）**
```sh
IMG=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/partdisk/media/ohos_part_pc_ptl.img
lsblk -o NAME,SIZE,MODEL           # 认准外接 U 盘（别写内部盘！）
sudo dd if="$IMG" of=/dev/sdX bs=16M status=progress conv=fsync && sudo sync
# 镜像只有 5.1GiB，U 盘更大：把备份 GPT 挪到物理盘末尾 + 重新读分区表
sudo sgdisk -e /dev/sdX && sudo partprobe /dev/sdX
```
**引导**：关 Secure Boot → 选 `UEFI: <U盘>` → GRUB 菜单（默认 [1]，15 s 自动启动；
排障选 `[2] verbose`）。

**在 Ubuntu 上直接读真实 /data（U 盘重新插回后；p6 就是 userdata 分区，不再有 .img）**
```sh
sudo mount /dev/sdX6 /mnt/od
sudo ls -l /mnt/od                       # 正常 OHOS /data 目录树
sudo tail -n 40 /mnt/od/ohos-log/zzpslog.log
sudo umount /mnt/od
```

---

## 6. QEMU 复现命令

```sh
cd /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/partdisk
timeout 150 bash run_kernel_serial.sh    # Stage A：详细串口证据
timeout 150 bash run_ovmf_usb.sh         # Stage B：OVMF→GRUB→USB
```
（两者都自动 `pkill -9 -f 'qemu-system-x86_64 -[m]achine'` 且用 overlay，不修改交付盘。）

---

## 7. 诚实的局限 / 已排除项

1. **必须保留 `part_init`（非 loop）**。已按任务允许的"若无法完全去掉，至少不依赖它做 loop"
   处理：真实分区、无 loop；但"完全用 ueventd 自动建 by-name"在 x86 上**不成立**（§2，有实测）。
   若一定要彻底去掉，需要改 `base/startup/init/ueventd`（让 by-name 不依赖 platform 总线，
   并让 init_early 支持延迟/重试 uevent）+ 重编内核内建 initramfs（加入 `/dev` 目录以启用
   devtmpfs）——代价大，本任务未做。
2. **QEMU 上 pc_ptl 用户态本身有既有 bring-up 问题**（早期记录：BMS `bundles.ready` 未上报 →
   foundation 反复崩）。本磁盘镜像的用户态启动到 samgr/hilogd/zzpslog/appspawn 正常；
   QEMU 能否走到桌面与磁盘结构无关。**真机行为未验证（无 PTL 现场/权限）**。
3. **`/dev/sdaN` 假设**：U 盘在 SCSI 编号里是 `/dev/sda`（内建 NVMe 是 `/dev/nvme0n1`，
   不冲突）。若同时插了别的 SCSI/U 盘，`sda` 可能变。by-name 由 `PARTNAME` 匹配，更稳。
4. 真机 USB 枚举更慢时，`part_init` 最多等 120 s（看到 `system` 后最多再等 5 s 就交接），
   足够覆盖慢速 U 盘；若某分区缺失会打 `WARNING` 但仍交接。
5. 本任务**未重编 OHOS/内核**；只新增脚本/程序并重新组装镜像；对 `out/ptl/.../system.img`
   只重盖了 `/system/etc/ohos_build_id`（与既有流程一致）。

---

## 8. 关键文件

- 构建脚本：`make_partition_disk.sh`
- helper 源码/二进制：`part_init.c` / `media/part_init`
- QEMU：`run_kernel_serial.sh`（Stage A）、`run_ovmf_usb.sh`（Stage B）
- 证据：`stepA_serial.log`、`stepB_serial.log`、`work/p6_ovl.raw`、`work/zzpslog_dump.log`、
  `work/p6_stepB.raw`、`bynametest/ser2.log`（by-name 反向证据）
