# pc_ptl 真机 U 盘镜像 —— 诊断版 part_init（2026-10-03）

> **⚠️ 最新一轮（2026-10-04，`/data`=tmpfs 内存盘 + 持久日志落点）见文末第 10 节。**
> 当前交付镜像 sha256 = **`9eb575e2073ffdd93622abfa07ca2c9826942219342da4ce05d2ed1aa7044c15`**
> （5,522,849,792 B），GRUB 菜单 **[1]..[6] + [D]**，默认仍 **[2] NoRAMOOPS**；
> **[D] = `/data` 用 tmpfs（内存盘）、真实 userdata 只当日志盘挂 `/ohoslog`**。
>
> （上一轮 2026-10-03 晚见第 9 节，旧镜像 sha `96db48a0…`。）

> **⚠️ 最新一轮（2026-10-03 晚，外置 GRUB 配置 + 六组诊断菜单）见文末第 9 节。**
> 当前交付镜像 sha256 = **`96db48a076e25e2fcb5c7ad48617eab8f5eb1515963b4be341dab9ae7d4f9658`**
> （5,522,849,792 B），GRUB 改为**从 ESP `/boot/grub/grub.cfg` 普通文件加载**，
> 菜单 [1]..[6]，默认 **[2] NoRAMOOPS**。

> 承接 `SUMMARY.md`。真机（Intel PTL，**无串口，唯一输出是屏幕 `console=tty0`**）现象：
> GRUB 选 [2] verbose 后刷一会日志就重启到 Windows，事后 `/data`、`sys_prod`、`chip_prod`
> **全是出厂内容** → OHOS 从未挂载/运行。本任务把 `part_init` 改成"会说话"的诊断版，
> 以便在没有串口/照片的情况下把失败原因留在屏幕上。

---

## 0. 一句话结论

- 新镜像：**`media/ohos_part_pc_ptl.img`，5,522,849,792 B，
  sha256 `54f93ac142183df76efb6d3ce0090d87fe0e62b9034bc730813e3b29b3c40731`**（BUILD_ID `20261002-163617-89b1c0472b19`）。
- `part_init` 诊断版：遍历 `/sys/class/block/*` 打印每个块设备的 `DEVNAME/PARTNAME/size`；
  每 2s 打 `waiting partitions, found N/5 <名字>`；90s 超时后打印
  `WARNING: only N/5` + 完整块设备清单 + `/proc/partitions` + `/proc/mounts` +
  内核日志尾部（**非破坏性** `syslog(2) READ_ALL`，不读 `/dev/kmsg`）；0 分区时打大横幅
  `!!! ONLY 0/5 PARTITIONS - USB DISK NOT SEEN !!!`；**无论成败都继续 `exec /init`**。
- 所有 part_init 消息以 `<0>`（KERN_EMERG）写 `/dev/kmsg` → **无视 kernel loglevel，必然出现在
  `tty0` 屏幕上**；仅当 `/dev/kmsg` 不可用时才回退直写 `/dev/console`（单通道，避免交织乱码）。
- 核实：ramdisk 里 **`/init`（stock，= `bin/init_early`）与 `/part_init` 都在**；
  `system.img` 的 **zz_pslog 已安装且已启用**（`disabled:0`, `start-mode:boot`）→ 无需补。
- QEMU 验证：
  - **OVMF→GRUB→USB 整盘**引导到用户态，真实 p6(`/data`) 里
    `/data/ohos-log/zzpslog.log` = **393,216 B / 71 个快照**，首行 build_id 与新镜像一致。
  - **无盘**实例（`-kernel` 不带任何磁盘）确认诊断真的打到 console：
    t=90.3s 出现 `WARNING: only 0/5`、块设备清单（只有 loop/ram/sr0，无 sda）、
    `/proc/mounts`、dmesg 尾部、大横幅，随后 `handing off to /init (0/5)`。

---

## 1. 交付产物

| 产物 | 路径 | 大小(B) | sha256 |
|---|---|---|---|
| **★ 磁盘镜像** | `media/ohos_part_pc_ptl.img` | **5,522,849,792** | **`54f93ac142183df76efb6d3ce0090d87fe0e62b9034bc730813e3b29b3c40731`** |
| ramdisk（stock init + part_init + firmware） | `media/ramdisk_bootmedia.img` | 8,865,950 | `77a36079d814a11094603b47a099e966e2a85c309d7b702cd538c6c6950c3ea7` |
| part_init（诊断版，静态） | `media/part_init` | 877,280 | `30b5a9eb4e54c52f3483d33796e7822f26caf8c751e08393ee5668043c9fbc6e` |
| BUILD_ID | — | — | `20261002-163617-89b1c0472b19` |

布局不变，仍是真实 GPT：p1 ESP / p2 system / p3 vendor / p4 sys_prod / p5 chip_prod / p6 userdata
（分区名字 = GPT 名，`.img` 用 `dd conv=fsync` 直写，无 loop / 无 mount）。
自检：`sgdisk -v` 无问题、末尾扇区=`EFI PART`、五个 fs 全部 `part_bytes == fs_bytes`。

---

## 2. `part_init` 诊断版改了什么（`part_init.c`）

1. **块设备全量清单** `dump_block_devices()`：遍历 `/sys/class/block/*`，逐个打印
   `名字 DEVNAME=... PARTNAME=(none|名字) size=XMiB (扇区数)`。启动挂好 devtmpfs 后先打一次，
   分区出现时再打一次，失败超时后再打一次。→ 可一眼区分 **U 盘完全没被内核枚举** vs
   **枚举到了但分区名/链接没建**。
2. **等待进度**：每 2s（200ms×10 tick）打印
   `waiting partitions, found N/5 system vendor sys_prod chip_prod userdata`（已找到才列名）。
3. **超时诊断**（默认 `WAIT_SECONDS=90`，见常量）：
   `WARNING: only N/5 partitions` → 块设备清单 → `/proc/partitions` → `/proc/mounts`
   → `dmesg tail`。
   dmesg 用 **`syscall(SYS_syslog, SYSLOG_ACTION_READ_ALL, ...)`（非破坏性，等价 `dmesg` 不加 `-c`）**，
   **不读 `/dev/kmsg`**（读会消耗），拿不到就跳过、绝不阻塞；并过滤掉自己刚打的
   `part_init:` 行，只留真实内核/硬件信息。
4. **醒目横幅**：0 分区时打
   `!!! ONLY 0/5 PARTITIONS - USB DISK NOT SEEN !!!` 并提示检查 xHCI/USB_STORAGE/供电。
5. **永不卡死**：无论 N/5，最后都 `exec /init`，因此即使 part_init 没问题也能继续观察 stock init。
6. **可见性**：`klogf()` 以 `<0>` 写 `/dev/kmsg`（KERN_EMERG 无视 loglevel，必上 `tty0`；
   也进 ring buffer/pstore），失败才回退直写 `/dev/console`/`/dev/tty0`。
   —— 只用一个通道，避免"kmsg+直写 console"在 ttyS0 上逐字节交织成乱码。
7. 保留原职责与"不建 loop、不碰 .img"原则：挂 devtmpfs → 轮询 `PARTNAME=` → 建
   `/dev/block/by-name/<name> -> /dev/sdaN` → `exec /init`。

---

## 3. 核实结论（两项）

### 3.1 ramdisk 里确有 `/init` 与 `/part_init`
`ramdisk_bootmedia.img` = `zcat` 出 263 个 cpio 头、3 个 `TRAILER!!!`（stock base + 追加 extra）。
`cpio -it` 会在**第一个** TRAILER 处停下，所以只列 stock 部分；逐头解析确认存在
**`init`、`bin/init_early`、`part_init`**。`init` 是 stock OHOS 第一级 init（软链 `bin/init_early`）。

### 3.2 `system.img` 里 zz_pslog 已安装且启用
```
/system/bin/zz_pslog.sh          100755  8949 B
/system/etc/init/zz_pslog.cfg    100644   336 B
```
`zz_pslog.cfg`：`name=zzpslog, path=[/system/bin/sh /system/bin/zz_pslog.sh],
start-mode="boot", disabled=0, sandbox=0, uid=root, secon=u:r:console:s0` → **开机即启动**，
无需补装/改配置。脚本落盘目录 `/data/ohos-log/`。

---

## 4. QEMU 验证

> 约定：QEMU 单实例，用完 `pkill -9 -f 'qemu-system-x86_64 -[m]achine'`；overlay 不修改交付盘。

### 4.1 Stage A：`-kernel/-initrd` + 串口（带盘）
脚本 `run_kernel_serial.sh`（`stepA_serial.log`）。诊断输出（干净无交织）：
```
part_init: --- block devices [early, right after devtmpfs] ... (25 entries) ---   # loop*/ram*/sr0
part_init: waiting for real GPT partitions (max 90s)
part_init: waiting partitions, found 0/5
part_init: linked /dev/block/by-name/system -> /dev/sda2
... 5 条 ...
part_init: waiting partitions, found 5/5 system vendor sys_prod chip_prod userdata
part_init:   sda2 ... PARTNAME=system ... / sda6 ... PARTNAME=userdata / sda1 PARTNAME=ESP / sda 整盘
part_init: handing off to /init (5/5 partitions)
[pid=1][BEGET] Mount /dev/block/by-name/system  to /usr       successful
... vendor/sys_prod/chip_prod/userdata 全部 successful ...
[pid=1] ServiceStart started info ... zzpslog ...
Kernel panic 计数 = 0
```

### 4.2 Stage B：OVMF→GRUB→USB 整盘
脚本 `run_ovmf_usb_wt.sh`（= 官方 `run_ovmf_usb.sh` **加 `cache=writethrough` + QMP**，
用于优雅 `quit` 刷盘），`stepB_wt_serial.log` / `stepB_wt_overlay.qcow2`。
- 串口见 `BdsDxe: starting Boot0002 "UEFI QEMU QEMU USB HARDDRIVE"` → `GNU GRUB 2.14` 菜单 →
  15s 后按 [1] 启动（cmdline `console=tty0`，故 GRUB 之后内核日志不上串口，属预期）。
- 宿主侧**纯 dd（无 loop/root）**切出 p6，`debugfs`（先 `e2fsck` 重放 ext4 日志）：
  ```
  /data: service system local log power samgr app chipset ohos-log misc vendor data
         nfc updater bluetooth update lost+found
  /data/ohos-log/zzpslog.log   393,216 B
  首行: ===== zzpslog session start uptime=3s ... build_id=BUILD_ID=20261002-163617-89b1c0472b19 ...
         BUILD_SCRIPT=make_partition_disk.sh ... =====
  SNAP 数: 71
  ```

### 4.3 故意"分区看不到"：无盘实例确认诊断上 console
脚本 `run_nodisk_diag.sh`（`-kernel`，**完全不带任何磁盘**），`nodisk_serial.log`：
```
[t=0.66] part_init: waiting partitions, found 0/5
[t=2.66] ... 每 2s 一次 ...
[t=90.22] part_init: WARNING: only 0/5 partitions
[t=90.25..] --- block devices [after wait] (25 entries) ---   # 只有 loop/ram/sr0，无 sda
            --- /proc/partitions / /proc/mounts / dmesg tail ---
[t=90.29] part_init: !!! ONLY 0/5 PARTITIONS - USB DISK NOT SEEN !!!
[t=90.30] part_init: handing off to /init (0/5 partitions)
```
→ 证明真机即便没有串口/照片，**失败原因（含内核是否枚举到 U 盘）也会留在屏幕上**。

---

## 5. 复现命令 / 上机

```sh
cd /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/partdisk
bash make_partition_disk.sh                 # 重编 part_init + 重组整盘（后台跑，约 2 min）
timeout 100 bash run_kernel_serial.sh       # Stage A：带盘，串口看诊断+挂载
timeout 100 bash run_nodisk_diag.sh         # 故意无盘：证明失败诊断上 console
# Stage B（稳妥取证）：用 writethrough + QMP 优雅退出，再 verify_p6.sh 读 p6
bash run_ovmf_usb_wt.sh & sleep 155; <QMP {"execute":"quit"}>
bash verify_p6.sh work/stepB_wt_overlay.qcow2   # convert+dd 切 p6，再 e2fsck -f -y 后 ls
```

**上机 dd（会整盘覆盖 U 盘，认准外接盘！）**
```sh
IMG=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/partdisk/media/ohos_part_pc_ptl.img
sudo dd if="$IMG" of=/dev/sdX bs=16M status=progress conv=fsync && sudo sync
sudo sgdisk -e /dev/sdX && sudo partprobe /dev/sdX   # 镜像 5.1GiB，挪备份 GPT 到盘尾
```
引导：关 Secure Boot → 选 `UEFI: <U盘>` → GRUB 选 **[2] verbose**（排障）。
在 Ubuntu 上读真实 `/data`：`sudo mount /dev/sdX6 /mnt/od && cat /mnt/od/ohos-log/zzpslog.log`。

---

## 6. 坑 / 注意（写给下一个会话）

1. **debugfs 的路径**：p6 文件系统就是 `/data`，其**根**直接是 `ohos-log service log app ...`；
   要访问必须写 `/ohos-log/zzpslog.log`，写 `/data/ohos-log` 会得到 `NOT FOUND`。
2. **必须 `e2fsck -f -y` 重放日志后再 `debugfs`**：QEMU 非优雅退出时 `/data` 根目录的
   htree 叶子/日志未落盘，不重放会**只看到 4 个目录**、误判"zzpslog 没跑"。
   稳妥做法是 QEMU 用 `cache=writethrough` + QMP 优雅 `quit`（见 `run_ovmf_usb_wt.sh`），
   或退出后对 p6 副本 `e2fsck -f -y` 再读。
3. **QEMU 上 pc_ptl 用户态并非完全健康**：`zzpslog.log` 里 `PROC ABSENT : foundation /
   render_service`，说明 QEMU 下 foundation 未起来（SUMMARY §7.2 记录过的既有 bring-up 问题）。
   但 `/data` 挂载、zzpslog 落盘等**磁盘链路完全正常**——磁盘镜像本身没问题。
4. `zz_pslog.sh` 启动时会 `dmesg -n 3` 压低 console 级别 → 之后串口会"静默"，这不是死机；
   想全程看日志可在 cmdline 加 `ignore_loglevel`（仅诊断用，不进交付镜像）。
5. 诊断版 part_init 等满 90s 才放弃，慢速 U 盘/慢枚举有足够时间；若某分区真缺，打 WARNING 后仍交接。

---

## 7. 关键文件

- 构建：`make_partition_disk.sh`（本次**未改脚本**，只改了它调用的 `part_init.c`）
- helper：`part_init.c` / `media/part_init`（诊断版）
- QEMU：`run_kernel_serial.sh`（Stage A）、`run_nodisk_diag.sh`（无盘诊断）、
  `run_ovmf_usb.sh`（Stage B）、`run_ovmf_usb_wt.sh`（Stage B + writethrough/QMP）、`verify_p6.sh`
- 证据：`stepA_serial.log`、`nodisk_serial.log`、`stepB_wt_serial.log`、
  `work/zzpslog_dumpWT.log`（393216 B）、`work/stepB_wt_overlay.qcow2`、`work/e2fsck_p6WT.log`

---

## 8. 追加（2026-10-03）：[2] 改为"失败即冻屏"诊断项 + QEMU 冒烟

> 真机现象：GRUB 选 [2] 后屏幕刷一会日志就**随机重启回 Windows**、来不及拍照，且 U 盘
> `/data`/`sys_prod`/`chip_prod` 全无改动 → 失败在早期且由 panic→reboot 触发。
> 本轮**只改 `make_partition_disk.sh` 里的 grub.cfg 生成**（不碰 `part_init`/内核/源码），
> 让 [2] 失败时**挂住不重启、屏幕保留最后输出**，便于手机拍照取证。

### 8.1 改动（`make_partition_disk.sh` 内 grub.cfg 生成段）

新增变量（放在 `CMDLINE_BASE` 之后，靠内核 `__setup` "后者覆盖"生效）：
```
CMDLINE_FREEZE="panic=-1 nmi_watchdog=0 softlockup_panic=0 ignore_loglevel"
```
- `panic=-1`：panic 后**不重启、死机挂起**，屏幕保留最后一行。
- `nmi_watchdog=0`：关闭 hard-lockup 检测（`kernel/watchdog.c:118` 的
  `hardlockup_panic_setup`，`0` → `watchdog_hardlockup_user_enabled=0`）。
- `softlockup_panic=0`：soft lockup 只告警不 panic（`kernel/watchdog.c:423`）。
- `ignore_loglevel`：无视 loglevel 全量打印到 `console=tty0`。
- **顺序保证覆盖**：两者都是普通 `__setup`（非 early_param），按 cmdline 出现顺序解析、后者生效；
  `CMDLINE_BASE` 里的 `panic=10 softlockup_panic=1 nmi_watchdog=panic,1` 被上面的值覆盖。

菜单（`set default=1`，[2] 变默认；[1][3][4] 文本与参数**完全未变**；`$` 仍写作 `\$`，无 `ttyS0`）：
```
menuentry "[2] DIAGNOSE: verbose + freeze on failure (panic=-1)" {
    linux /boot/bzImage ${CMDLINE_BASE} keep_bootcon loglevel=8 ${CMDLINE_FREEZE} ${CMDLINE_MOUNT}
    initrd /boot/ramdisk_bootmedia.img
}
menuentry "[5] DIAGNOSE SLOW: [2] + initcall_debug (freeze on failure)" {
    linux /boot/bzImage ${CMDLINE_BASE} keep_bootcon loglevel=8 ${CMDLINE_FREEZE} initcall_debug ${CMDLINE_MOUNT}
    initrd /boot/ramdisk_bootmedia.img
}
```
并在组装自检里加了：`default=1`、[2] 标题、`panic=-1`/`nmi_watchdog=0`/`softlockup_panic=0`/
`ignore_loglevel`、[5] `initcall_debug`、且**禁止**出现 `console=ttyS0`。

### 8.2 [2] 实际 cmdline（从镜像 ESP/p1 `mtype ::/boot/grub/grub.cfg` 读回）
```
console=tty0 earlycon=efifb log_buf_len=4M panic=10 softlockup_panic=1 nmi_watchdog=panic,1 \
sysrq_always_enabled=1 firmware_class.path=/system/lib/firmware memmap=1M\$0x7e000000 \
ramoops.mem_address=0x7e000000 ramoops.mem_size=0x100000 ramoops.console_size=0x80000 \
split_lock_detect=off rdinit=/part_init root=/dev/ram0 rw keep_bootcon loglevel=8 \
panic=-1 nmi_watchdog=0 softlockup_panic=0 ignore_loglevel sn=0123456789 hardware=pc_ptl \
ohos.required_mount.system=/dev/block/by-name/system@/usr@ext4@ro,barrier=1@wait,required \
ohos.required_mount.vendor=/dev/block/by-name/vendor@/vendor@ext4@ro,barrier=1@wait,required \
ohos.required_mount.sys_prod=/dev/block/by-name/sys_prod@/sys_prod@ext4@rw,barrier=1@wait,required \
ohos.required_mount.chip_prod=/dev/block/by-name/chip_prod@/chip_prod@ext4@rw,barrier=1@wait,required \
ohos.required_mount.data=/dev/block/by-name/userdata@/data@ext4@nosuid,nodev,noatime,barrier=1,data=ordered,noauto_da_alloc@wait,reservedsize=104857600 \
ohos.boot.hardware=pc_ptl
```

### 8.3 新产物
| 产物 | 路径 | 大小(B) | sha256 |
|---|---|---|---|
| **★ 磁盘镜像** | `media/ohos_part_pc_ptl.img` | **5,522,849,792** | **`4992a004af473b7b13f17c092a0a40a4b39e97e930714f5620729db61cc9b683`** |
| ramdisk | `media/ramdisk_bootmedia.img` | 8,866,111 | `bc87d120646deea3354c7fad133ae784610bf4953120a6c69685c5f3128e17ff` |
| part_init（诊断版） | `media/part_init` | 877,280 | `30b5a9eb4e54c52f3483d33796e7822f26caf8c751e08393ee5668043c9fbc6e`（未变） |
| BUILD_ID | — | — | `20261002-170345-867c3084c066` |

布局、分区大小、`part_init` 与上一版一致（只改了 grub.cfg）。

### 8.4 QEMU 冒烟（OVMF→GRUB→USB 整盘，overlay+writethrough+QMP）
脚本 `smoke_capture.py`（抓图）、`shots_smoke_*.png`（证据）：
- **t=8s**：GRUB 2.14 菜单，`*[2] DIAGNOSE: verbose + freeze on failure (panic=-1)` **默认高亮**
  （见 `shots_smoke_008.png`），15s 倒计时后自动启动 [2]。
- **t=20/35/55s**：纯黑（内核接管 framebuffer 的过渡段，串口无内核日志属预期）。
- **t=90s / t=150s**：**OHOS PC 锁屏**（09:05、10月3日 星期六、壁纸）→ **已到用户态**
  （`shots_smoke_090.png`、`shots_smoke_150.png`）。
- 串口（`smoke2_serial.log`）只到 GRUB 菜单即止（cmdline 为 `console=tty0`，内核日志走屏不走串口）。
- ESP 读回校验：`set default=1`、[2] 标题/冻结参数、[5]、无 `ttyS0` 全部正确。

### 8.5 硬件看门狗排查（支持"冻屏"有效）
`ptl_standard_defconfig` 里 `CONFIG_ITCO_WDT / SP5100_TCO / I6300ESB_WDT` 等**全部未开**，
`CONFIG_WATCHDOG_CORE` 也未开 → 没有会独立触发重启的硬件看门狗；真机此前的"重启"最可能来自
`panic=10`（panic 后 10s 重启）。`panic=-1` 后即不再重启。

### 8.6 遗留 / 注意
1. QEMU 下 `/data` 顶层只出现 `intell_voice/huks_service/.pulse_dir/hvs` 4 个目录，
   **没有** `ohos-log/zzpslog.log`（与上一版 [1] 跑出的完整 `/data` 不同）。但 `[2]` 已进入
   PC 锁屏（SystemUI 在跑），故属 QEMU `pc_ptl` 既有的用户态不完整问题，**与本轮 GRUB 改动无关**；
   真机取证不必依赖 QEMU 的 `/data`。
2. `ignore_loglevel` 会让早期内核日志全量刷到 `tty0`，真机上屏幕会**很花、滚动很快**；这是刻意的，
   便于拍到最后一行。若刷屏过快只想要最后画面，可去掉 `ignore_loglevel` 只留 `panic=-1` 等冻结项。
3. 本轮**只产出镜像文件**，未碰用户 U 盘/内部硬盘/ESP；QEMU 全部用 overlay，交付盘 sha 未变。

---

## 9. 外置 GRUB 配置 + 六组诊断菜单（2026-10-03 晚）

> 目标：① 让 GRUB **配置外置**（`/boot/grub/grub.cfg` 普通文件，Ubuntu 挂 ESP 即可编辑，
> 不必重 dd）；② 加 [1]..[6] 六组诊断菜单（默认 [2] 去掉 ramoops/memmap）；
> ③ 本地 QEMU 判定"内核只认 3GB"是否是我们的 `memmap=` 造成。

### 9.1 GRUB 改成"外置配置"（`grub-mkimage`，不再 `grub-mkstandalone`）

- 旧：`grub-mkstandalone ... "boot/grub/grub.cfg=$GRUB_CFG"` → 菜单**内嵌**进 `BOOTX64.EFI`，
  改参数必须重编重 dd。
- 新（`make_partition_disk.sh` ESP 段）：
  ```sh
  grub-mkimage -O x86_64-efi -o BOOTX64.EFI -p /boot/grub $GRUB_MODULES
  # GRUB_MODULES="part_gpt part_msdos fat ext2 normal linux search search_fs_file
  #               search_label configfile echo test all_video efi_gop font gfxterm
  #               videoinfo video_bochs video_cirrus terminal png jpeg ls cat sleep
  #               halt reboot minicmd"
  ```
  `-p /boot/grub` 是**内嵌 prefix 路径**（不是配置内容）；开机时 GRUB 加载
  `($root)/boot/grub/grub.cfg`，即 ESP 上的**普通文件**。模块已内嵌，外置配置只需执行命令。
- `BOOTX64.EFI` 从旧 standalone 的 **~6.8 MB 降到 856 KB**；脚本自检新增：
  `grep -a 'NoRAMOOPS' BOOTX64.EFI` 必须**不命中**（证明菜单没被内嵌），且
  `mcopy` 读回 ESP `/boot/grub/grub.cfg` 与生成文件 `cmp` 一致。

### 9.2 验证：改 ESP 上的 grub.cfg，菜单确实变（两处独立证据）

1. 小盘快速验证（`grubtest/`）：同一 `BOOTX64.EFI`，先放标题 `EXT-CONFIG-TITLE-A` 引导 →
   串口出现 A 与 `hello from external config A`；`mcopy` 改成 `...-B-EDITED` 后重启 →
   串口变为 B（`ser_test.log`）。
2. **在交付镜像本体上验证**：从 `media/ohos_part_pc_ptl.img` 用 `dd` 抽出 p1（sectors
   2048..1050623）得 `work/esp_from_disk.img`，作为 USB 盘在 OVMF 下引导 →
   串口显示完整 6 条菜单、**默认高亮 `*[2]`**；再对抽出的 p1 `mcopy` 把 [2] 标题改成
   `EDITED-ON-ESP-AFTER-DD-TITLE` 重启 → 串口默认项标题随之改变
   （`work/ser_esp_disk.log`、`work/ser_esp_disk2.log`）。
   → **用户以后在 Ubuntu 上 `mcopy -i <ESP> grub.cfg ::/boot/grub/grub.cfg` 即可改参数，无需重 dd。**

### 9.3 六组菜单（`set default=1` → 默认 [2]；全部含冻结参数，无 `ttyS0`）

所有项都带（任务要求）：
`panic=-1 nmi_watchdog=0 softlockup_panic=0 ignore_loglevel console=tty0 earlycon=efifb
keep_bootcon loglevel=8 rdinit=/part_init root=/dev/ram0 rw firmware_class.path=/system/lib/firmware`
+ 全部 `ohos.required_mount.*` + `log_buf_len=4M sysrq_always_enabled=1 split_lock_detect=off
sn=0123456789 hardware=pc_ptl`。`memmap` 写成 `memmap=1M\$0x7e000000`（`$` 已转义）。

| # | 标题（中/英） | 与 [2] 的差异 |
|---|---|---|
| [1] | BASE baseline: WITH memmap/ramoops | + `memmap=1M$0x7e000000 ramoops.mem_address=0x7e000000 ramoops.mem_size=0x100000 ramoops.console_size=0x80000` |
| **[2]** | **NoRAMOOPS（默认）** | 去掉 memmap/ramoops |
| [3] | NoRAMOOPS + mce=off | + `mce=off` |
| [4] | NoRAMOOPS + pci=noaer ghes.disable=1 | + `pci=noaer ghes.disable=1` |
| [5] | NoRAMOOPS + mce=off + pci=noaer ghes.disable=1 | + `mce=off pci=noaer ghes.disable=1` |
| [6] | NoRAMOOPS + initcall_debug (SLOW) | + `initcall_debug` |

### 9.4 QEMU 内存实验：**memmap 不是"只认 3GB"的原因**

`-m 4096`，同一 `bzImage`，仅改 `-append`（`grubtest/memexp.sh`）：

| cmdline | `Memory: X/Y available` | reserved |
|---|---|---|
| **[1] 含** `memmap=1M$0x7e000000 ramoops...` | `3972980K / 4192756K` | 215468K |
| **[2] 去掉** memmap/ramoops | `3974000K / 4193780K` | 215476K |

- **差值 = 1020K（≈1.0 MB）**，即 `memmap=1M` 精确只挖掉 1 MiB 的 0x7e000000 保留区；
  **不会**造成数量级的内存缩水。
- **GRUB 传参正确性**：用 OVMF→GRUB→USB（外置配置，`console=ttyS0` 临时）实测内核收到
  `Kernel command line: ... memmap=1M$0x7e000000 ...`（`$` **未被 GRUB 展开**，见
  `grubtest/ser_test.log`）。所以真机内存行里的 `$` 也是正确传入的。
- **结论**：真机 `Memory: 2276644K/3099048K available`（≈3.0 GB）与我们的 cmdline
  **无关**（memmap 只占 1 MB）。这更像是**固件 e820 / 内核早期内存上报**层面的问题
  （例如 4G 以上内存条未被正确枚举、`mem_encrypt`/内存类型、或该 defconfig 的内存模型），
  需要真机用 [1]/[2] 对照并配合 `e820`/`dmesg` 进一步定位；本任务的 QEMU 实验已排除
  "我们的参数吞内存"。

### 9.5 新产物

| 产物 | 路径 | 大小(B) | sha256 |
|---|---|---|---|
| **★ 磁盘镜像** | `media/ohos_part_pc_ptl.img` | **5,522,849,792** | **`96db48a076e25e2fcb5c7ad48617eab8f5eb1515963b4be341dab9ae7d4f9658`** |
| BOOTX64.EFI（外置配置 GRUB2.14） | `media/work/BOOTX64.EFI` | 856,064 | （见 `media/work/`） |
| ramdisk（stock init + part_init + firmware） | `media/ramdisk_bootmedia.img` | 8,866,107 | `d4fa2a9a5d53963079fe89a35d95926da543bea5e7f95b6aef8165428854be87` |
| part_init（诊断版，未变） | `media/part_init` | 877,280 | `30b5a9eb4e54c52f3483d33796e7822f26caf8c751e08393ee5668043c9fbc6e` |
| BUILD_ID | — | — | `20261003-023622-80b55d1f011c` |

布局、分区大小、`part_init` 与上一版一致（只改了 GRUB 配置方式 + grub.cfg）。

### 9.6 QEMU 冒烟（OVMF→GRUB→USB 整盘，新镜像）

- `smoke_capture.py`（OVMF + usb-storage + QMP 截图，overlay）：
  - 串口 t≈8s 显示 **6 条菜单、默认 `*[2]`**；15s 后自动启动 [2]。
  - `screendump`：t=20s 黑（内核接管 framebuffer 过渡）；**t=90s / t=150s 为
    OHOS PC 锁屏**（1280x800，>7100 种颜色，0% 黑）→ **整盘已引导到用户态**。
    证据 `shots_smoke_090.ppm`、`shots_smoke_150.ppm`。
- 自检（脚本内）：外置配置未内嵌、ESP grub.cfg 读回一致、[1] 含 ramoops / [2] 不含、
  `default=1`、冻结参数齐全、无 `ttyS0`。
- 抽出的 p1 ESP 单独 OVMF 引导：默认 [2]，编辑标题后重启生效（§9.2）。

### 9.7 用法 / 回退

- 改参数：`mcopy -o -i <ESP分区设备或p1镜像> new_grub.cfg ::/boot/grub/grub.cfg`
  （ESP 是 FAT32，也可直接挂载 `sudo mount /dev/sdX1 /mnt/esp` 后编辑
  `/mnt/esp/boot/grub/grub.cfg`）。**改完无需重 dd 磁盘。**
- 回退到内嵌配置：把 `make_partition_disk.sh` 的 `grub-mkimage` 段换回原来的
  `grub-mkstandalone` 并重新构建（旧 BOOTX 仍在 `media/_bx.efi` 可参考）。
- 本轮**只产出镜像文件**，未碰用户 U 盘/内部硬盘/ESP；QEMU 全部用 overlay。

### 9.8 遗留

1. 真机"只认 3GB"仍需真机 `dmesg`/e820 取证（[1] vs [2] 对照）；已排除 memmap（§9.4）。
2. `panic=-1`、`mce=off`、`pci=noaer ghes.disable=1` 等能否绕过真机
   `[Hardware Error]: Machine check events logged` 后定屏，需真机用 [3]/[4]/[5] 验证。
3. QEMU `pc_ptl` 用户态本身不完整（与磁盘无关），真机取证不依赖 QEMU 的 `/data`。

---

## 10. `/data` = tmpfs（内存盘）模式：排除 USB 存储挂死（2026-10-04）

> 目标：真机上让 **`/data` 不落在 USB 盘**，以排除 OHOS 运行时海量读写把 `usb-storage`
> 打进 D 状态（真机现象：`usb_stor_block_transfer_sglist` D 状态、写 `/data` 全阻塞、
> `SA:3901`(param_watcher) 起不来）。本轮用 **`/data`=tmpfs** 做最快验证，**不重编内核/OHOS**。
> 新增 GRUB 菜单 **[D] DATA=tmpfs**；默认仍是 **[2]**。

### 10.1 一句话结论

- 新交付镜像：**`media/ohos_part_pc_ptl.img`，5,522,849,792 B，
  sha256 `9eb575e2073ffdd93622abfa07ca2c9826942219342da4ce05d2ed1aa7044c15`**
  （BUILD_ID `20261003-165816-1e6be4dd5c4c`）。
- **[D] 引导后 `/data` 确实是 `tmpfs`**（`size=2097152k,mode=771`），**不涉及 USB 写**；
  真实 userdata（p6）只被挂到 `/ohoslog` 当日志盘。
- **tmpfs 下仍能取到日志**：`zzpslog.log`/dmesg 尾段每 30s 同步到 **p6 `/ohoslog/ptl-log/`**，
  重启/拔盘后可在 Ubuntu 直接读。QEMU 端到端 150s、心跳到 122s，日志齐全。
- 200MiB 写 `/data` 压测：**`bytes=209715200, t0=3.11s → t1=3.29s`（≈0.18s，~1.1GB/s，纯内存）**。

### 10.2 先搞清 init 怎么挂 `/data`（结论 + 依据）

| 问题 | 结论 | 依据（文件:行） |
|---|---|---|
| `ohos.required_mount.*` 语法 | `<dev>@<mnt>@<fstype>@<mntopts>@<fs_mgr flags>`，按 `@` 拆 5 段 | `base/startup/init/interfaces/innerkits/fs_manager/fstab.c:518-551` |
| 为什么原 data token「没生效」 | token 里只有 `wait,reservedsize=…`，**没有 `required`** → 第一阶段 required 遍**跳过** | `fstab.c:50-82`（只识别 `required` 等）；`fstab_mount.c:1037-1055`（`FM_MANAGER_REQUIRED_ENABLED` 才挂） |
| 那原镜像 `/data` 是谁挂的 | 是 **pre-init 的 `mount_fstab_sp /vendor/etc/fstab.${hardware}`**（required=0 遍），vendor fstab 里有 `/data` 行 | `base/startup/init/services/etc/init.cfg:16`；`init_cmds.c:356-361`；`fstab_mount.c:1045-1051` |
| tmpfs 能否写进 required_mount | **不能**。`MountOneItem` 只认 `{ext4,f2fs,overlay}`，其他类型直接返回 0 **不挂载** | `fstab_mount.c:98-103,130-137,934-937` |
| `/data` 目录谁建、权限 | mount 点由 `Mount()` `mkdir(0755)` 建；随后第二级 init `chown system system /data` + `chmod 0771 /data` | `fstab_mount.c:484-485`；`services/etc/init.cfg:15,17-19` |
| `reservedsize` | **init 不解析**（`ConvertFlags` 只认 8 个名字，未知项忽略），下面提到仅为保持原 token 语义 | `fstab.c:52-65` |
| switch_root 会搬走挂载点 | `MountToNewTarget()` 把 `/`、`/usr`、`/dev|/sys|/proc` 之外的挂载逐个 `MS_MOVE` 到 `新根+挂载点`（故 `/data`→`/usr/data`、`/ohoslog`→`/usr/ohoslog`；目标目录必须在 system 分区存在） | `interfaces/innerkits/fs_manager/switch_root/switch_root.c:94-131` |

**据此实现方式（选 (a)，理由：tmpfs 不在 init 支持列表，只有 part_init 自己能挂）：**
- `part_init` 在 `exec /init` 前，若 `/proc/cmdline` 含标记 **`ptl.data=tmpfs`**：
  `mount("tmpfs","/data","tmpfs",MS_NOSUID|MS_NODEV,"mode=0771,size=2G")`；
  并 `mount("/dev/block/by-name/userdata","/ohoslog","ext4",…)`（日志盘）。
- `system.img` 根**预建 `/ohoslog`**（switch_root 搬移目标）；`/data` 目录 system 分区本就有。
- **vendor fstab 去掉 `/data` 行**（`/vendor/etc/fstab.pc_ptl`），否则 pre-init
  `mount_fstab_sp` 会把真 USB userdata(ext4) 重新盖到 tmpfs 上（并跑 `resize2fs`/`e2fsck`）。
- **补偿**：把 [1]..[6] 的 cmdline data token 改成 **`wait,required,reservedsize=…`**，
  让它们改由**第一阶段**用 cmdline 挂 `/data`（实测 t=2.18s 挂载成功；失败也不会 abort）。

> 本轮多花时间定位的坑：仅把 data token 从 cmdline 删掉、vendor fstab 那行删掉后，
> **`[2]` 会完全没有 `/data`**（422 次 `mkdir /data... failed err=2`）→ critical 服务
> `param_watcher`(SA 3901) 反复退出 4 次 → `ExecReboot panic`。
> 这正是 `required` 补偿要解决的；也是任务想验证的 **SA:3901 依赖可写 `/data`** 的现场证据。

### 10.3 system.img / vendor.img 的改动（都由脚本产出，可回退）

| 分区 | 改动 | 说明 |
|---|---|---|
| p2 `system.img` | `/system/lib/modules/load_order.txt` **删除 `i915.ko`** | 真机 GPU 走 `xe`（真实机实测删 i915 后 GPU 成功） |
| p2 `system.img` | 新增目录 `/ohoslog` | switch_root 后日志盘挂载点 |
| p2 `system.img` | 新增 `/system/bin/zz_ptllog.sh`（0755）+ `/system/etc/init/zz_ptllog.cfg`（0644） | start-mode=boot；仅当 `/data` 是 tmpfs 且 `/ohoslog` 已挂载才工作，否则空转（避免反复重启） |
| p3 `vendor.img` | `/etc/fstab.pc_ptl` **删除 `userdata /data` 行** | 防 pre-init 把真 USB `/data` 盖上 tmpfs |
| p1 `ESP` | `grub.cfg` 增 **[D]** 项；[1]..[6] data token 加 `required` | [D] 含 `ptl.data=tmpfs`，**不含** `ohos.required_mount.data` |

脚本/素材：`partdisk/tmpfs/`（`prep_tmpfs_edits.sh` 打镜像补丁、`part_init.c` 改动在
`partdisk/part_init.c`、`zz_ptllog.sh`、`load_order.txt.no_i915`、`fstab.pc_ptl.nodata`、
Stage A/B 运行脚本 `run_tmpfs_stageA.sh` / `qemu_ovmf.py`）。
构建时用 `IMAGES=partdisk/tmpfs_images`（system/vendor 为打过补丁的副本，其余硬链接原图），
原 `out/ptl/.../images/{system,vendor}.img` **未被修改**。

### 10.4 日志落点（tmpfs 下也必须能取到日志）

- `part_init` 挂好 `/ohoslog` 后立刻写：`/ohoslog/ptl-log/{part_init.txt,dmesg.boot.log}`（内核早期日志）。
- `/system/bin/zz_ptllog.sh` 每 30s：把 `/data/ohos-log/zzpslog.log` 拷到
  `/ohoslog/ptl-log/zzpslog.log`，`dmesg | tail -500` → `dmesg.tail.log`，并追加 `heartbeat.log`。
- 一次性写 `/ohoslog/ptl-log/mounts.txt`（含完整 `/proc/mounts`、`mount`、`df`）——**证明 `/data` 是 tmpfs**。
- 压测（仅测试用）：cmdline 加 `ptl.datatest=200m` 时写 200MiB 到 `/data` 并把
  `DATA200M OK bytes=… t0=… t1=…` 记到 `/ohoslog/ptl-log/datatest.txt`（**交付镜像的 [D] 菜单不含此标记**）。

### 10.5 QEMU 验证（单实例、overlay、未改交付盘）

- **Stage A（`-kernel/-initrd` + [D] cmdline + `console=ttyS0`）**，串口证据
  `tmpfs/stageA_tmpfs_serial.log`：
  ```
  part_init: DATA_TMPFS: tmpfs mounted on /data (mode=0771,size=2G)
  part_init: DATA_TMPFS: mounted /dev/block/by-name/userdata on /ohoslog (persistent log store)
  [BEGET] Mount /dev/block/by-name/system to /usr successful   ← 没有挂 /data
  DATA200M OK bytes=209715200 t0=3.11 t1=3.29
  ```
  跑到 169s、`ZZPSLOG SNAP=42`、SystemUI 活跃，**无 usb-storage D 状态**。
  p6 读回 `/ptl-log/{mounts.txt,zzpslog.log,dmesg.*,heartbeat.log,datatest.txt}` 齐全；
  `mounts.txt` 明确：`tmpfs /data tmpfs …size=2097152k,mode=771` + `/dev/block/by-name/userdata /ohoslog ext4`。
- **Stage B（OVMF→GRUB→USB 整盘）**：临时把 ESP 的 `set default` 指向 [D]（跑完已还原），
  串口确认高亮 `*[D]` 并自动启动；`screendump` t=35..150s 为 6.8–6.9 万色真实 UI
  （`tmpfs/stageD2_150.png` 等）；overlay 的 p6 `/ptl-log/` 心跳到 uptime 122s。
- **回归**：最终盘默认 [2] 仍正常——第一阶段 t=2.18s 挂 `/data`、无 `critical service crashed`、
  无 panic、`ZZPSLOG SNAP=14`（`tmpfs/final2_serial.log`）。
- 证据小文件：`tmpfs/evidence/A_mounts.txt`、`A_part_init.txt`、`A_heartbeat.log`；
  截图 `tmpfs/stageD2_*.png`；overlay `work/tmpfsD2_overlay.qcow2`（45MB，可再切 p6）。

### 10.6 新产物

| 产物 | 路径 | 大小(B) | sha256 |
|---|---|---|---|
| **★ 磁盘镜像** | `media/ohos_part_pc_ptl.img` | **5,522,849,792** | **`9eb575e2073ffdd93622abfa07ca2c9826942219342da4ce05d2ed1aa7044c15`** |
| ramdisk（stock init + 新 part_init + firmware） | `media/ramdisk_bootmedia.img` | 8,867,187 | `d619a18fed5cc640bce3c98bb0967730e31ccccfd03f68205ec9e41f858ac5b2` |
| part_init（新增 tmpfs/日志盘逻辑） | `media/part_init` | 877,328 | `0af58f5d52a50361fbc50acac8fdb84de3ac5f048b5ee75b8e2d85ca680c4a69` |
| 上一版基线（rollback） | `media/ohos_part_pc_ptl.prev.img` | 5,522,849,792 | `96db48a076e25e2fcb5c7ad48617eab8f5eb1515963b4be341dab9ae7d4f9658` |
| BUILD_ID | — | — | `20261003-165816-1e6be4dd5c4c` |

### 10.7 上机步骤

> 本次 **p2/p3/p1 都改了**，所以必须**整盘重 dd**（只改 ESP grub.cfg 不够）。
> dd 之后，[D] 之外的参数仍可只改 ESP 上的 `grub.cfg`。
```sh
IMG=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/partdisk/media/ohos_part_pc_ptl.img
sudo dd if="$IMG" of=/dev/sdX bs=16M status=progress conv=fsync && sudo sync
sudo sgdisk -e /dev/sdX && sudo partprobe /dev/sdX     # 镜像 5.1GiB，挪备份 GPT 到盘尾
```
引导：关 Secure Boot → 选 `UEFI: <U盘>` → GRUB 里选 **[D] DATA=tmpfs**（15s 倒计时默认 [2]，
按 ↓ 五次到 [D] 或直接改 ESP grub.cfg 的 `set default=6`）。

在 Ubuntu 读日志（p6 的真实文件系统根下就是 `ptl-log/`，不是 `/data/ptl-log`）：
```sh
sudo mount /dev/sdX6 /mnt/od
sudo ls -l /mnt/od/ptl-log
sudo head -60 /mnt/od/ptl-log/mounts.txt        # 看 /data 是否 tmpfs
sudo tail -n 40 /mnt/od/ptl-log/zzpslog.log
sudo umount /mnt/od
```

### 10.8 回退

- **回到 [2] 基线（保留 [D]）**：不用动，默认就是 [2]；或把 ESP grub.cfg `set default=1`。
- **回到上一版交付镜像**：`sudo dd if=media/ohos_part_pc_ptl.prev.img of=/dev/sdX …`
  （sha `96db48a0…`）。
- **原图未变**：`out/ptl/packages/phone/images/{system,vendor}.img` 未改；补丁只在
  `partdisk/tmpfs_images/`（可 `rm` 后由 `tmpfs/prep_tmpfs_edits.sh` 重建）。
- 仓库源码**零改动**（只改了本目录脚本与 `part_init.c`，未碰 `base/`、内核、OHOS）。

### 10.9 遗留 / 注意

1. **`/data` 是 tmpfs ⇒ 重启即丢**（正常现象）；持久证据只靠 p6 `/ohoslog/ptl-log/`。
2. QEMU 下 `pc_ptl` 用户态本就不完整（`bootevent.bms.main.bundles.ready not set`）；本轮 [2]/[D]
   都跑到深用户态（SNAP 14~42），真机结论需上机取 [D] 的 p6 日志。
3. **i915 去留**：本轮按「真机删 i915 后 GPU 成功」的基线，从 `/system/lib/modules/load_order.txt`
   删除了 `i915.ko`（QEMU 无碍）。若要恢复，把 `tmpfs/load_order.txt.no_i915` 换回含 i915 的版本重打。
4. tmpfs 上限写死 `size=2G`（QEMU/真机 `MemTotal` 约 3.8–4GB）；如需可在 `part_init.c`
   的 `setup_tmpfs_data_and_logstore()` 改，重编 `part_init`（`make_partition_disk.sh` 自动）即可。
