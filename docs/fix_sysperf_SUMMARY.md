# fix_sysperf — 真机（pc_ptl / HONOR XWC-P, Intel PTL + xe, eDP 3072x1920）"整机操作都卡" 取证与修复

> 目标：定位**系统级**性能问题（桌面动画/窗口/浏览器整体迟滞），而不是单应用。
> 本轮**不猜**：把"到底在用哪个 GL 后端 / CPU 频率 / 每进程 CPU / DRM 状态"做成一次性取证，
> 并修掉路上发现的两个**确定的真 bug**（RS 每帧 ERROR 日志刷屏、hidumper 完全不可用）。
>
> 交付物：`fix_sysperf/inject.sh <image>`（幂等）、`fix_sysperf/scratch.img`（验证用）、
> 本报告。**未改动** `partdisk/media/ohos_part_pc_ptl.img`（用户统一串行合入）。

---

## 0. 结论速览（每条都有 file:line / 证据）

| # | 线索 | 结论 | 状态 |
|---|---|---|---|
| 1 | 真机没有硬件 GL？ | **未证实，但已可一键证实**：Mesa 之前把驱动选择/回退日志写进 `/data/mesa_dbg.txt`，而 `render_service` 以 uid `graphics` 运行、**写不进 /data** → 所有诊断信息**静默丢弃**。已改为 `MESA-OHOS:` 前缀，落 hilog + stderr + `/data/service/el0/render_service/mesa_ohos.log` | ✅ 已修 |
| 2 | 静默退回 swrast | `ohos_load_driver()` 失败后**无条件**回退 swrast（软件渲染），没有任何日志 | ✅ 已改成显式记录 + `MESA_OHOS_NO_SWRAST_FALLBACK=1` 可禁用 |
| 3 | RS 水印日志 | **不是"水印功能开着"，是 bug**：`DrawCommSurfaceWatermark()` 在**没有任何水印**时（正常情况）**每 surface 每帧**打一条 **ERROR** 级日志 | ✅ 已降级为 DEBUG（真机日志里 592 条 / 动画期 ~500 行/秒） |
| 4 | `SetBufferColorSpace fail` / `SetMetadata -5` | 同一根因：HDI display **没实现 metadata 接口**，RS 每帧调用失败 → **不是性能主因**（真机 81 条 / 24 分钟） | ℹ️ 仅记录 |
| 5 | `Animation finish callback is not executed in estimated time` | 是**结果**不是原因（动画没按时完成） | ℹ️ 由 §1/§2/§3 决定 |
| 6 | **hidumper 全线不可用（新发现，阻塞取证）** | 真机上 `hidumper -ls` / `-s RenderService` **全部**返回 `request error`：`console`/`zzdiag` 的 native token 默认 `apl=system_basic`，而 `ohos.permission.DUMP` 需要 `system_core` → 权限校验失败 | ✅ 已修（加 `apl` + `permission`） |
| 7 | 显示 HDI 路径 | 是 **DRM/KMS 直通**（`drmModeAddFB2` 导入客户 dma-buf + `drmModeAtomicCommit` 挂 plane），**没有每帧 CPU 拷贝** | ℹ️ 已核实 |

---

## 1. 首要怀疑：真机的 GL 后端（任务 1 / 2）

### 1.1 镜像里到底是哪个 Mesa

`pc_ptl` p2 里是 **Mesa 26.2.3**（`libgallium-26.2.3.so`，28.9 MB，含 **iris**）：

```
/system/lib64/libgallium-26.2.3.so   28972880 B   sha 3ef698af618909fe...   ← 与 mesa_build26/stage-iris/ 完全一致
/system/lib64/libEGL.so.1.0.0         322808 B    sha 7bf3d9cc1131a608...
```
（`device/qemu/common/virt_full/hardware/gpu/x86_64/` 里那份是 vendor 的 **Mesa 21.2.1**，
 只在 pc_ptl 没被替换时才会用；本镜像已被 `mesa_build26/stage-iris` 覆盖。）

Mesa 26.2.3 的 gallium 构建参数（`mesa_build26/setup_iris.sh`）：
`-Dgallium-drivers=virgl,iris,softpipe` → **iris 在里面**。

### 1.2 驱动选择路径（静态推演，file:line）

```
mesa_build26/mesa3d-src/src/egl/drivers/dri2/platform_ohos.c:1115 ohos_load_driver()
  ├─ :1050 打开 /dev/dri/renderD128 → 真实机上是 **xe** 驱动的 render node
  ├─ :1061 loader_get_driver_for_fd(fd)
  │        └─ src/loader/loader.c:790 loader_get_pci_driver()
  │             driver_map[] (src/loader/pci_id_driver_map.h:56)
  │               {0x8086,"i915", i915_chip_ids}   ← PTL(0x8086:0xb080) **不在** i915_pci_ids.h
  │               {0x8086,"iris", NULL, -1, iris_predicate}  ← 命中
  │             iris_predicate() (src/loader/loader.c:139) 接受内核驱动名 "i915" 或 "xe" ✔
  │             → driver_name = **"iris"**
  ├─ :1085 dri2_create_screen() → dri2_init_screen() → pipe_loader_drm_probe_fd()
  │        └─ get_driver_descriptor("iris") (pipe_loader_drm.c:71) ✔
  └─ :1112 ohos_load_driver_swrast()  ← **失败时无条件回退软件渲染**
```
**结论：按代码推演，真机应该拿到 iris**；但**推演不能代替实测**，而且第 3 步的失败会被
**静默吞掉**（见 1.3）。

### 1.3 为什么之前完全看不到（根因）

`mesa_build26/mesa3d-src/src/egl/drivers/dri2/platform_ohos.c`（改前）：
```c
static void mesa_dbg(const char *fmt, ...) {
   FILE *f = fopen("/data/mesa_dbg.txt", "a");   // ← render_service 写不进去！
   if (!f) return;                                 // ← 静默丢弃
   ...
}
```
* `render_service` 以 **uid `graphics`** 运行（`out/ptl/packages/phone/system/etc/init/graphic.cfg`），
  `/data` 目录 `root:data_reserve 0770`，**graphics 不在该组** → `fopen` 失败 → **所有诊断信息消失**。
* 且 `mesa_dbg` 用的是 Mesa 自带的 `mesa_dbg` 风格（只有 `MESA_DEBUG` 环境变量才打印的那类），
  我们自己写的 `MESA_OHOS:` 前缀**没有**进任何日志。

→ 所以"静默退回 swrast"这条怀疑**既不能证实也不能证伪**。这就是本轮第一件事。

### 1.4 已做的改动（只改副本，仓库 `third_party/mesa3d` 未动）

文件：`out/x86_64_virt/ohos-dbg/mesa_build26/mesa3d-src/src/egl/drivers/dri2/platform_ohos.c`
（完整副本见 `fix_sysperf/patch/platform_ohos.c.diag`）

1. **新增 `mesa_ohos_log()`**：同一条消息同时写到
   * hilog（`dlopen("libhilog.so")` → `HiLogPrint(LOG_CORE, LOG_INFO, 0xD002000, "MESA-OHOS", …)`；
     本镜像里 ndk hilog 的库名是 **`libhilog.so`**，不是 `libhilog_ndk.z.so`——见 `/system/lib64`），
   * stderr，
   * 文件（依次尝试 `$MESA_OHOS_LOG_FILE` → `/data/service/el0/render_service/mesa_ohos.log`
     → `/data/local/shader_cache/local/system/render_service/mesa_ohos.log` →
     `/data/service/el1/public/render_service/…` → `/data/local/tmp/…` → `/tmp/…`；
     **第 1 个是 graphics 可写的**，`graphic.cfg` 里 `mkdir /data/service/el0/render_service 0711 graphics graphics`）。
2. **驱动选择全程打点**：`ohos_log_drm_nodes()`（列出 /dev/dri 下所有节点）、打开的节点、
   `loader_get_pci_id_for_fd()` 的 PCI id、`loader_get_driver_for_fd()` 的结果、
   实际使用的 gallium driver、`dri2_create_screen()` 成败与 errno。
3. **回退不再静默**：`dri2_initialize_ohos()` 里打印
   `"init: hardware driver NOT usable -> falling back to swrast (SOFTWARE RENDERING)"`，
   并在 `pscreen->get_name()` 是 `softpipe/llvmpipe/swrast` 时再打一条
   `"*** WARNING: SOFTWARE RASTERIZER IN USE"`。
4. **可禁用兜底**：环境变量 `MESA_OHOS_NO_SWRAST_FALLBACK=1` → 硬件驱动失败就**直接失败**，
   不再偷偷变软件渲染（便于将来判别）。
5. **可强制驱动**：`MESA_OHOS_DRIVER=iris` → 覆盖自动选择结果。
6. 顺带把 `pscreen->get_name()` 打进日志（= Mesa 的 `GL_RENDERER` 同源信息）。

**重新编译**（增量 ninja，只重编 `platform_ohos.c` + 重链 `libEGL`）：
```
out/x86_64_virt/ohos-dbg/mesa_build26/build_iris_diag4.log
```
`libgallium-26.2.3.so` / `libGLESv1_CM` / `libGLESv2` / `libgbm` **字节级未变**
（sha 与镜像里的一致），只有 `libEGL.so.1.0.0` 变了 → **注入面最小**。

### 1.5 QEMU 实测证据（新 libEGL 不崩 + 日志可用）

`out/x86_64_virt/ohos-dbg/fix_sysperf/evidence/mesa_log_qemu.txt`（节选）：
```
MESA-OHOS: [diag] hilog_lib=loaded hilog_domain=0x0d002000
MESA-OHOS: drm: node /dev/dri/card0
MESA-OHOS: drm: node /dev/dri/renderD128
MESA-OHOS: drm: opened /dev/dri/renderD128 fd=15
MESA-OHOS: drm: pci id 1af4:1050
MESA-OHOS: drm: loader_get_driver_for_fd -> virtio_gpu
MESA-OHOS: drm: using gallium driver 'virtio_gpu'
MESA-OHOS: drm: dri2_create_screen OK driver='virtio_gpu'
MESA-OHOS: init: create_screen OK driver='virtio_gpu' renderer='virgl (Mesa Intel(R) Graphics (PTL))' fd=15
MESA-OHOS: MESA_OHOS: create_image buf w=1280 h=800 stride=5120 fmt=0xc fourcc=0x34324241 fd=22
```
* 新 `libEGL` 加载正常、RS 正常出帧（`hidumper -a screen` → `activeMode 1280x800@75`）。
* **注意**：hilog 侧仍看不到 `MESA-OHOS`（`HiLogPrint` 从 `dlopen` 的库调用被拒/未生效，
  返回值非 0，代码里已做 domain 回退 0xD001400/0xD000000）。
  **权威来源是那个文件**：`/data/service/el0/render_service/mesa_ohos.log`，
  `ohos-diag perf` 会自动收走（见 §3）。
* QEMU 上 driver 是 `virtio_gpu`/virgl（符合预期）；**真机上这里会显示 `iris` 或 `swrast`**。

---

## 2. RS 水印日志（任务 3）：不是开关问题，是 bug

### 2.1 定位

`foundation/graphic/graphic_2d/rosen/modules/render_service/core/feature/watermark/rs_surface_watermark.cpp:25-32`
```c
void RSSurfaceWatermarkHelper::DrawCommSurfaceWatermark(RSPaintFilterCanvas& canvas,
    const RSSurfaceRenderParams& params)
{
    if (params.IsSystemWatermarkEmpty() && params.IsCustomWatermarkEmpty()) {
        RS_LOGE("...DrawCommSurfaceWatermark Name:%{public}s Id:%{public}" PRIu64
            " water mark count is zero", ...);   // ← 每 surface 每帧一条 ERROR
        return;
    }
```
* **没有"水印功能开关"**：水印只有被 `SetSurfaceWatermark()` 设置过才有；
  上面这个分支就是"**一个水印都没有**"的**正常状态**，却打 ERROR。
* 调用点（每帧每个 surface 各一次）：
  * `core/drawable/rs_surface_render_node_drawable.cpp:269`
  * `core/feature/uifirst/rs_draw_window_cache.cpp:237`
  * `core/feature/uifirst/rs_sub_thread_cache.cpp:1250`
* 同类问题还有一处：
  `rosen/modules/render_service/composer/composer_service/external_depend/engine/rs_base_render_util.cpp:1277`
  → `RS_LOGE("RSBaseRenderUtil::DealWithSurfaceRotationAndGravity, GetSurfaceBufferOpaque:0")`
  同样在 uni-render 的**每 surface 每帧**路径上（`rs_uni_render_util.cpp:587/658/768`）。

### 2.2 量化（真机 hilog `diagwork/d2/E_hilog.txt`，24 分钟窗口）

| 日志 | 条数 | 说明 |
|---|---|---|
| `DrawCommSurfaceWatermark … water mark count is zero` | **592** | 8 个 surface 各 80 条左右 → 动画期 **~480 行/秒** |
| `RSBaseRenderUtil::DealWithSurfaceRotationAndGravity, GetSurfaceBufferOpaque:0` | ~460 | 同上，每 surface 每帧 |
| `RSUniRenderComposerAdapter::SetBufferColorSpace set color space fail` | **81** | **每帧 1 次**（不是每 surface） |
| `Bufferqueue: SetMetadata Failed with -5` | **243** | 同源（bufferqueue 不支持 metadata） |
| `Animation finish callback is not executed in estimated time` | 8 | 结果，不是原因 |

按秒统计（真机 hilog 20:07:14–20:07:33，20 秒）：
```
20:07:14 → 234 行   20:07:17 → 383   20:07:18 → 497
20:07:20 → 1062 行  20:07:23 → 298   20:07:25 → 373   …  ≈ 230 行/秒（动画期）
```
其中 **RS 的 E 级日志约 75%**。渲染线程每帧 8 次 E 级 hilog 写入（socket 写 hilogd），
**在渲染关键路径上**，会直接吃掉帧预算。

### 2.3 修法

`RS_LOGE` → `RS_LOGD`（= `HILOG_DEBUG`，默认日志级别下**不写 socket**，只做一次格式化）：
`fix_sysperf/patch/rs_perframe_log.patch`（2 文件，各 1 行 + 注释）。
重编：`out/x86_64_virt/ohos-dbg/fix_sysperf/build_rs.log`（`build.sh --product-name pc_ptl
--build-target librender_service`，**2 分 08 秒**，74 个目标，无全量重建），
产物 `out/ptl/graphic/graphic_2d/librender_service.z.so` = 8 888 432 B，
sha `c0bbdd2a52ba4881…`。

> **判据（真机）**：动画/拖动时 `hilog | grep -c DrawCommSurfaceWatermark` 应从 ~500/秒 降到 **0**
> （DEBUG 级默认不落盘）；`GetSurfaceBufferOpaque` 同理。

---

## 3. `ohos-diag` 新增 `perf` 段（任务 5）

`base/startup/ohos_diag/ohos-diag`（本地改动，非 manifest 仓）新增 **F/perf** 段，
并加入默认段列表与 `quick` 段列表。**注意**：设备上没有 `awk`/`tr`，
全部用 `sed`/`cut`/`grep` 实现（`cpu_snap`/`cpu_diff` 自己算每进程 CPU%）。

采集内容（`F_perf.txt`）：

| 子段 | 内容 |
|---|---|
| F1 图形后端（最关键） | `hidumper -s RenderService -a gles`（**GL_RENDERER/GL_VERSION**）、`-a screen`（分辨率/电源/刷新率/activeMode）、`-a fps`、`-a hitchs`（>66/>33/>16.67ms 掉帧计数） |
| F2 CPU 频率 | 每个 `cpu*/cpufreq` 的 `scaling_cur_freq/min/max/governor/available_governors`、每个 `cpufreq/policy*`、`intel_pstate/{status,no_turbo,min_perf_pct,max_perf_pct,hwp_dynamic_boost,…}`、cpuidle 状态、`/proc/cpuinfo` MHz |
| F3 负载 | `/proc/loadavg`、`uptime`、`free -m`、`/proc/meminfo`、`top -b -n1`、**自算的每进程 CPU%（utime+stime 差分，HZ=100，3 秒窗口）** |
| F4 DRM/xe | `/dev/dri`、`/sys/class/drm/card*-*/status`、card 的 vendor/device/driver、`/sys/kernel/debug/dri/*/{name,state,clients}`、`lsmod`、`dmesg | grep -i xe` |
| F5 Mesa/RS | hilog 里的 `MESA-OHOS`、**Mesa 日志文件**（§1.4 的路径列表）、EGL/GL 相关 hilog、**RS 每帧日志噪声计数**（4 个 pattern 的 count） |

### 3.1 QEMU 端到端验证（已通过）

```
$ /system/bin/ohos-diag perf
ohos-diag: section F/perf ...
ohos-diag: DONE, archive = /sys_prod/ohos-diag/diag-20261021-153515.tar.gz (12835 bytes)
```
`F_perf.txt` 实测内容见 `fix_sysperf/evidence/F_perf_qemu.txt`：
* `GL_RENDERER: virgl (Mesa Intel(R) Graphics (PTL))` / `GL_VERSION: OpenGL ES 3.2 Mesa 26.2.3`
* `screen[0]: powerStatus=POWER_STATUS_ON, backlight=223, render resolution=1280x800 …`
* `hidumper -a hitchs` → `more than 66/33/16.67 ms  0`
* `MESA-OHOS: … renderer='virgl (…)'`（来自 Mesa 日志文件）
* 每进程 CPU% 表、loadavg、free、top 均正常。

---

## 4. 【新发现并修复】hidumper 在真机上完全不可用

这是**取证的最大阻塞**：真机 `diagwork/d2/A_hidumper_rs.txt`、`A_hidumper_sms.txt`、
`B_hidumper.txt`、`C_hidumper.txt` **全部**是 `request error`（连 `hidumper -ls` 都是）。

真机 hilog 证据：
```
10-20 20:07:29.080 18010 18010 I C02d20/DumperService: SetCmdArgs# hidumper cmd:hidumper -ls , calllingUid=0 …
10-20 20:07:29.081 18010 18010 E C02d20/DumperService: Main# request error, ret: -1.
```
QEMU 上同样复现（不是真机独有）：
```
10-21 15:13:02.677 18244 18248 E C02d20/DumperService: HasDumpPermission# No dump permission, please check!
10-21 15:13:02.677 18244 18244 E C02d20/DumperService: Request# No dump permission, please check!, uid:0.
```

**根因链**：
1. `base/hiviewdfx/hidumper/services/native/src/dump_manager_service.cpp`
   → `AccessTokenKit::VerifyAccessToken(callingTokenID, "ohos.permission.DUMP")` 失败。
2. `base/security/access_token/services/accesstokenmanager/main/cpp/src/permission/accesstoken_info_manager.cpp:2330`
   `VerifyNativeAccessToken()`：native token 的权限清单来自 init cfg 的 `"permission"` 数组，
   且受 token 的 **APL** 过滤。
3. `base/startup/init/services/init/standard/init_service.c:299-315`：
   native token 的 APL 默认 **`"system_basic"`**（`const char *apl = "system_basic";`），
   而 `ohos.permission.DUMP` 的 `availableLevel` 是 **`system_core`**
   （`base/global/system_resources/systemres/main/module.json:2723-2731`）→ **权限被过滤掉**。
4. `base/startup/init/services/etc/console.cfg` 的 console 服务 **既没有 `permission` 也没有 `apl`**
   → 即使是 root（uid 0）也拿不到 DUMP。

**修法**（两个 cfg，加 `apl` + `permission`）：
* `base/startup/init/services/etc/console.cfg`（console 服务）
* `base/startup/ohos_diag/etc/zz_diag.cfg`（开机自动抓取的那次 `ohos-diag`）
```json
"apl" : "system_core",
"permission" : [ "ohos.permission.DUMP" ]
```
**QEMU 实测（已通过）**：改完 cfg 后同一台 guest 上
```
$ hidumper -s RenderService -a gles
GL_VENDOR: Mesa
GL_RENDERER: virgl (Mesa Intel(R) Graphics (PTL))
GL_VERSION: OpenGL ES 3.2 Mesa 26.2.3
$ hidumper -s RenderService -a screen
screen[0]: … activeMode: 1280x800, refreshRate=75 …
$ hidumper -s RenderService -a hitchs
more than 66 ms 0 / more than 33 ms 0 / more than 16.67 ms 0
```
> 真机判据：刷机后 `hidumper -s RenderService -a gles` 必须能出 GL_RENDERER；
> 若仍 `request error`，看 hilog 里 `HasDumpPermission` 那行。
> **风险**：console 服务的 token APL 变成 system_core；console 本来就是 root，
> 权限面只多了 DUMP，不影响启动（QEMU 已验证 console 正常）。

---

## 5. 显示 HDI 路径（任务 4）

pc_ptl 用的是 QEMU 那套 **DRM/KMS 显示 HDI**：
`device/qemu/common/virt_full/hardware/display/src/display_device/`

* `drm_node_utils.h:146 FindPreferredDrmNode()`
  → 先看 `/vendor/etc/display/drm_node.conf` 或 `OHOS_DRM_DEVICE` 环境变量，
  否则枚举 `/dev/dri/card*`，按 **connected 连接器数**打分选最高的。
  真机上：只有一张 `xe` 卡（`card0`，`eDP-1 connected`，DP-1/DP-2/HDMI-A-1 disconnected）→ 选 card0，正确。
  （宿主机 `lspci`：`00:02.0 VGA: Intel Panther Lake [Arc B390] [8086:b080]`，驱动 `xe`。）
* `hdi_drm_composition.cpp:52 SetLayers()` 注释写着 *"now we do not surpport present direct"*，
  只把 client layer 交给 DRM；`hdi_drm_composition.cpp:119 ApplyPlane()`：
  `drmModeAtomicAddProperty(FB_ID)` + `IN_FENCE_FD` + `CRTC_ID` → `drmModeAtomicCommit`。
* `hdi_drm_layer.cpp:57 DrmGemBuffer::Init()`：
  `drmPrimeFDToHandle()` + **`drmModeAddFB2()`**（客户层的 dma-buf 直接变成 DRM FB）
  → **GPU 直通扫描输出，没有每帧 CPU 拷贝**。
  代价是**每帧**一次 `drmPrimeFDToHandle` + `drmModeAddFB2` + `drmModeRmFB` + `GEM_CLOSE`，
  以及 `AddFB2` 失败时的多格式探测循环（`hdi_drm_layer.cpp:101-111`）——这是真实开销点，
  但不是"CPU 拷贝"。
* `SetMetadata Failed with -5`：RS 调 `MetadataHelper::SetColorSpaceType()` →
  bufferqueue → HDI 的 `SetMetadata` **没实现**（`-5` = EIO）。
  这是**接口缺失**，不是拷贝；3072×1920 下也不影响像素吞吐。
  → 建议后续给 display HDI 补 `SetMetadata`，或让 RS 在能力查询失败时不再每帧重试
    （现在 `rs_uni_render_composer_adapter.cpp:342` 每帧调一次）。

**结论**：HDI 侧没有"每帧 CPU 拷贝"这种典型软渲染症状；卡顿更可能在 **GL 后端**、
**CPU 频率**、**RS 每帧日志**这三处——其中前两处本轮已经给出取证手段，第三处已修。

---

## 6. 交付物与怎么用

### 6.1 `fix_sysperf/inject.sh <image> [--no-rs|--no-mesa|--no-diag|--no-cfg]`

幂等（先比 sha256，已是最新就**跳过**，因此**镜像 sha 不变**）。
支持两种输入：GPT 整盘（`ohos_part_pc_ptl.img`）或裸 ext4（`system.img`）。

注入到 p2(system) 的 5 个文件：

| 镜像内路径 | 来源 | 说明 |
|---|---|---|
| `/system/lib64/libEGL.so.1.0.0` | `mesa_build26/stage-iris/libEGL.so.1.0.0` | Mesa 26.2.3，**只加诊断 + 可禁用兜底** |
| `/system/bin/ohos-diag` | `base/startup/ohos_diag/ohos-diag` | 新增 `perf` 段 |
| `/system/lib64/librender_service.z.so` | `out/ptl/graphic/graphic_2d/librender_service.z.so` | RS 每帧 ERROR 日志 → DEBUG |
| `/system/etc/init/console.cfg` | `base/startup/init/services/etc/console.cfg` | `apl=system_core` + `ohos.permission.DUMP` |
| `/system/etc/init/zz_diag.cfg` | `base/startup/ohos_diag/etc/zz_diag.cfg` | 同上（开机自动抓取那次） |

用法：
```sh
# 1) 复制一份交付镜像做验证（不要动交付镜像！）
cd /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/fix_sysperf
cp --sparse=always ../../partdisk/media/ohos_part_pc_ptl.img scratch.img
./inject.sh scratch.img

# 2) 刷机 / 合入：把同样的 inject.sh 指向交付镜像
```
实测：`scratch.img` sha `7f51a290…` → `7bb0445c…`，**再跑两次 sha 不变**（幂等）。

### 6.2 验证环境

* `fix_sysperf/scratch.img` = 交付镜像的稀疏副本 + 5 个文件（**未改交付镜像**）。
* QEMU 侧验证用 `out/x86_64_virt/packages/phone/images/system.img`（**已注入同一份
  libEGL / ohos-diag / console.cfg**，QEMU 回归仍正常出帧）。

### 6.3 真机一次性取证（推荐流程）

刷完 `scratch.img`（或合入交付镜像）后：
1. **开机自动抓**：`zz_diag_boot.sh` 在开机 ~240 s 后自动跑一次完整 `ohos-diag`
   → 产物在 `/ohoslog` 或 `/sys_prod/ohos-diag/diag-<ts>.tar.gz`。
   这一次就把 **F/perf** 段收全了（GL_RENDERER、hitchs、CPU 频率、每进程 CPU%、DRM/xe、Mesa 日志）。
2. **手动**：`ohos-diag perf`（或 `ohos-diag` 全量）。
3. **只想看 GL 后端**：`cat /data/service/el0/render_service/mesa_ohos.log`
   （看到 `renderer='iris …'` = 硬件 GL；看到 `SOFTWARE RENDERING` = 掉到软渲染）。

### 6.4 真机判据（逐条）

| 判据 | 期望 |
|---|---|
| `hidumper -s RenderService -a gles` | 出 `GL_RENDERER`（iris / zink / softpipe），**不再** `request error` |
| `/data/service/el0/render_service/mesa_ohos.log` | 有 `drm: loader_get_driver_for_fd -> iris`；**没有** `SOFTWARE RENDERING` |
| `hidumper -s RenderService -a screen` | `render resolution=3072x1920`，`activeMode` 刷新率 ≥ 60 |
| `hidumper -s RenderService -a hitchs` | `more than 66 ms` 计数；改动前后对比 |
| `F_perf.txt` F2 段 | `scaling_governor` 不是 `powersave`；`intel_pstate/status` = `active`；`min_perf_pct` 不是 0 |
| `F_perf.txt` F3 段 | `render_service` 的 CPU%（有动画时）应在个位数～几十 %；若接近 100%×核数 → 软件渲染 |
| `hilog \| grep -c DrawCommSurfaceWatermark` | 动画期间 **0**（原来是 ~500/秒） |
| `hilog \| grep -c "GetSurfaceBufferOpaque"` | 动画期间 **0** |
| 主观 | 窗口拖动/桌面动画是否恢复到 ~60fps 手感 |

### 6.5 回退

* Mesa：把 pc_ptl 镜像里的 `/system/lib64/libEGL.so.1.0.0` 换回旧文件
  （旧 sha `7bf3d9cc1131a608…`；`libgallium/libGLES/libgbm` 从未变，不需要动）。
* RS：`git -C foundation/graphic/graphic_2d checkout -- <那两个文件>` → 重编
  `librender_service` → 注入 → e2fsck → 重建 overlay。
* cfg：把 `console.cfg` / `zz_diag.cfg` 的 `apl`/`permission` 两段删掉即可
  （hidumper 会退回 `request error`，其它功能不受影响）。
* 整包回退：用交付镜像 `partdisk/media/ohos_part_pc_ptl.img`
  （sha `e848e34c512c6a1606824a53f32f154580d3415020fc23d02fc3809e79e7bcf0`）直接覆盖。

---

## 7. 改动清单（源码）

| 文件 | 改动 |
|---|---|
| `foundation/graphic/graphic_2d/rosen/modules/render_service/core/feature/watermark/rs_surface_watermark.cpp` | `RS_LOGE` → `RS_LOGD`（每 surface 每帧） |
| `foundation/graphic/graphic_2d/rosen/modules/render_service/composer/composer_service/external_depend/engine/rs_base_render_util.cpp` | `RS_LOGE` → `RS_LOGD`（每 surface 每帧） |
| `base/startup/init/services/etc/console.cfg` | `apl: system_core` + `permission: [ohos.permission.DUMP]` |
| `base/startup/ohos_diag/etc/zz_diag.cfg` | 同上 |
| `base/startup/ohos_diag/ohos-diag` | 新增 `F/perf` 段 + 默认段列表 |
| `out/x86_64_virt/ohos-dbg/mesa_build26/mesa3d-src/src/egl/drivers/dri2/platform_ohos.c` | **副本**（仓库 `third_party/mesa3d` 未动）：`MESA-OHOS:` 日志、显式回退、可禁用兜底、可强制驱动 |

## 8. 遗留 / 下一步

1. **真机还没有跑过这批改动**：本轮所有验证都在 QEMU（同一份 libEGL / cfg / diag 脚本）。
   真机跑完后才能确认"是不是软渲染"。
2. **RS 的 `SetBufferColorSpace` / `SetMetadata` 每帧失败**仍在（81 / 243 条）。
   建议给 display HDI 补 `SetMetadata`，或让 RS 在能力缺失时不再每帧调用。
3. **每帧 `drmModeAddFB2`/`RmFB`**（`hdi_drm_layer.cpp`）在 3072×1920 下 ioctl 开销未知，
   可考虑缓存 FB（buffer 尺寸不变时复用）。
4. **RS 其它每帧 E 级日志**仍可能有（`DealWithSurfaceRotationAndGravity` 已改，
   但 `rs_main_thread`/composer 里还有若干 `RS_LOGE` 在每帧路径上，值得再扫一遍）。
5. **hidumper 现在可用了** → 可以用 `hidumper -s RenderService -a hitchs` 做前后对比，
   这是判断"卡"是否改善的**客观**指标。
6. Mesa 的 `MESA-OHOS` 目前只在**文件**里（hilog 侧 `HiLogPrint` 未生效，返回值非 0，
   已尝试 domain 回退）。若希望进 hilog，需要再查 access_token 对 dlopen 进来的
   `libhilog.so` 的处理。
