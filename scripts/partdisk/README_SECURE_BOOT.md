# UEFI Secure Boot 支持（pc_ptl U 盘镜像）

> 本文件描述 `out/x86_64_virt/ohos-dbg/partdisk/make_partition_disk.sh` 生成的 U 盘镜像
> 在 **UEFI Secure Boot 开启**下的启动方式。
> Secure Boot 是**默认路径**（`SECURE_BOOT=1`）；旧的未签名布局仍可用
> `SECURE_BOOT=0` 复现（见文末「退回未签名路径」）。
>
> **当前状态（2026-10-20）**：MOK-only（只登记 MOK、**不动 BIOS 的 db**）已经
> **端到端验证通过**：OVMF Secure Boot + MOK-only → 内核启动 → part_init 找到
> 5/5 分区 → OHOS init 进用户态。
> 证据：`out/x86_64_virt/ohos-dbg/fix_secure_boot2/SUMMARY.md`。

---

## 0. 先读这一段：Secure Boot 下谁验谁

| 被加载的东西 | 谁验 | 需要我们的证书在哪 |
|---|---|---|
| `::/EFI/BOOT/BOOTX64.EFI`（**shim**，微软签） | **固件**（固件 db 里的微软 CA） | 不需要（微软签的） |
| `::/EFI/BOOT/grubx64.efi`（**GRUB**，我们签） | **shim** | 我们的证书在 **MOK** 里 |
| `::/boot/bzImage`（**内核**，我们签） | **shim**（GRUB 用 shim 的 legacy `shim_lock` 协议验证，然后**由 GRUB 自己**装载） | 我们的证书在 **MOK** 里 |

**关键点（这一版和上一版不同）**：内核**不再由固件装载**。

- 上一版用的是 Ubuntu 官方 GRUB 2.14。Ubuntu 给它打了
  `debian/patches/secure-boot/disable-efi-fallback-to-legacy.patch`，
  删掉了 GRUB 上游的 **legacy `shim_lock` 回退分支**。
  于是 GRUB 只能请**固件** `LoadImage` 内核 → 固件只认 db → MOK-only 必然失败：
  `error: cannot load image.`
- 现在用的是**我们自己从上游源码构建的 GRUB 2.14**（`device/pc/ptl/grub/`），
  保留了该回退分支：GRUB 走 `grub_cmd_linux_x86_legacy()`（EFI handover），
  **自己把内核装载进去**，固件全程不参与内核装载。
  → **固件 db 里不需要我们的证书，只要 MOK 登记一次即可。**

> 也就是说：**不需要动 BIOS 的 db**（不需要 OEM 配合），这是本次改动的主要价值。

## 1. 信任链（当前版本）

```
固件 db（微软 UEFI CA 2011，机器自带）
   └─> ::/EFI/BOOT/BOOTX64.EFI   = shimx64.efi（微软签名）
          └─> MOK（我们自己的证书，mokutil 登记一次）
                └─> ::/EFI/BOOT/grubx64.efi = 自建 GRUB 2.14（我们签）
                      └─> ::/boot/bzImage    = 内核（我们签）
                          ↑ 仍由 shim 用 MOK 验证（legacy shim_lock 协议），
                            但装载动作是 GRUB 自己做的（EFI handover），
                            固件不参与 ⇒ 固件 db 无需我们的证书
```

> 备选链路（把证书也放进固件 db）：任何发行版 GRUB 都能用，
> 但需要 OEM/BIOS 支持，**我们不再需要**。

## 2. 密钥

| 文件 | 说明 |
|---|---|
| `partdisk/sb_keys/ohos-uefi.key` | RSA2048 私钥（权限 600） |
| `partdisk/sb_keys/ohos-uefi.crt` | 证书（PEM） |
| `partdisk/sb_keys/ohos-uefi.cer` | 证书（DER，`mokutil --import` 用这个） |
| `partdisk/sb_keys/ohos-uefi.pub` | 公钥 |

由 `partdisk/gen_sb_keys.sh` 生成，**幂等**：已存在则不覆盖。
证书带 `CA:TRUE` + `codeSigning` EKU（既当 MOK 信任锚，又当签名者）。

## 3. 登记步骤（真机）——**只需要 MOK**

### 3.1 登记进 MOK（唯一需要用户做的固件交互）

在装了 Ubuntu 的机器（宿主机）上：

```sh
sudo mokutil --import /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/partdisk/sb_keys/ohos-uefi.cer
```

- 会要求设置一个**一次性密码（MOK enrollment password）**，记住它。
- **必须重启**；重启时固件进 MokManager，选
  **Enroll MOK → Yes → 输入刚才的密码 → Reboot**。
- 确认：`mokutil --list-enrolled | grep -A2 OpenHarmony`。

### 3.2 **不需要**登记进固件 db

旧版本要求把证书也加进 BIOS 的 db（Secure Boot → Certificate Management /
Add CA / Enroll Certificate），**这一步现在不需要了**，请不要去做：
自建 GRUB 会自己装载内核，固件 db 只用来信任微软签的 shim。

> 如果你的机器的 shim 实现了 `SHIM_IMAGE_LOADER_GUID`（shim ≥ 16 风格），
> 发行版 GRUB 也能直接工作（GRUB 会让 shim 装载内核），自建 GRUB 就不必要；
> 但目前没有微软签名的 shim 16，所以自建 GRUB 仍是必需。

## 4. 镜像里的 ESP 布局

```
::/EFI/BOOT/BOOTX64.EFI     shim（微软签）
::/EFI/BOOT/grubx64.efi     自建 GRUB 2.14（我们签）
::/EFI/BOOT/mmx64.efi       MokManager（微软签，用于 MOK 登记）
::/EFI/ubuntu/grubx64.efi   GRUB 的 fallback 副本（我们签）
::/boot/bzImage             内核（我们签）
::/boot/ramdisk_bootmedia.img
::/boot/grub/grub.cfg       外置菜单（不在 EFI 二进制里）
::/ohos_build_id
```

构建时脚本会对 shim / grubx64.efi / bzImage 逐个 `sbverify --list`，
并把 ESP 上的文件再取回来复验一遍；任一失败即 `exit 1`（日志：`partdisk/media/sbverify.log`）。

## 5. 自建 GRUB（`device/pc/ptl/grub/`）

| 文件 | 说明 |
|---|---|
| `device/pc/ptl/grub/build_grub.sh` | 构建脚本：拉上游 2.14 → 打补丁 → `grub-mkimage -s` → `sbsign` |
| `device/pc/ptl/grub/patches/0001-efi-keep-legacy-shim-lock-loader.patch` | 保留 legacy `shim_lock` 内核装载回退（+ `ohos_force_legacy_loader` 开关） |
| `device/pc/ptl/grub/patches/0002-kern-dl-keep-module-memory-writable.patch` | 修 GRUB 2.14 的 `.bss` 只读 bug（否则 legacy handover 路径 `#PF`） |
| `device/pc/ptl/grub/grub.sbat` | GRUB 的 `.sbat` 元数据（`grub,100,OpenHarmony GRUB,...`） |

产物落在 `out/x86_64_virt/ohos-dbg/partdisk/grub/dist/`：

```
grubx64.efi          裸 GRUB core（含 .sbat 段）
grubx64.efi.signed   用 MOK 证书签过的（真正放进 ESP 的就是这个）
build_info.txt       版本 / 补丁 / sha256
```

`make_partition_disk.sh` 默认 `GRUB_SOURCE=ours`（用这份自建 GRUB）；
`GRUB_SOURCE=system` 可以退回宿主机的 `grub-mkimage`（仅用于对比，**不要**用于 Secure Boot）。

## 6. SBAT（必须做，否则 shim 一定拒绝）

shim ≥ 15.x（例如 Ubuntu 的 shim 15.8）**强制要求**它加载的每一个 EFI 镜像带
`.sbat` PE 段，否则直接 `EFI_SECURITY_VIOLATION`：

```
pe.c:348:verify_sbat_section() No .sbat section data
```

因此本工程做了两处配套改动：

| 对象 | 做法 |
|---|---|
| GRUB | `grub-mkimage -s device/pc/ptl/grub/grub.sbat`（自建 GRUB 的构建脚本里） |
| 内核 | `CONFIG_EFI_SBAT_FILE="arch/x86/boot/compressed/ohos.sbat"`（`kernel/linux/linux-7.2`） |

`.sbat` 内容（6 列 CSV，见 shim `SBAT.md`）：

```
sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
grub,100,OpenHarmony GRUB,grub,1,https://www.ohos.org/
linux,100,OpenHarmony Linux,linux,1,https://www.ohos.org/
```

generation 取 **100**：shim 的规则是
`组件自身 generation < 固件 sbat 变量里的 generation → 视为被吊销`，
取足够大的值可保证不被现有/将来常见的吊销列表命中。

## 7. 启动

把 `partdisk/media/ohos_part_pc_ptl.img` dd 到 U 盘（**≥ 19.2 GiB**，建议 32 GB），
写完跑 `sgdisk -e` 把备份 GPT 放到盘尾（`partdisk/dd_and_verify.sh` 会做）。

插上 → 固件 → shim → 自建 GRUB（2 秒超时，自动进默认项
“OpenHarmony PC (persistent /data)”）→ 内核 → part_init → init。

**注意**：
- Secure Boot 下固件**只**认 `::/EFI/BOOT/BOOTX64.EFI` 这条 removable-media 路径，
  所以 ESP 上必须放 shim（不能直接把 GRUB 放 BOOTX64.EFI）。
- `::/EFI/ubuntu/grubx64.efi` 是 shim 编译进去的 fallback 路径，必须一起放。
- 内核模块不需要签名：内核 `CONFIG_MODULE_SIG` 未启用，`.ko` 不用签。
- **画面**：MOK-only 走的是 GRUB 的 legacy EFI handover，**不会**像内核 EFI stub
  那样调用 GOP 设模式，所以开机最初几秒屏幕上没有内核日志（黑屏或低分辨率）；
  真正的面板模式由内核里的 Intel **xe** 驱动设置，桌面照常显示。
  判据与排查见 `fix_secure_boot2/SUMMARY.md`「显示模式」一节。

## 8. 退回未签名路径

固件拒绝 MOK、或者不想折腾固件交互时：

```sh
cd /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/partdisk
SECURE_BOOT=0 ESP_ONLY=1 bash make_partition_disk.sh
```

`SECURE_BOOT=0` 会重新生成**未签名**的 ESP（`::/EFI/BOOT/BOOTX64.EFI` = 裸 GRUB，
内核不签名），其它分区不动（ESP 布局保持旧的单加载器布局）。
写盘前请先备份 p1：

```sh
dd if=media/ohos_part_pc_ptl.img of=p1_backup.img bs=512 skip=2048 count=1048576
zstd -19 p1_backup.img -o p1_backup.img.zst
```

## 9. 相关文件

| 路径 | 说明 |
|---|---|
| `partdisk/gen_sb_keys.sh` | 生成 UEFI Secure Boot 密钥（幂等） |
| `partdisk/make_partition_disk.sh` | 磁盘镜像构建（`SECURE_BOOT=1` 为默认，`GRUB_SOURCE=ours` 用自建 GRUB） |
| `partdisk/media/sbverify.log` | 构建期验签日志 |
| `partdisk/media/FINAL_SUMMARY.txt` | 构建摘要（含新镜像 sha256、MOK 登记命令） |
| `device/pc/ptl/grub/` | **自建 GRUB 的源码配方**（补丁 + 构建脚本 + sbat） |
| `out/x86_64_virt/ohos-dbg/partdisk/grub/` | 自建 GRUB 的构建工作区与产物 |
| `out/x86_64_virt/ohos-dbg/fix_secure_boot/SUMMARY.md` | 上一版（发行版 GRUB）实施报告 |
| `out/x86_64_virt/ohos-dbg/fix_secure_boot_bisect/SUMMARY.md` | 根因定位报告（Ubuntu 补丁 = 真凶） |
| `out/x86_64_virt/ohos-dbg/fix_secure_boot2/SUMMARY.md` | **本次（自建 GRUB 固化 + MOK-only 端到端验证）报告** |
