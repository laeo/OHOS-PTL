# 自建 GRUB 2.14（pc_ptl 引导器配方）

这个目录是 **pc_ptl U 盘镜像的引导器（GRUB）配方**：从**上游 GRUB 2.14 源码**
构建一个只服务于 OpenHarmony PC 的 GRUB core，打上两个补丁、嵌入 `.sbat` 段，
再用工程的 **MOK 证书**签名。

产物由 `out/x86_64_virt/ohos-dbg/partdisk/make_partition_disk.sh` 自动取用
（`GRUB_SOURCE=ours`，默认）。

---

## 1. 为什么必须自建（而不是用发行版 GRUB）

Ubuntu / Debian 的 GRUB 2.14 打了这个补丁：

```
debian/patches/secure-boot/disable-efi-fallback-to-legacy.patch
Subject: Disable fallback to legacy mode if shim is loaded on x86 archs
--- grub-core/loader/efi/linux.c
-  if (grub_is_using_legacy_shim_lock_protocol () == true)
-    { err = grub_cmd_linux_x86_legacy (cmd, argc, argv); ... }
```

后果（在 Secure Boot + **MOK-only**，即固件 db 里没有我们证书的情况下）：

1. GRUB 打开内核文件 → 触发 shim 的 legacy `shim_lock` 验证协议 → shim 用
   **MokListRT** 验签 → **成功**；
2. 但 legacy `shim_lock` **只验签、不装载**，GRUB 拿不到「已验证的镜像句柄」；
3. GRUB 于是退回 `grub_efi_load_image()` → **由固件 LoadImage** → 固件只认 db →
   我们的证书不在 db → `EFI_SECURITY_VIOLATION` →
   **`error: cannot load image.`**

上游 GRUB 2.14 保留了这个回退分支：`grub_cmd_linux_x86_legacy()`（EFI handover）
让 **GRUB 自己**装载内核，固件全程不参与 ⇒ **固件 db 里不需要我们的证书**。

完整根因分析见 `out/x86_64_virt/ohos-dbg/fix_secure_boot_bisect/SUMMARY.md`。

## 2. 目录内容

| 文件 | 说明 |
|---|---|
| `build_grub.sh` | 构建脚本（下载 → 打补丁 → configure/make → `grub-mkimage -s` → `sbsign`） |
| `patches/0001-efi-keep-legacy-shim-lock-loader.patch` | ① 保留/强化 legacy `shim_lock` 内核装载回退，并加 `ohos_force_legacy_loader=1` 开关 |
| `patches/0002-kern-dl-keep-module-memory-writable.patch` | ② 修 GRUB 2.14 的 `.bss` 只读 bug（否则 legacy x86-64 handover 路径 `#PF` 崩溃） |
| `grub.sbat` | ③ `.sbat` 元数据（shim ≥ 15 强制要求第二阶段带 `.sbat` PE 段） |

### ① legacy shim_lock 回退

上游 2.14 的 `grub-core/loader/efi/linux.c` 已经有：

```c
  if (grub_is_using_legacy_shim_lock_protocol () == true)
    {
#if defined(__i386__) || defined(__x86_64__)
      err = grub_cmd_linux_x86_legacy (cmd, argc, argv);   /* GRUB 自己引导内核 */
```

我们**从上游源码构建**（不套 Debian 补丁集）⇒ 这段回退天然存在。
补丁 0001 做两件事：
* 把这段逻辑连同注释显式保留下来（防止以后有人再套 Debian 补丁）；
* 增加一个逃生开关 `set ohos_force_legacy_loader=1`（写进 `grub.cfg`），
  即使 shim 实现了新的 `SHIM_IMAGE_LOADER_GUID`（shim ≥ 16）也能强制走
  「GRUB 自己装载内核」的路径。

### ② `.bss` 只读 bug

GRUB 2.14 的 `grub_dl_set_mem_attrs()` 按 ELF section 给模块设置内存属性，
但只处理**能匹配到 GRUB DL segment** 的 section；`.bss` 匹配不到 → 保持固件给的
**只读**属性。relocator 模块把启动状态（`grub_relocator64_rax` 等）放在 `.bss`，
一写就 `#PF`（page present, write），legacy x86-64 handover 路径在进内核之前就死：

```
!!!! X64 Exception Type - 0E(#PF - Page-Fault) !!!!
ExceptionData - 0000000000000003  I:0 R:0 U:0 W:1 P:1
```

补丁 0002 让 `grub_dl_set_mem_attrs()` 直接返回（保持模块内存可写）。
本 GRUB 只用于引导 OpenHarmony，不存在安全顾虑。

### ③ `.sbat` 段

shim ≥ 15（Ubuntu 的 shim 15.8）拒绝加载**没有** `.sbat` PE 段的第二阶段：

```
pe.c:348:verify_sbat_section() No .sbat section data   -> EFI_SECURITY_VIOLATION
```

`grub.sbat`（6 列 CSV）：

```
sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
grub,100,OpenHarmony GRUB,grub,1,https://www.ohos.org/
```

generation 取 100：shim 的规则是「组件自身 generation < 固件 sbat 变量里的
generation ⇒ 视为被吊销」，取足够大的值可避免被常见吊销列表命中。

## 3. 构建

```sh
bash device/pc/ptl/grub/build_grub.sh
```

工作区（默认）/产物：

```
out/x86_64_virt/ohos-dbg/partdisk/grub/
├── grub2_2.14.orig.tar.xz     上游源码包（sha256 bc8d3c73…）
├── src/grub-2.14/             解压 + 打补丁 + 构建树
├── logs/                      configure.log / make.log / patch.log / mkimage.log
└── dist/
    ├── grubx64.efi             裸 GRUB core（含 .sbat 段）
    ├── grubx64.efi.signed      用 MOK 证书签过（放进 ESP 的就是这个）
    ├── grub.sbat
    └── build_info.txt         版本 / 补丁列表 / sha256
```

环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `GRUB_WORK` | `out/.../partdisk/grub` | 工作区 |
| `JOBS` | `min(nproc,8)` | make 并行度 |
| `SB_KEYS_DIR` | `out/.../partdisk/sb_keys` | MOK 密钥目录 |
| `GRUB_TARBALL_URL` | launchpad 上的 2.14 原始包 | 换源用 |
| `SKIP_BUILD=1` | – | 复用 `dist/` 里已有产物 |

构建脚本会**校验**三件事，任何一条不满足即失败：

1. 上游 tarball 的 sha256；
2. `linux.c` 里 legacy `shim_lock` 回退**确实在**（防止误用 Debian 补丁过的源码）；
3. `kern/dl.c` 里的 `.bss` 可写修复**确实在**；
4. 产出的 core 确实带 `.sbat` 段（`objdump -h`）。

## 4. 与交付管线的关系

`out/x86_64_virt/ohos-dbg/partdisk/make_partition_disk.sh`：

* `SECURE_BOOT=1`（默认）→ 用 `dist/grubx64.efi.signed` 放在
  `::/EFI/BOOT/grubx64.efi` 和 `::/EFI/ubuntu/grubx64.efi`，
  `::/EFI/BOOT/BOOTX64.EFI` 放**微软签的 shim**，`::/boot/bzImage` 放我们签的内核；
  构建期对 ESP 上的每个文件 `sbverify --list` 复验，任一失败 `exit 1`。
* `SECURE_BOOT=0` → 同样的自建 GRUB，但**不签名**、ESP 走旧的单加载器布局。
* `GRUB_SOURCE=system` → 退回宿主机的 `grub-mkimage`（**仅用于对比，不要用于 Secure Boot**）。

## 5. 回退

* 想回到发行版 GRUB：`GRUB_SOURCE=system SECURE_BOOT=1 ESP_ONLY=1 bash make_partition_disk.sh`
  （在 Secure Boot 下**会失败**，这正是本目录存在的原因）。
* 想回到未签名路径：`SECURE_BOOT=0 ESP_ONLY=1 bash make_partition_disk.sh`。
* 磁盘镜像整体回退：`zstd -d media/ohos_part_pc_ptl.pre_selfbuilt_grub.img.zst`。
