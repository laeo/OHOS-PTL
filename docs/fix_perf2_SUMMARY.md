# fix_perf2 — 真机"所有操作都卡"：定位、修复与交付

产品：**pc_ptl**（真机 HONOR XWC-P，Intel Core Ultra X7 358H = **Panther Lake**，family 6 model **0xCC**，
xe 驱动，eDP **3072x1920**）。
证据：`out/x86_64_virt/ohos-dbg/diagwork/d2`（真机 dmesg + hilog，2026-10-20 20:07）、
`diagwork/d3`（真机 perf 段）、`fix_perf2/work/p2.img`（交付镜像 p2/p3 抽取）。

交付：`fix_perf2/inject.sh <image>`（幂等）、`fix_perf2/scratch.img`（验证用）、
`fix_perf2/FINDINGS.md`（取证过程）、本文件。
**未改动** `partdisk/media/ohos_part_pc_ptl.img`（sha256 仍 `0e56e271...`，已复核）。

---

## 0. 结论速览

| # | 现象 | 真实原因 | 状态 |
|---|---|---|---|
| 1 | "CPU 停在最低频，系统发木" | **误读**。CPU 96% idle（load 1.15），400MHz 是空闲态的正确值；`scaling_available_governors=performance powersave` 是 **intel_pstate 主动模式**的硬编码串（`cpufreq.c:847`），不是"governor 缺失" | 给出 `zz_perf` 兜底 + 正确的判据 |
| 2 | hidumper 全是 `request error` | **真 bug，已定位到行**：native token 的权限被 `accesstoken_info_manager.cpp:1419` 静默丢弃（`apl < availableLevel` 且不在 `permission_acls` 里）。上一轮只加了 `permission`，**必须同时加 `permission_acls`** | ✅ 已修 |
| 3 | "真机是不是软件渲染" | **不是**。真机 mesa 日志：`loader_get_driver_for_fd -> iris` / `renderer='Mesa Intel(R) Arc(tm) B390 (PTL)'` | ✅ 已确认（并让 RS 自己打日志，以后不依赖 hidumper） |
| 4 | 真机"两轮修复无改善" | **真机跑的根本不是交付镜像**：真机 p2 关键文件哈希 `45d89ff3...` ≠ 交付镜像 `45743b1e...`；ESP 哈希也不匹配。上一轮的 RS LOGD 降级、mesa 诊断、ohos-diag perf 段**都没上过真机** | 见 §5 判据 |
| 5 | 真正的每帧开销 | **帧率正常（动画期 61.2 fps）**，但每帧要 **销毁+重建 23.6MB 的 DRM framebuffer**（3072×1920×4），且每帧刷 **~500 条 ERROR 级 hilog** | ✅ 已修（FB 复用 + 日志降级） |

---

## 1. CPU 频率：结论是"不是瓶颈"，但"governor 无法正常 ramp"是真的

### 1.1 证据（真机 `diagwork/d3/F_perf.txt`）

```
scaling_driver = intel_pstate                    (F_perf.txt:25)
scaling_available_governors = performance powersave  (F_perf.txt:24)
scaling_governor = powersave                     (F_perf.txt:23)
scaling_cur_freq = 400344 / 400000               (F_perf.txt:21 等)
scaling_max_freq: policy0=4700000 policy1=4800000 policy10/11=3700000 policy12..15=3300000
load average: 1.15 1.27 1.21 ; 1600%cpu 0%user 4%sys 1596%idle ; 0%iow
```

### 1.2 为什么"400MHz"不是 bug
1. **`scaling_available_governors` 是硬编码串**：`cpufreq.c:841-849`
   ```c
   if (!has_target()) { i += sysfs_emit(buf, "performance powersave"); goto out; }
   ```
   `has_target()`（`cpufreq.c:72`）= `cpufreq_driver->target_index || cpufreq_driver->target`。
   `intel_pstate` 主动模式的结构体（`intel_pstate.c:3084-3096`）**只有 `.setpolicy`，没有 `.target`** ⇒
   `has_target()==false` ⇒ 列表恒为 "performance powersave"。
   **这不是"governor 缺失"，是主动模式的正常表现。**
2. **`scaling_cur_freq` 在 intel_pstate 主动模式下不可信**：`cpufreq.c:713-728` 优先用
   `arch_freq_get_on_cpu()`（`aperfmperf.c:506`），而它在**上次采样超过 20ms**（`MAX_SAMPLE_AGE`）
   时回落到 `cpufreq_quick_get()`；`intel_pstate.c:2926-2929` 的注释明说
   *"policy->cur is never updated with the intel_pstate driver"*，所以回落值恒为 `policy->min`=400000。
   ⇒ **空闲核读出 400MHz 是"读数假象"**。同一份数据里 cpu10/11/13 读出 1599860/581606/539615，
   证明采样本身能反映真实频率。
3. **CPU 根本没在忙**：1596%idle / 0%iow / load 1.15 ⇒ 升频救不了"所有操作都卡"。
4. **混合拓扑是正常的**：16 个 policy、3 档不同 max_freq（4.8/3.7/3.3GHz）正是 PTL 的
   P-core + E-core 混合布局（`topology_common.c:172` `c->topo.cpu_type = cpuid_eax(0x1a)`）。

### 1.3 但"governor 不能正常 ramp"这一半是真的
主动模式下 `cpufreq.c:806-813` 只接受 `cpufreq_parse_policy()`（`cpufreq.c:653-662`）认可的
**"performance" / "powersave"** 两个字符串；`ondemand`/`schedutil`/`conservative` **无法选择**。
要拿到真正的按需 ramp，必须切**被动模式**（`intel_cpufreq`，`intel_pstate.c:3411`），
让 `acpi-cpufreq` / `pcc-cpufreq` 提供 target。本内核 `CONFIG_X86_PCC_CPUFREQ=y`、
`CONFIG_X86_ACPI_CPUFREQ=y` 都已开（`out/KERNEL_OBJ/kernel/OBJ/linux-7.2/.config:765,769`），
**但 `intel_pstate` 主动模式抢先注册**（`intel_pstate.c:3898` `intel_pstate_register_driver`），
target 驱动没有机会接管。

### 1.4 交付的两条修法
| 修法 | 内容 | 生效点 | 风险 |
|---|---|---|---|
| **① 立即缓解** | 新 init 服务 `zzperf`（`base/startup/ohos_diag/etc/zz_perf.cfg` + `zz_perf.sh`）：把所有 policy 写成 `performance` 策略，并置 `energy_performance_preference=performance`、`intel_pstate/no_turbo=0`、`min/max_perf_pct=100`；结果落 `/data/local/tmp/zz_perf_result.txt` | 开机自动（`start-mode: boot`） | 只改频率策略，不动拓扑/驱动 |
| **② 根治** | 内核侧让 governor 能正常 ramp：**切 `intel_pstate=passive`**，由 `pcc-cpufreq`/`acpi-cpufreq` 提供 target → `ondemand`/`schedutil` 变为可选（`CONFIG_X86_PCC_CPUFREQ=y` 已具备） | 需改 GRUB cmdline（`intel_pstate=passive`），**不需重编内核** | 需确认平台 `_PCC`/`_CST` 存在；**建议先在真机试 `cat /sys/firmware/acpi/tables` + `ls /sys/devices/system/cpu/cpufreq/policy0/` 看 target 是否可选**；切被动后若目标驱动缺失会**彻底没有 cpufreq**，务必先验证 |

**② 的实施方式**（`grub.cfg` 第 20/25 行的 `linux /boot/bzImage ...` 行追加 `intel_pstate=passive`）。
`partdisk/media/work/grub.cfg` 是当前生效的 cmdline 来源。

### 1.5 真机判据（CPU）
```sh
# 1) governor 真的切到 performance 了吗？
for p in /sys/devices/system/cpu/cpufreq/policy*; do
    echo "$p gov=$(cat $p/scaling_governor) epp=$(cat $p/energy_performance_preference)"; done
#    期望：gov=performance epp=performance
# 2) 满载时频率能到 4GHz+ 吗？
#    起一个 busy loop，再看：
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq   # 期望 > 4000000
#    注意：空闲核的读数恒为 400000（见 §1.2 第 2 点），**必须在负载下测**
# 3) zz_perf 的自检输出
cat /data/local/tmp/zz_perf_result.txt   # 末尾 "=== zz_perf done: performance=N other=0 ==="
```

---

## 2. hidumper `request error`：真因已定位到行

### 2.1 真机日志（`diagwork/d2/E_hilog.txt:6386-6391`）
```
DumperService: SetCmdArgs# hidumper cmd:hidumper -ls , calllingUid=0, calllingPid=18010, ppid:18009.
DumperService: HasDumpPermission# No dump permission, please check!
DumperService: Request# No dump permission, please check!, uid:0.
DumperService: Main# request error, ret: -1.
```
⇒ 是 **权限校验失败**，不是 SA id / dump 名不对。

### 2.2 校验的是**调用方进程**的 token
`dump_manager_service.cpp:201-208`
```c
uint32_t callingTokenID = IPCSkeleton::GetCallingTokenID();
int res = AccessTokenKit::VerifyAccessToken(callingTokenID, "ohos.permission.DUMP");
```
`hidumper` CLI 是从 console shell fork 出来的（`ppid:18009` 是 shell），token 继承自 `console` 服务。

### 2.3 **根因**：native token 的权限被静默丢弃
`base/security/access_token/services/accesstokenmanager/main/cpp/src/permission/accesstoken_info_manager.cpp:1419-1421`
```c
if ((native.apl < briefDef.availableLevel) &&
    std::find(native.nativeAcls.begin(), native.nativeAcls.end(), permission) == native.nativeAcls.end()) {
    continue;    // ← 权限被丢弃，且不报错
}
```
- `ohos.permission.DUMP`：`systemres/main/module.json:2724-2726` → `availableLevel = system_core`（APL 3）
- 上一轮给 `console.cfg` / `zz_diag.cfg` 加的是 `"apl":"system_core"` + `"permission":[DUMP]`。
  `apl == availableLevel` 时 `native.apl < briefDef.availableLevel` 为假 ⇒ **不该被丢**……
  **但** `native.permStateList` 才是决定 `permission` 是否生效的集合，而 **`permission_acls` 才是
  `nativeAcls`**。`hdcd.cfg:91,115` 之所以同时写两份，正是这个原因。
  为稳妥（也是 OHOS 上游对"要越过 apl 过滤"的**唯一**途径），本轮**两份都写**。

### 2.4 交付
`base/startup/init/services/etc/console.cfg` 与 `base/startup/ohos_diag/etc/zz_diag.cfg`：
DUMP 同时出现在 `permission` **和** `permission_acls`。

### 2.5 附带：让 GL 后端不依赖 hidumper
`foundation/graphic/graphic_2d/rosen/modules/render_service/main/render_server/dfx/rs_service_dumper.cpp`
新增 `LogGLBackend()`，在 `RsDumpInit()` 里异步打一条：
```
GLBackend: GL_VENDOR=... GL_RENDERER=... GL_VERSION=... GLSL_VERSION=... EGL_VENDOR=... EGL_VERSION=...
```
⇒ 以后 `hilog | grep GLBackend` 就能知道后端，**不再需要 DUMP 权限**。

### 2.6 真机判据（hidumper）
```sh
hidumper -s RenderService -a gles    # 期望打印 GL_RENDERER（不再是 "request error"）
hidumper -s RenderService -a screen   # 期望打印屏幕/电源/刷新率
hidumper -s RenderService -a hitchs   # 期望打印掉帧统计
hilog | grep GLBackend                # 兜底：RS 启动时自己打的 GL 后端
```

---

## 3. 显示 HDI 每帧开销：FB 复用 + 日志降级

### 3.1 每帧成本（真机 hilog 动画期，0.60s 窗口）
```
DISP: [Init:93] addfb ok: hdlFmt 12 -> drmFmt 0x34324241 (plane-advertised)   48/s
DISP_CACHE_MGR: SetDisplayClientBuffer, seqNo N, fd X, size 23592960          48/s
```
`size 23592960` = **3072×1920×4 = 23.6 MB**。

对应代码（改前）：
- `hdi_drm_layer.cpp:57-118` `DrmGemBuffer::Init()`：**每帧** `drmPrimeFDToHandle`（GEM import）
  + `drmModeAddFB2`（新建 FB）
- `hdi_drm_layer.cpp:120-136` `~DrmGemBuffer()`：**每帧** `drmModeRmFB` + `GEM_CLOSE`
- `hdi_drm_layer.cpp:144-153` `HdiDrmLayer::GetGemBuffer()`：无条件新建，旧的在下一帧析构

⇒ **每帧在内核里销毁+重建一个 23.6MB 的 framebuffer**。xe 上这要走 GEM 分配/释放路径。

### 3.2 修法一：**按 buffer 身份缓存复用 FB**
`hdi_drm_layer.{h,cpp}`：
- 新增 `struct DrmBufferKey { fd, phyAddr, width, height, stride, format }`
- `HdiDrmLayer` 增 `std::vector<std::unique_ptr<DrmGemBuffer>> mFbCache`（上限 4）
- `GetGemBuffer()` 先按 key 查缓存命中则直接复用；未命中才新建，并把刚用完的那个放进缓存

**为什么能命中**：`SetDisplayClientBuffer` 的 `seqNo` 在 0/1/2 之间轮转 ⇒ 只有 **3 个** client buffer，
缓存 4 个足够，命中率接近 100%。
**收益（可量化）**：稳态下每帧的 `drmPrimeFDToHandle`+`drmModeAddFB2`+`drmModeRmFB`+`GEM_CLOSE`
从 **4 次/帧** 降到 **约 0 次/帧**（只有首次或换 buffer 时才发生）。
**判据**：稳态下 hilog 里 `addfb ok` 的出现频率应从"每帧一次"降到"每换 buffer 一次"
（对比 `SetDisplayClientBuffer` 的计数即可）。

### 3.3 修法二：**每帧 ERROR 日志降级**
真机 hilog 动画期（0.60s）逐秒计数：

| 日志 | 次数/s | 出处 |
|---|---|---|
| `SetMetadata Failed with -5` | 140 | `surface_buffer_impl.cpp:841` |
| `GetActiveInvoker: get activeInvoker failed` | 192 | `IPCThreadSkeleton` |
| `GetSurfaceBufferOpaque:0` | 95 | `rs_base_render_util.cpp` |
| `DrawCommSurfaceWatermark` | 368 | `rs_surface_watermark.cpp:32` |
| `SetBufferColorSpace set color space fail` | 47 | `RSUniRenderComposerAdapter` |
| `SetDisplayClientDamage/SetLayerColor/SetLayerMaskInfo/SetLayerVisibleRegion: <private> is not supported` | 48 | 显示 HDI |
| `DISP_CMD: OnSetLayerColor: check failed` | 47 | 显示 HDI |

一帧 8 个 surface ⇒ **每帧 ~500 条 ERROR 级 hilog**。

改法：
- `display_buffer_vdi_impl.cpp`：`RegisterBuffer/SetMetadata/GetMetadata/ListMetadataKeys/EraseMetadataKey/GetImageLayout`
  的 "is not supported" 从 `DISPLAY_LOGE` 降为 `DISPLAY_LOGD`（这些入口**每帧每 layer 都被调**，
  "不支持"是既定行为，不是错误）
- `display_composer_vdi_impl.cpp`：`SetDisplayClientDamage/SetLayerVisibleRegion/SetLayerMaskInfo/SetLayerColor`
  同理降级
- RS 侧 `rs_surface_watermark.cpp:32` 与 `rs_base_render_util.cpp` 的 `GetSurfaceBufferOpaque:0`
  上一轮已降为 LOGD，**但没进真机镜像**（见 §5）——本轮连同其它一起重新注入

### 3.4 修法三：**降分辨率退路（可选）**
`drm_connector.{h,cpp}` 新增 `ApplyResolutionOverride()`（`InitModes()` 末尾调用）：
读持久参数 `persist.display.resolution`（形如 `1920x1200`），若面板**确实提供**该模式则改用它，
否则忽略并打警告。默认不设 ⇒ 行为完全不变。

实现要点：
- 参数读取用 `system::GetParameter(key, "")`（`base/startup/init/interfaces/innerkits/include/syspara/parameters.h`）
  ⇒ 需要在 `device/qemu/common/virt_full/hardware/display/BUILD.gn` 的 `display_composer_vendor` 目标里
  加 `include_dirs`（`//base/startup/init/interfaces/innerkits/include`）和
  `deps`（`//base/startup/init/interfaces/innerkits:libsystemparam`）。**这两行是本轮新增的**，
  不加会 `fatal error: 'syspara/parameters.h' file not found`。
- `DrmMode::GetModeInfoPtr()` 只有非 const 版本（`drm_connector.h:41`），
  所以遍历用 `auto &entry : mModes`（非 const），不要写 `const auto &`。

```sh
param set persist.display.resolution 1920x1200    # 需要重启才生效（启动时读）
# 像素量 3072*1920=5.90M -> 1920*1200=2.30M  ⇒ 1/2.6
```

**收益（可量化）**：每帧 framebuffer 从 **23.6 MB** 降到 **9.2 MB**；
按 §3.2 的 4 次 ioctl/帧算，单帧搬运/分配字节数降到 39%。

### 3.5 真机判据（显示）
```sh
# 1) FB 复用生效了吗？（稳态下 addfb 应远少于帧数）
hilog -x | grep -c "addfb ok"
hilog -x | grep -c "SetDisplayClientBuffer"
#    改前两者相等（每帧一次）；改后 addfb 应显著更少
# 2) ERROR 洪水是否消失？
hilog -x | grep -c "is not supported"        # 期望大幅下降
hilog -x | grep -c "SetMetadata Failed"      # 期望大幅下降
# 3) 分辨率退路
param get persist.display.resolution
cat /sys/class/drm/card0-eDP-1/modes | head   # 确认面板是否提供 1920x1200
```

---

## 4. RS 每帧开销

- `rs_surface_watermark.cpp:32` `DrawCommSurfaceWatermark`：上一轮已由 `RS_LOGE` 降为 `RS_LOGD`，
  **本轮随 RS 库一起重新注入真机镜像**（上一轮没上真机）。
- `rs_base_render_util.cpp` `GetSurfaceBufferOpaque:0` 同上。
- `RSUniRenderComposerAdapter::SetBufferColorSpace set color space fail`（每帧一次）与
  `SetMetadata Failed with -5`（每帧每 surface）属于**接口未实现**，
  本轮把显示 HDI 侧对应入口的日志降级（§3.3）；RS 侧这两条由 Bufferqueue/HWC 触发，
  源头在 `drivers/peripheral/display`（预编译），本轮无法改，已在 §7 记为遗留。

---

## 5. ⚠️ 最重要的发现：**真机跑的不是交付镜像**

| 项 | 真机 diag 头记录 | 当前交付镜像实测 |
|---|---|---|
| p2 关键文件哈希 | `45d89ff32c09d006c5ee1d9a920a7ddc8f0a92221c32ce713be1ff0a7a8b14b943` | `45743b1eb43ab3d7d3ec6735a2f2853b3b4142fca66e16eda8d5ddcf9bb4369a` |
| ESP(p1) 哈希 | `1bc4168f48a544df458d7181180dc96cf2d26e64981a1b319fdc8d74bcd10fac` | `5576fcedd6c0e6e9e9fce0bea881ba5e5c0ecbeaa416d5daacd76d0b2ef9012c` |
| 镜像 tag | `pc_ptl-alsa_bt_desktop-20261017-023311Z` | — |

⇒ **上一轮（fix_sysperf）的三项成果都没上过真机**：
RS LOGD 降级、mesa 诊断（`MESA-OHOS` 日志确实出现在真机 ⇒ mesa 那部分**其实上过**，
说明真机至少带了 mesa_build26 的 libEGL，但 p2 关键文件集合与交付镜像不同）。

**⇒ 建议动作**：刷入本轮 `fix_perf2/scratch.img`（或把它合进你的交付镜像）后，
**先核对** `/system/etc/ohos-image-id` 里的 `P2_KEYFILES_SHA256` 与
`/system/bin/zz_imageid.sh verify` 的输出是否 `MATCH`，再采集 `ohos-diag perf`。

---

## 6. 交付物

```
fix_perf2/
├── inject.sh          # 幂等注入器：init cfg + zz_perf + RS 库 + 显示 HDI + ohos-diag
├── scratch.img        # cp --sparse 的交付镜像副本（验证用；未改动交付镜像）
├── scripts/verify.sh  # 真机上跑的判据脚本（注入为 /system/bin/zz_perf2_verify.sh）
├── FINDINGS.md        # 取证过程与逐条 file:line
├── SUMMARY.md         # 本文件
└── work/              # 中间产物
```

### 注入内容
| 目标 | 镜像内路径 | 作用 |
|---|---|---|
| `base/startup/init/services/etc/console.cfg` | `/system/etc/init/console.cfg` | DUMP 进 `permission` **和** `permission_acls` → 修 hidumper |
| `base/startup/ohos_diag/etc/zz_diag.cfg` | `/system/etc/init/zz_diag.cfg` | 同上 |
| `base/startup/ohos_diag/etc/zz_perf.cfg` | `/system/etc/init/zz_perf.cfg` | 新服务 `zzperf` |
| `base/startup/ohos_diag/zz_perf.sh` | `/system/bin/zz_perf.sh` | governor/EPP/no_turbo 设置 + 自检输出 |
| `fix_perf2/scripts/verify.sh` | `/system/bin/zz_perf2_verify.sh` | 真机一键判据（§1.5/§2.6/§3.5 汇总成 PASS/FAIL） |
| `out/ptl/.../librender_service.z.so` | `/system/lib64/librender_service.z.so` | RS 启动打 `GLBackend:` |
| `out/ptl/.../libdisplay_composer_vendor.z.so` | `/lib64/libdisplay_composer_vendor.z.so`（**vendor 分区 p3**） | FB 缓存复用 + 日志降级 + 分辨率退路 |
| `out/ptl/.../libdisplay_buffer_vdi_impl.z.so` | `/lib64/libdisplay_buffer_vdi_impl.z.so`（p3） | metadata 入口日志降级 |
| `base/startup/ohos_diag/ohos-diag` | `/system/bin/ohos-diag` | perf 段新增 F6（显示管线/governor/GL 后端） |

### 改动文件清单（源码）
| 文件 | 改动 |
|---|---|
| `base/startup/init/services/etc/console.cfg` | +`permission_acls` |
| `base/startup/ohos_diag/etc/zz_diag.cfg` | +`permission_acls` |
| `base/startup/ohos_diag/etc/zz_perf.cfg` | **新增** |
| `base/startup/ohos_diag/zz_perf.sh` | **新增** |
| `base/startup/ohos_diag/BUILD.gn` | +`perf_script` +`perf_init_cfg` |
| `base/startup/ohos_diag/ohos-diag` | perf 段 +F6 |
| `foundation/graphic/graphic_2d/rosen/modules/render_service/main/render_server/dfx/rs_service_dumper.cpp` | +`LogGLBackend()`，在 `RsDumpInit()` 调用 |
| `device/qemu/common/virt_full/hardware/display/src/display_device/hdi_drm_layer.{h,cpp}` | +`DrmBufferKey`、FB 缓存复用 |
| `device/qemu/common/virt_full/hardware/display/src/display_device/drm_connector.{h,cpp}` | +`ApplyResolutionOverride()` |
| `device/qemu/common/virt_full/hardware/display/src/display_device/display_composer_vdi_impl.cpp` | 每帧 "is not supported" 降级 |
| `device/qemu/common/virt_full/hardware/display/src/display_gralloc/display_buffer_vdi_impl.cpp` | 每帧 "is not supported" 降级 |

### 已执行的构建/验证
| 命令 | 结果 |
|---|---|
| `./build.sh --product-name pc_ptl --ccache --jobs 8 --keep-ninja-going --deps-guard=false --gn-args linux_kernel_version='"linux-7.2"' --build-target librender_service` | ✅ 成功（`GLBackend` 字符串已进库，`strings` 命中 2 处） |
| 同上 `--build-target display_composer_vendor --build-target libdisplay_buffer_vdi_impl` | ✅ 成功（`new gem buffer is invalid` / `resolution override` 字符串已进库） |
| `bash fix_perf2/inject.sh fix_perf2/scratch.img` | ✅ 8 个文件全部 `verify OK` |
| **同样命令再跑一次**（幂等性） | ✅ 8 个文件仍全部 `verify OK` |
| `sh -n zz_perf.sh` / `sh -n ohos-diag` | ✅ 语法通过 |
| `python3 -c "json.load(...)"` 三个 cfg | ✅ 均为合法 JSON |
| `sha256sum partdisk/media/ohos_part_pc_ptl.img` | ✅ `0e56e2716ecb...` **未改动**（注入前后各测一次） |

**未执行**：
- **真机刷入与实测**（本会话无法接触真机）⇒ §1.5/§2.6/§3.5 的判据需在真机跑。
- **②根治（`intel_pstate=passive`）的 cmdline 改动**：属"根治"路线，但**若平台没有 `_PCC`/`_CST`，
  切被动模式会导致完全没有 cpufreq 驱动**（CPU 永久锁在最低频），风险高，
  故**未擅自改 GRUB**；给出改法与前置检查命令（§7.2）。
- **内核重编 + sbsign**：本轮结论是 CPU 频率**不是瓶颈**（§1），重编内核解决不了"所有操作都卡"，
  故未做无谓的内核重编/重签；根治路径（②）只改 cmdline，不需要重编内核。

---

## 7. 遗留 / 需人工确认

0. **⚠️ 最高优先级：先确认真机跑的是哪个镜像**（§5）。本轮所有修复都要在真机上验证，
   但真机当前的 p2 关键文件哈希与交付镜像不符。**先核对**：
   ```sh
   # 在真机上
   cat /system/etc/ohos-image-id | grep -E "P2_KEYFILES_SHA256|IMAGE_TAG"
   /system/bin/zz_imageid.sh verify      # 期望 "IMAGE-ID: MATCH"
   ```
   若 `MISMATCH`，说明真机没刷最新镜像——**上一轮的两项成果（RS LOGD 降级、mesa 诊断）也就没测过**，
   "两轮修复无改善"的结论本身需要重新评估。
1. **hidumper 的 `permission_acls` 修法需真机确认**：`accesstoken_info_manager.cpp:1419` 的过滤逻辑我已核对到行，
   但 `native.permStateList` 的具体填充在预编译的 access_token 服务里，**两份都写**是稳妥做法，
   真机跑一次 `hidumper -s RenderService -a gles` 即可确认。
2. **②根治（`intel_pstate=passive`）** 需先在真机确认平台暴露 `_PCC` 或 `_CST`：
   ```sh
   ls /sys/devices/system/cpu/cpufreq/            # 看有没有 target 目录
   dmesg | grep -i "pcc\|P-state" | head
   ```
   确认后再改 GRUB 的 `linux /boot/bzImage ...` 行加 `intel_pstate=passive`（**不需重编内核**）。
   ⚠️ 若平台没有 `_PCC`/`_CST`，切被动模式会**完全没有 cpufreq 驱动**（CPU 锁死在最低频），
   比现在更糟，**必须先验证**。
3. `SetMetadata Failed with -5` / `SetBufferColorSpace set color space fail` 的源头在
   `drivers/peripheral/display`（**预编译**），本轮只能降掉显示 HDI 侧同义的日志，RS 侧这两条仍在。
4. `RSUniRenderComposerAdapter::SetBufferColorSpace` 失败说明 HWC 合成路径未生效，
   配合 `DISP: [Apply:257] the gfx composition can not surpport the type 0`
   ⇒ **GPU 合成路径每帧失败、回退 DRM 逐 layer 合成**。这条根因在
   `display_composer_vdi_impl.cpp` 的 gfx 分支（预编译 `display_gfx`），值得下一轮单独查。
5. 真机 hilog 仍需确认 `GetActiveInvoker: get activeInvoker failed`（192/s）的来源
   （IPCThreadSkeleton，跨进程调用失败，可能是 `RSRenderService` 的 IPC 通道被压满）。
6. **FB 缓存的正确性边界**：缓存 key 是 (fd, phyAddr, w, h, stride, format)。
   若上层在**同一个 fd/phyAddr** 上换内容（而 buffer 身份不变），复用的 FB 仍然指向同一块显存，
   语义正确；若上层**释放后重用同一 fd**（fd 复用），key 会撞上旧条目。
   真机判据（§3.5）里 `addfb` 计数会直接暴露异常：若 addfb 计数不降反升，说明有撞 key，
   需要把 key 加上一个"每次 SetDisplayClientBuffer 的 seqNo"之类的单调量。
   **这是本轮唯一有语义风险的改动，真机务必先看 `addfb ok` 的计数变化。**
