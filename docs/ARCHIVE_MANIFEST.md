# OHOS pc_ptl（Intel PTL 笔记本）工作归档 — 2026-10-22

本归档把这一阶段**所有源码改动、补丁、注入脚本、报告、以及交付镜像里的权威产物**集中在一起，
用于存档与复现。**不包含 5.5 GB 的整盘镜像本身**（只记录 sha256 与获取路径）。

- 生成时间：2026-10-23
- 生成脚本：`out/x86_64_virt/ohos-dbg/make_archive.sh`（可重跑，幂等覆盖）
- 校验：`SHA256SUMS`（本目录全部文件）+ `DELIVERED_SHA256SUMS`（仅镜像内抽取的产物）
- 归档大小：约 329 MiB / 1158 个文件

---

## 0. 交付镜像身份（最重要的一个 sha）

| 项 | 值 |
|---|---|
| 路径 | `out/x86_64_virt/ohos-dbg/partdisk/media/ohos_part_pc_ptl.img` |
| sha256 | **`f1040921bede65a86985fb3b3dc886dbed68cccde21105bea15f6fe5af83ae15`** |
| 镜像内 tag | `pc_ptl-b2-rebuild-20261022-2350`（见 `delivered/p2/etc/ohos-image-id`） |
| ESP 分区 sha | `5576fced…`（与安全启动版基线一致） |
| p2 关键文件 sha | `53003bbd…` |
| 备份（仅 2 个 .zst） | `partdisk/media/ohos_part_pc_ptl.pre_batch6.img.zst`（重建基线，含 Secure Boot）、`ohos_part_pc_ptl.p1_pre_secureboot.img.zst`（仅 p1） |

分区布局（512 B 扇区）：p1 ESP 2048/1048576、p2 system 1050624/4194304、p3 vendor 5244928/1048576、
p4 sys_prod 6293504/131072、p5 chip_prod 6424576/131072、p6 userdata 6555648/33558495。

写入 U 盘：`sudo sh partdisk/dd_and_verify.sh /dev/sda`（内含 `sgdisk -e` 修 GPT 备份头，必须执行）。

---

## 1. 三步上手

```sh
# 1) 写盘（会清空目标 U 盘！）
sudo sh 04_scripts/partdisk/dd_and_verify.sh /dev/sda

# 2) 首次使用前导入 MOK（只需一次），重启进 MokManager 输密码 Enroll
sudo mokutil --import 04_scripts/partdisk/sb_keys/ohos-uefi.cer

# 3) 开机后取诊断包（一条命令，11 段，约 100 s）
ohos-diag            # 输出 /sys_prod/ohos-diag/diag-<ts>.tar.gz，首个文件是 VERDICT.txt
```

读结论：`tar -xzOf <包> VERDICT.txt`（一张「项目 / 期望 / 实测 / PASS/FAIL/WARN/SKIP」表）。

---

## 2. 目录结构

```
00_MANIFEST.md              本文件
REPO_HEADS.txt              每个改动仓库的 git HEAD（打补丁前请先对齐）
SHA256SUMS                  本目录全部文件校验
DELIVERED_SHA256SUMS        从交付镜像抽取的产物校验
01_tree_patches/            树内已跟踪文件的 git diff（23 个仓，逐仓一个 .patch）
02_tree_new_files/          树内新增文件（仓库内新增 + 6 个整目录 + 内核 defconfig）
03_out_patches/             out/ 下所有修复补丁（含 Mesa、SceneBoard、Aira、Browser、MMI…）
04_scripts/                 injectors（45）/ partdisk / tools / debug
05_reports/                 98 份 SUMMARY.md + AGENTS.md（完整交接文档）
06_artifacts/
  delivered/p2|p3/          ★ 从交付镜像直接抽取的权威产物（HAP、lib、脚本、配置、固件）
  builds/                   构建期中间产物（非最终态，仅供追溯）
  source/mesa/              Mesa OHOS 平台层源码（含行序翻转 + 驱动诊断日志）
```

---

## 3. 树内补丁（01_tree_patches，23 个仓库）

> 打补丁：`git -C <repo> apply <patch>`（先核对 `REPO_HEADS.txt` 的 HEAD）。

| 补丁 | 文件数 | 作用 / 对应问题 |
|---|---|---|
| `vendor_ohemu.patch` | 10 | **产品配置总成**：graphic/window 子系统 features（sceneboard + uni_render + opengl）、2in1、`product_virt.para`（FreeForm、BMS 设备类型放行）、ALSA 适配、HDF `wifi_chip_device` 节点、预装/特权/权限清单（SceneBoard/Aira/Terminal/Rime）、`sanitizer_check_list.gni`、wifi feature 切 `default` |
| `foundation_graphic_graphic_2d.patch` | 11 | **RS 平台修复**：①async 事务 `GetCallingPid()==0` 不再覆盖真实 pid（修 `pid:0 not valid` 丢事务）；②`GetUniRenderEnabled()` 只在得到 true 时永久缓存；③`rs_filter_cache_manager.cpp` `ResetClip()`（修毛玻璃只画上半）；④backdrop 首帧强制刷新；⑤水印/不透明日志降为 DEBUG；⑥`screen_session` 相关 dump 增强 |
| `foundation_multimodalinput_input.patch` | 10 | **输入**：MMI 连接懒重连、关键事件（DOWN/UP）最多等 150 ms **不丢**、motion/hover 才丢、客户端**读 socket 与回调解耦**（`OS_mmi_Dispatch` 线程）、`MMI_PERF` 埋点、指针窗口延迟重建（修光标不绘制）、`uds_server`/`uds_session` 流控 |
| `foundation_window_window_manager.patch` | 3 | 合一架构下把 `connectToRenderToken`/`renderSession` 正确传入 ScreenSession（修显示节点 `NO_RSUIContext`）；`package.json` 一行清理 |
| `device_qemu.patch` | 21 | **显示 HDI（本机唯一显示通路）**：DRM 节点选择、`drmModeAddFB2` **按 buffer 身份缓存复用**（去掉每帧 23.6 MB 的 FB 重建）、连接器/编码器/平面修正、gralloc、每帧日志降级、`init.virt.cfg` |
| `drivers_peripheral.patch` | 9 | ALSA 适配（render/capture）、电量、`devhost`、**通用 nl80211 chip HAL**（regdomain/reload/关省电）、display composer 1.x 服务 |
| `drivers_hdf_core.patch` | 12 | HDF host/kevent/osal 稳定性；Wi-Fi bus Kconfig；`hc-gen` 生成带 **CAP_NET_RAW** 的配置（蓝牙 RAW HCI 通道） |
| `drivers_interface.patch` | 5 | display composer v1_5 接口/实现、hc-gen 工具 |
| `base_startup_init.patch` | 2 | `console.cfg` 给 native token 补 **APL=system_core + DUMP 权限（含 permission_acls）**（根治 `hidumper` 不可用）；`init.cfg` 的 import 路径 |
| `base_hiviewdfx_hidumper.patch` | 1 | `HasDumpPermission()` **对 root(uid 0) 放行**（真机上权限仍被静默丢弃时的兜底） |
| `base_inputmethod_imf.patch` | 5 | 输入法弹窗/候选栏修复（含中英文案） |
| `base_global_system_resources.patch` | 1 | `2in1` 下 `float_sys.json` 尺寸资源 |
| `applications_standard_settings.patch` | 5 | 触控板页改异步（`pointer.get/setTouchpadPointerSpeed`，UI 线程零同步 IPC）+ 路由 try/catch（修设置闪退） |
| `foundation_communication_wifi.patch` | 6 | Wi-Fi SA 加载/设备/热点/P2P/扫描实现与 SA manager |
| `foundation_communication_bluetooth_service.patch` | 1 | `hdi_wrapper.c` dlopen 库名 `libbluetooth_hdi_adapter.so` → **`.z.so`**（否则协议栈碰不到 HDI 就退出） |
| `foundation_bundlemanager_bundle_framework.patch` | 2 | x86_64 模拟器下**原生 SO ABI 不匹配从致命降级为警告**（否则 SceneBoard 装不上）；安装器健壮性 |
| `foundation_ability_ability_runtime.patch` | 2 | `screen_unlock_interceptor` 对 `const.debuggable` 放行；权限工具 |
| `foundation_arkui_ace_engine.patch` | 1 | `text_field_pattern.cpp` 输入框行为 |
| `third_party_wpa_supplicant.patch` | 1 | `phy_info_rates` 在 `num_rates==0` 时提前返回（规避本树 musl `calloc(0)` 除零 → wpa_host SIGFPE） |
| `third_party_musl.patch` | 2 | `malloc_common.c`（`calloc(0)` 除零、分配器加固） |
| `third_party_alsa-lib.patch` | 1 | `include/config.h`（OHOS 交叉构建） |
| `kernel_linux_build.patch` | 2 | `kernel.mk`/`kernel_module_build.sh` 模块清单与构建（配合内核 `=m` 驱动） |
| `build.patch` | 2 | `build_scripts/build.sh`（宿主 Ruby 4 的 `RUBYOPT` 兼容入口）、`config/compiler/BUILD.gn`（Vulkan 头路径） |

新增文件（`02_tree_new_files/`，均为 `git status` 的 `??` 项）：
`vendor_ohemu/`（`qemu_x86_64_linux_min/bundle.json`、`virt/hdf_config/khdf/hdf_hcs.hcb` 等）、
`drivers_hdf_core/`（`hdf_diag_log.h`）、`drivers_peripheral/`（`comp_kmsg.h`）、
`device_qemu/`、`applications_standard_settings/`（`MousePage.ets`、`TouchpadPage.ets`、`TouchpadPointerSpeedController.ets`）、
`kernel_linux_build/`（`modules_manifests/`、`ohos_stage_modules.sh`）、`kernel_linux_config/`（见 §4）。

---

## 4. 树内新增目录（02_tree_new_files/_worktree）

| 目录 | 大小 | 内容 |
|---|---|---|
| `device/pc/` | 18 M | **新设备 `ptl`**：`BUILD.gn`/`ohos.build`/`device.gni`、`linux_full/{config.gni,device.gni,bundle.json}`、`cfg/`、`firmware/`（SOF/Xe/WiFi/BT 固件 + `BUILD.gn`）、`hardware/`、`grub/`（**自建 GRUB 2.14 配方 + 3 补丁 + `.sbat`**）、`sceneboard_patches/`、`hwdec_probe/` |
| `vendor/pc/` | 96 K | **新产品 `pc_ptl`**：`config.json`（board=ptl、device_type 2in1）、`power_config/`、`subsystem_config_overlay.json`、`bluetooth/src/bt_vendor_linux.c`（H4 切帧 + hilog 落点） |
| `applications/standard/terminal/` | 2.3 M | 原生 ArkTS 终端（VT100 解析 + Canvas 渲染）+ `ohosptyd` PTY 守护 |
| `applications/standard/rime_ime/` | 4.6 M | Rime 输入法 HAP 源码 |
| `base/startup/ohos_diag/` | 252 K | **`ohos-diag`**（11 段 / `VERDICT.txt`）、`zz_dmesg_boot.sh`、`zz_hilog_persist.sh`、`zz_audioup.sh`、`zz_audioguard.sh`、`ohos-diag` 各段判据 |
| `third_party/aira/` | 100 K | AIRA 浏览器补丁素材（HDS 垫片、codec guard 说明） |

内核 defconfig（`02_tree_new_files/kernel_linux_config/`，1.2 M 文本）：
`linux-7.2/arch/x86/configs/{ptl,x86_64_virt}_standard_defconfig` 等 —— 关键开关：`NAMESPACES/PID_NS/NET_NS`（ArkWeb 渲染子进程必需）、
`MAC80211_HWSIM`（QEMU 测 Wi-Fi）、`IWLWIFI`、`SND_SOC_SOF_INTEL_PTL`、`USB_USBNET/R8152/CDCETHER`（USB 网卡）。

---

## 5. out/ 补丁（03_out_patches，41 个）

按产物主题分（文件名已带来源目录）：

- **SceneBoard / 桌面**：`fix_desktop2_patches_01_…`（桌面项 `page`/`area` 归一，修真机 3072×1920 桌面空白）、`02_…hidumper_root_dump`
- **AIRA / 浏览器**：`fix_aira_avc_patch_…`（屏蔽 HEVC + 改写取流参数 + 网络层兜底）、`fix_ua_browser_ua.patch`（去掉强制 Mobile UA）、`fix_browser_avc_patch_…`
- **输入**：`fix_input_aira_patch_mmi_input_focus.patch`、`…aira_hds_fallback.patch`（AIRA 缺 HDS 导致闪退）
- **Mesa**：`06_artifacts/source/mesa/`（`platform_ohos.c` 含 **行序翻转** 与驱动诊断日志；`.20260923` 为历史版本）
- **硬解**：`fix_hwdec_probe_src_media-driver-ohos-port.patch`（media-driver 26.x 的 clang/C++ 标准修复）
- **诊断/性能**：`fix_sysperf_patch_rs_perframe_log.patch`、`…ohos_diag_perf.patch`、`fix_desktop2_…desktop_criteria`、`fix_hwdec2_evidence_ohos-diag-audio.patch`
- 其余为调研期补丁（`research_code_*`、`verify_*`），保留备查。

---

## 6. 脚本（04_scripts）

- `injectors/` — **45 个 `fix_*_inject.sh`**（每个都可对镜像副本幂等注入并自校验 sha）。**注意**：
  1) 它们**拒绝对交付镜像路径动手**（`REFUSING`，exit 3）；请对 `rebuild.img` / `scratch.img` 等副本操作。
  2) 参数顺序是 `inject.sh <img> [hap] [--with-diag]`，**没有 `--force`**。
- `partdisk/` — `dd_and_verify.sh`（写盘+校验）、`make_partition_disk.sh`（分区/Secure Boot/GRUB 装配，`SECURE_BOOT=1` 默认）、
  `update_image_id.sh`（重算镜像身份戳）、`gen_sb_keys.sh`、`sb_keys/`、`grub/`（dist + 上游 tarball）、
  `README_SECURE_BOOT.md`、`DIAG_SUMMARY.md`。
- `tools/` — `hwdec_probe` 构建配方与交叉文件、`drmfb_dump.c`/`drmfb2.c`（读 CRTC 扫描输出，验证"是否真的上屏"）、`drm_modes.c`、`mouseinj.c`。
- `debug/` — 189 个调试脚本（VNC/hdc/截图/触摸注入/QEMU 队列查询等）。

---

## 7. 产物（06_artifacts/delivered，直接从镜像抽取）

**HAP（p2 `/system/app`）**

| 文件 | sha256 前 16 | 说明 |
|---|---|---|
| `SceneBoard/SceneBoard.hap` | `be8096904f445223` | **PC 产品版 SceneBoard**（自建 `pc_sceneboard`，x86_64，含任务栏）；含桌面 `page/area` 修复 |
| `org.aira.browser/Aira.hap` | `db9ce1bb3885e423` | AIRA 3.7.2：HDS 垫片 + **HEVC 屏蔽/取流改写** |
| `com.ohos.browser/Browser.hap` | `1430bc9422095725` | 系统浏览器：桌面 UA + HEVC guard |
| `com.ohos.rimeime/RimeIme.hap` | `034971eda39fe669` | Rime 输入法 |
| `Terminal/Terminal.hap` | `4a420cd7f7c07ea5` | 原生终端（**注意：与 §22 的 c6307e56 不是同一版**，以镜像为准） |
| `com.example.kikakeyboard/kikaInput.hap` | `22b566f9c29b4956` | 键盘 |
| `com.ohos.systemui/*.hap`（8 个） | 见清单 | PC 版状态栏/控制中心/通知/锁屏/导航栏等 |
| `SceneBoard/{ThemeComponent,ThemeService,NotificationManagement}.hap` | 见清单 | SceneBoard 附属 |

**库 / 二进制 / 配置（p2、p3）**：`librender_service.z.so`、`librender_service_base.z.so`（毛玻璃修复）、
`libcursor_drawing_adapter.z.so`（光标重建）、`libhidumperservice.z.so`（root dump）、`libmmi-server.z.so`、
`platformsdk/libmmi-util.z.so`（流控）、`libgallium-26.2.3.so` + `libEGL/libGLES/libgbm`（**Mesa 26.2.3，virgl 硬件加速**）、
`system/bin/{ohos-diag,hwdec_probe,bt_enable,bt_diag.sh,ohosshd,zz_*.sh}`、`system/etc/init/zz_*.cfg`、
`firmware/xe/ptl_guc_70.bin`、`firmware/regulatory.db`；
p3 `/lib64`：`libva.so.2.2500.0`、`libvpl.so.2.17`、`libmfx-gen.so.1.2.17`、`libigdgmm.so.12.10.0`、`dri/iHD_drv_video.so`（**oneVPL 硬解栈**）、
`libaudio_render_adapter.z.so`、`libaudio_capture_adapter.z.so`、`libasound.so`、`libbluetooth_hci_hdi_driver.z.so`、`libbt_vendor.z.so`。
注：`libva.so.2`/`libvpl.so.2`/`libmfx-gen.so.1.2`/`libigdgmm.so.12` 在镜像里是**符号链接**，`debugfs dump` 只能抽出 0 字节空文件（清单中 sha 为 `e3b0c442…`），复制时请重建软链。

`06_artifacts/builds/` 是构建中间态（`fix_*` 的 `stage/`、`files/`），**不要**当作交付内容使用。

---

## 8. 重建配方

环境：`RUBYOPT=-r$PWD/build/compat/erb_compat.rb`、`JAVA_HOME=~/.gradle/jdks/jetbrains_s_r_o_-17-amd64-linux.2`、
node `prebuilts/build-tools/common/nodejs/node-v18.20.1-linux-x64`、hvigor 6.26.4、ohpm 26.0.0.630、SDK 26.0.0.105。

```sh
# 产品镜像（必须带 --device-type 2in1，否则 devicetype 回 default、PC SceneBoard 反复崩溃）
./build.sh --product-name pc_ptl --ccache --jobs 8 --keep-ninja-going \
  --device-type 2in1 --deps-guard=false --gn-args linux_kernel_version='"linux-7.2"'
```

改内核 defconfig 后 **必须删对应产品的 stamp 与 bzImage**（ninja 不跟踪 `kernel/linux/config/**`），
并删共享 `out/KERNEL_OBJ/kernel/OBJ/linux-7.2/.config`。

从基线与 16 个注入脚本一键重建整盘：`04_scripts/rebuild_chain.sh`（顺序见脚本；约 25 min，逐步记录 rc/sha）。

---

## 9. 未纳入归档的「脏仓」（确认非本项目改动）

`base/web/webview`、`third_party/ffmpeg`、`third_party/libjpeg-turbo`、`bounds_checking_function`、`e2fsprogs`、
`freetype`、`kernel/linux/linux-6.18`、`kernel/linux/linux-6.6`、`kernel/linux/common_modules`、`kernel/linux/patches`、
`base/powermgr`（仅未跟踪 build 目录）、`third_party/vk-gl-cts`、`cups-filters`、`sane-airscan`、`tzdata`、
`iptables`、`icu`、`jsframework`、`dlp_manager`、`user_certificate_manager`、`permission_manager`、
`user_file_service`、`distributed_hardware_fwk`。

筛选依据：修改时间集中在 9/17 源码导入期、或内容与本项目无关（例如 linux-6.6 的 accesstoken id、
vk-gl-cts 的测试用例）。`foundation/arkui/ace_engine` 只取了 `text_field_pattern.cpp`，其余 `.ets` 为构建生成物。

---

## 10. 已知遗留（真机未闭环）

1. **无声**：声卡已能被 SOF 拉起（`zz_sof_reprobe`），但 `pcm-data-flowing`（hw_ptr 是否前移）与
   `sof-dai-mixer-nonzero` 尚未在真机判定 —— 二选一：DAI 数字静音，或框架开流不喂数据。
2. **HEVC**：ArkWeb 引擎（Chromium 114 x86_64）无 HEVC 解析/解码；当前只能在页面层屏蔽 HEVC 强制 AVC。
   根治需重编引擎（磁盘不足）或补 `drivers/peripheral/codec/hal/va` 走 oneVPL 硬解。
3. **hidumper 权限**：root 放行已在 QEMU 验证；真机需用 `VERDICT.txt` 的 `hidumper/dump-permission` 复核。
4. **直播卡顿**：引擎无 libva（Chrome/114 无硬解开关），H.264 纯软解；硬解栈已就位，缺 HDI 接线。
5. 毛玻璃有 ~3–5% 横向条带残差；过渡动画偶发「整屏小图平铺」（RS/virgl 离屏快照采样，未定位到代码点）。

---

## 11. 校验

```sh
cd <解压后的归档>
sha256sum -c SHA256SUMS                # 全量
( cd 06_artifacts/delivered && sha256sum -c ../../DELIVERED_SHA256SUMS )
git -C <repo> apply --check <04 里对应的 .patch>   # 打补丁前预检
```
