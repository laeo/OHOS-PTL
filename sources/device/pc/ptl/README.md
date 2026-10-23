# device/pc/ptl —— Intel Panther Lake (X7-358H) 真机接入骨架

> **状态：骨架 / 未上机验证。** 本目录只提供真机接入所需的**具体文件与清单**，
> 尚未接入任何产品（没有 `BUILD.gn`/产品 config 引用它），因此**不影响现有构建**。
> 显示 HDI 的“去 QEMU 硬编码”通用化已完成并通过 QEMU 回归（见
> `out/x86_64_virt/ohos-dbg/verify_hdi/SUMMARY.md`）。

## 1. 硬件基线（本机实测，`host_probe.txt`）

| 项 | 值 |
|---|---|
| GPU | Intel Panther Lake [Arc B390] `8086:b080`，驱动 `xe` |
| DRM 节点 | **`/dev/dri/card1`**（**没有 `card0`**），`renderD128` |
| 显示 | eDP-1 connected，面板 3072x1920 |
| 触摸板 | I2C-HID `27C6:0F9A`（需 `CONFIG_I2C_HID`/`HID_MULTITOUCH`/`LPSS`） |
| 存储 | NVMe（`/dev/nvme0n1`/`nvme1n1`） |
| 启动 | UEFI + GPT（`CONFIG_EFI_STUB=y`） |

## 2. 显示 HDI：本骨架依赖的通用化实现

`device/qemu/common/virt_full/hardware/display/` 的显示 HDI 已通用化，真机可直接复用其
`display_composer_model` / `display_buffer_model` 目标：

- **DRM 节点枚举**：`src/display_device/drm_node_utils.h` 的 `FindPreferredDrmNode()`：
  1. 环境变量 `OHOS_DRM_DEVICE`（调试用）；
  2. 配置文件 `/vendor/etc/display/drm_node.conf`（首个非注释行，如 `/dev/dri/card1`）；
  3. 遍历 `/dev/dri/card*`，选“已连接 connector 最多”的节点（QEMU→card0，PTL→card1）。
- **格式选择**：`src/display_device/hdi_drm_layer.cpp` 的 `BuildFormatCandidates()`：
  先按 `hdl.GetFormat()` 映射到**精确** DRM fourcc（`PIXEL_FMT_RGBA_8888→DRM_FORMAT_ABGR8888` 等），
  再用 **plane 通告的格式列表**过滤，最后回退到 legacy/`XRGB8888`。
  实测 PTL/Xe primary plane 通告 `XR24 XB24 AR24 AB24`，因此真机会选 **AB24**（R/B 正确，无需内核 patch）。

> **注意**：当前实现用 `drmModeAddFB2`（隐含 LINEAR）。gralloc 走 `DRM_IOCTL_MODE_CREATE_DUMB`
> （线性 dumb buffer），Intel 支持；**若将来 gralloc 改为带 modifier 的 GBM 分配**，
> 需改用 `drmModeAddFB2WithModifiers` 并从 `BufferHandle` 取 modifier。

## 3. 接入清单（可静态确认 vs 待上机）

### 3.1 可静态确认
- [x] 内核 defconfig：`kernel/linux/config/linux-7.2/arch/x86/configs/pc_ptl_standard_defconfig`
      已存在（`DRM_XE=y`、`IWLWIFI`、`BT_INTEL_PCIE`、`I2C_HID`、`LPSS`、SOF 等）。
- [x] 节点枚举逻辑（`drm_node_probe` 在主机 PTL 上选中 `card1`）。
- [x] 格式精确映射（`drm_fmt_probe` 在主机 Xe 上确认 `AB24` 被 primary plane 支持）。
- [x] 显示 HDI 去 `card0`/去 `XRGB8888` 硬编码（QEMU 回归 MAE 1.15，见 SUMMARY）。

### 3.2 待上机验证
- [ ] 真机内核能否用 `pc_ptl_standard_defconfig` 启动（Xe/GuC/HuC 固件版本匹配）。
- [ ] 真机 Xe 的 `cardN` 是否确实非 0（本机为 1）；枚举是否选对。
- [ ] 真机扫描输出格式是否为 `AB24`、R/B 是否正确（用 `drmfb_dump` 对比 `snapshot_display`）。
- [ ] 高分屏 3072x1920 的缩放/DPI。
- [ ] 背光：`DrmConnector::SetBrightness` 写 `/sys/class/backlight/backlight/brightness`
      在真机需对应到 `intel_backlight`（`/sys/class/backlight/*/`）。
- [ ] 触摸板 libinput 分类、键盘。

## 4. 固件（待打包）
把以下固件放进镜像 `/system/lib/firmware/`（或 `/vendor/lib/firmware/`）：
- `xe/ptl_guc_70.bin[.zst]`、`xe/ptl_huc.bin[.zst]`、`xe/ptl_gsc_1.bin[.zst]`
- `iwlwifi-sc-a0-gf-a0-100.ucode`（+ `.pnvm`）
- `intel/ibt-00a0-0041-*.sfi`、`intel/ibt-00a0-0041-*.ddc`
> 若放 `.zst` 需 `CONFIG_FW_LOADER_COMPRESS=y`（`pc_ptl_standard_defconfig` 已开）。

## 5. 参考
- 规划：`out/x86_64_virt/ohos-dbg/PC_ON_PTL_PORTING_PLAN.md` §4（显示 HDI）、§5/§6。
- 显示 HDI 验证：`out/x86_64_virt/ohos-dbg/verify_hdi/SUMMARY.md`。
- 内核 7.2 + 真机 defconfig：`out/x86_64_virt/ohos-dbg/verify_kernel2/SUMMARY.md`。
