# fix_hwdec_probe —— Intel oneVPL 硬件视频解码链路（移植 + 探针）

**任务**：让 OHOS（7.0 / musl / x86_64，产品 `pc_ptl` = Intel PTL/xe）具备硬件视频解码的
**用户态前置件**：oneVPL 运行时 + 探针 + init 服务 + 样本，并给出**注入脚本**。
**本轮不写 OHOS 的 codec HDI**（那是下一步）。

* 工作目录：`out/x86_64_virt/ohos-dbg/fix_hwdec_probe/`
* 树内新增：`device/pc/ptl/hwdec_probe/{hwdec_probe.c,hwdec_probe.sh,init.hwdec_probe.cfg,README.md}`
* 交付镜像**未改动**（`partdisk/media/ohos_part_pc_ptl.img` 保持原样），验证在
  `fix_hwdec_probe/scratch.img`（`cp --sparse` 副本）上做。

---

## 0. 结论速览

| 项 | 状态 |
|---|---|
| oneVPL dispatcher / GPU runtime / libva / libdrm / Intel media driver 交叉编译到 OHOS musl x86_64 | ✅ 完成（6 个组件，5 个上游仓库） |
| `hwdec_probe`（oneVPL API 解码 H.264，打印帧数/耗时/格式/CPU 占用） | ✅ 完成，`/system/bin/hwdec_probe` |
| init 服务（开机自动跑探针，日志 `/sys_prod/hwdec_probe.log`，hilog 前缀 `HWDEC:`） | ✅ 完成并在 QEMU 上验证自动触发 |
| H.264 样本（<2 MB） | ✅ `moonlight.264` 191 113 B（512×336，约 130 帧）+ `foreman_p16x16.264` 3 734 B（176×144，1 帧） |
| `inject.sh <image>`（幂等、含 init cfg 接线） | ✅ 完成，20 个文件逐个 sha256 自校验通过 |
| QEMU 结构化校验 | ✅ 探针在 OHOS musl 上跑起来、**优雅失败、退出 0、不 panic**；唯一失败原因是 QEMU 没有 Intel GPU |
| 真机硬解验证 | ⏳ **待真机**（判据见 §7） |

---

## 1. 链路与"oneVPL DRM 插件"的澄清（重要）

任务描述里说的"oneVPL 的 **DRM 插件**"，在上游并不存在这样独立的东西。实际链路是：

```
应用/探针
 └─ libvpl.so.2                  oneVPL **dispatcher**（intel/libvpl，Apache-2.0）
      └─ libmfx-gen.so.1.2       oneVPL **GPU Runtime**（intel/vpl-gpu-rt，MIT）—— 这就是"插件"
           └─ libva.so.2 / libva-drm.so.2 / libdrm.so.2
                └─ dri/iHD_drv_video.so   **Intel media driver**（intel/media-driver，MIT）
                     └─ libigdgmm.so.12    **gmmlib**（直接对 DRM 节点做 ioctl，含 xe exec queue）
                          └─ kernel: xe  →  DRM_IOCTL_XE_EXEC + XE_ENGINE_CLASS_VIDEO_DECODE
```

* 真正"用 DRM/xe exec queue 干活"的是 **Intel media driver（iHD）**：本树 media-driver
  26.4.1 里已经有 `media_driver/agnostic/Xe_M/Xe_XPM/codec`（xe 专用 codec 路径）与
  `media_softlet/agnostic/Xe3P_M_plus/...`（PTL 用），它经 `libigdgmm` 直接下发 xe 的
  exec queue（**不经过 libdrm**，见 §4 的 NEEDED 表）。
* 所以本轮移植的 5 个组件就是这条链路的全部用户态依赖；
  **内核不用改**（`kernel/linux/linux-7.2/include/uapi/drm/xe_drm.h` 已有
  `DRM_XE_ENGINE_CLASS_VIDEO_DECODE`，`xe_drm.h` 属内核 UAPI，libdrm 不提供）。

---

## 2. 上游源码与版本（全部放在 `out/.../fix_hwdec_probe/src/`，仓库源码未动）

| 组件 | 仓库 | 版本 / commit | 许可 | 角色 |
|---|---|---|---|---|
| libdrm | gitlab.freedesktop.org/mesa/libdrm | 2.4.134 `b97cbde15c5c` | MIT | DRM 用户态（`libmfx-gen`/libva-drm 依赖） |
| libva | github.com/intel/libva | 2.25.0 `f3fefceb192c` | MIT | VA-API（`libva.so.2` + `libva-drm.so.2`） |
| media-driver | github.com/intel/media-driver | 26.4.1 `911fe6cfab59` | MIT | iHD VA 驱动 `iHD_drv_video.so` |
| gmmlib | github.com/intel/gmmlib | master `733c91a19baa` | MIT | `libigdgmm.so.12`（media-driver 26.x 的必需依赖，见 §3） |
| oneVPL dispatcher | github.com/intel/libvpl（源码在 `onevpl_src/`） | 2.17.0 `674d015bcb29` | **Apache-2.0** | `libvpl.so.2` |
| oneVPL GPU Runtime | github.com/intel/vpl-gpu-rt（源码在 `vpl-gpu-rt/`） | 26.4.1 `c2052626b7f6` | MIT | `libmfx-gen.so.1.2`（dispatcher 的实现插件） |

> dispatcher 与 runtime **版本必须配对**：两者 `api/vpl/mfxdefs.h` 都是 `MFX_VERSION 2.17`
> （本轮选的这一对：dispatcher main ↔ runtime main）。混搭会被 dispatcher 以
> "API version" 不匹配拒掉。

### 2.1 交叉编译环境

* 工具链：**OHOS SDK native**（`prebuilts/ohos-sdk/linux/26.0.0/native`，clang 15.0.4，
  `--target=x86_64-linux-ohos`，sysroot = SDK `native/sysroot`（musl））
* 交叉文件（本任务自建）：
  * CMake：`fix_hwdec_probe/ohos_x86_64.cmake`
  * Meson：`fix_hwdec_probe/ohos_x86_64_cross.ini`
* 统一安装前缀：`fix_hwdec_probe/stage/usr`（`lib/` + `include/` + `lib/pkgconfig/`）
* C++ 静态（`-static-libstdc++`）→ 注入的 .so **不依赖设备 libc++.so 的 ABI**

### 2.2 构建命令（可复现）

```sh
cd /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/fix_hwdec_probe
export PKG_CONFIG_LIBDIR=$PWD/stage/usr/lib/pkgconfig

# 1) libdrm 2.4.134 (meson)
meson setup build/libdrm src/libdrm --cross-file ohos_x86_64_cross.ini \
      --prefix=$PWD/stage/usr --libdir=lib \
      -Dtests=false -Dvalgrind=disabled -Dudev=false -Dintel=disabled
ninja -C build/libdrm && ninja -C build/libdrm install

# 2) libva 2.25.0 (meson)
meson setup build/libva src/libva --cross-file ohos_x86_64_cross.ini \
      --prefix=$PWD/stage/usr --libdir=lib \
      -Dwith_x11=no -Dwith_glx=no -Dwith_wayland=no -Dwith_win32=no -Ddisable_drm=false
ninja -C build/libva && ninja -C build/libva install

# 3) Intel media driver 26.4.1 + gmmlib (cmake)；只建需要的两个 target
cmake -S src/media-driver -B build/media-driver \
      -DCMAKE_TOOLCHAIN_FILE=$PWD/ohos_x86_64.cmake -DCMAKE_INSTALL_PREFIX=$PWD/stage/usr \
      -DCMAKE_BUILD_TYPE=Release -DENABLE_NONFREE_KERNELS=ON -DBUILD_CMRTLIB=OFF
cmake --build build/media-driver --target iHD_drv_video igfx_gmmumd_dll -j 12
#   产物：build/media-driver/media_driver/iHD_drv_video.so (255 MB, 未 strip)
#         build/media-driver/gmmlib/libigdgmm.so.12.10.0 (3.6 MB)
#   strip 后：iHD_drv_video.so → 42 179 104 B，libigdgmm.so.12.10.0 → 1 167 080 B

# 4) oneVPL GPU Runtime 26.4.1 (cmake)
cmake -S vpl-gpu-rt -B build/vpl-gpu-rt -DCMAKE_TOOLCHAIN_FILE=$PWD/ohos_x86_64.cmake \
      -DCMAKE_INSTALL_PREFIX=$PWD/stage/usr -DCMAKE_BUILD_TYPE=Release
cmake --build build/vpl-gpu-rt -j 4 && cmake --install build/vpl-gpu-rt
#   产物：stage/usr/lib/libmfx-gen.so.1.2.17 (+ libmfx-gen/enctools.so)

# 5) oneVPL dispatcher 2.17.0 (cmake)
cmake -S onevpl_src -B build/libvpl -DCMAKE_TOOLCHAIN_FILE=$PWD/ohos_x86_64.cmake \
      -DCMAKE_INSTALL_PREFIX=$PWD/stage/usr -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_TESTS=OFF -DBUILD_EXPERIMENTAL=OFF -DENABLE_LIBDIR_IN_RUNTIME_SEARCH=ON
cmake --build build/libvpl && cmake --install build/libvpl
#   产物：stage/usr/lib/libvpl.so.2.17

# 6) 探针
bash build_probe.sh        # -> build/hwdec_probe
```

构建日志：`fix_hwdec_probe/logs/{libdrm,libva,md,rt,libvpl}_*.log`。
media-driver 单个 target 约 6~8 分钟（-j12），其余各 <1 分钟。

---

## 3. 移植中踩到的 4 个真问题（都已修，补丁可复现）

### 3.1 media-driver 26.x 需要独立的 `gmmlib` 仓库
26.x 把 `gmm` 拆出去了：`pkg_check_modules(igdgmm>=12.0.0)` 找不到就报错；
即使 `-DSKIP_GMM_CHECK=ON`，CMake 仍会 `add_subdirectory(../gmmlib/Source/GmmLib)`。
→ **解法**：再 clone `github.com/intel/gmmlib` 放在 `src/media-driver` 的**兄弟目录**
（CMake 里 `BS_DIR_GMMLIB = ${BS_DIR_SOURCE}/gmmlib/Source/GmmLib`）。

### 3.2 clang 不接受 `-std=c++14` 用于 C 源文件
media-driver 把 `-std=c++14` 放在**通用** compile options 里（对 C 也生效）；
GCC 只是警告，**clang 直接报错** `invalid argument '-std=c++14' not allowed with 'C'`
→ C 文件编译失败。
→ **解法**（`src/media-driver-ohos-port.patch`，2 文件 7 行）：
 1. `media_driver/cmake/linux/media_compile_flags_linux.cmake`：把 `-std=c++14` 从通用
    列表移除（C++ 仍由 `MEDIA_COMPILER_CXX_FLAGS_COMMON` 的 `-std=c++1y` 提供）；
 2. `Tools/bldsys/include/utils.cmake`：`bs_set_defines()` 里硬编的 `-std=c++11` 会覆盖
    掉 `-std=c++1y`（导致 `std::make_unique` 编译失败），改成 `-std=c++14`。

### 3.3 gmmlib 的 ULT 单元测试在交叉编译下必然失败
`cmake --build ... --target all` 会在最后跑 `Run_ULT`（宿主执行 OHOS musl 二进制）→
`no such file or directory` → 整个构建失败。
→ **解法**：只构建需要的 target：
 `cmake --build build/media-driver --target iHD_drv_video igfx_gmmumd_dll`。

### 3.4 OHOS init 的 `import` 必须是**绝对路径**
`base/startup/init/services/init/init_config.c:ParseAllImports()`：import 项先按
**参数名**查（`GetParamValue`），查不到才当路径用；而且**相对路径是相对 init 的 cwd**，
`"init.hwdec_probe.cfg"` 解析成 `/init.hwdec_probe.cfg` → 找不到 → **服务根本没注册**
（现场症状：`param get init.svc.hwdec_probe` 报 106，探针从不自动跑）。
→ **解法**：import 写绝对路径 `"/vendor/etc/init.hwdec_probe.cfg"`。
（设备 cfg 里原有的 `"init.${ohos.boot.hardware}.usb.cfg"` 其实是**相对路径、同样无效**的写法，
参考实现请用 wukong100 那种 `"/vendor/etc/init.${ohos.boot.hardware}.xxx.cfg"`。）

---

## 4. 产物清单（注入内容，sha256 见 `manifest.txt`）

### p2 = system（`/system/...`）
| 镜像内路径 | 大小 | 说明 |
|---|---|---|
| `/system/bin/hwdec_probe` | 15 880 B | 探针（OHOS musl x86_64，解释器 `/lib/ld-musl-x86_64.so.1`） |
| `/system/bin/hwdec_probe.sh` | 816 B | init 服务入口（remount sys_prod → 跑探针 → 复制日志到 /data/local/tmp） |
| `/system/etc/hwdec/sample.h264` | 191 113 B | H.264 Annex-B，512×336，约 130 帧（`moonlight.264`，samples.ffmpeg.org） |
| `/system/etc/hwdec/sample_min.h264` | 3 734 B | H.264 Annex-B，176×144，1 帧（`foreman_p16x16.264`） |

### p3 = vendor（`/vendor/...`）
| 镜像内路径 | 大小 | 说明 |
|---|---|---|
| `/vendor/lib64/libvpl.so.2.17` (+`libvpl.so.2` 软链) | 4 934 592 B | oneVPL dispatcher (Apache-2.0) |
| `/vendor/lib64/libmfx-gen.so.1.2.17` (+`libmfx-gen.so.1.2` 软链) | 17 893 488 B | oneVPL GPU Runtime 插件 |
| `/vendor/lib64/libmfx-gen/enctools.so` | 4 681 272 B | runtime 内部 helper（按相对路径 dlopen，必须同目录） |
| `/vendor/lib64/libva.so.2.2500.0` (+`libva.so.2`) | 731 504 B | libva 2.25.0 |
| `/vendor/lib64/libva-drm.so.2.2500.0` (+`libva-drm.so.2`) | 44 520 B | libva-drm |
| `/vendor/lib64/libdrm.so.2.134.0` (+`libdrm.so.2`) | 281 408 B | libdrm 2.4.134（树内 third_party/libdrm 的 soname 是 `libdrm.so`，不冲突） |
| `/vendor/lib64/libigdgmm.so.12.10.0` (+`libigdgmm.so.12`) | 1 167 080 B | gmmlib（iHD 的 DRM 层） |
| `/vendor/lib64/dri/iHD_drv_video.so` | 42 179 104 B | Intel media driver 26.4.1 VA 驱动（strip 后） |
| `/vendor/etc/init.hwdec_probe.cfg` | 233 B | init 服务定义 |
| `/vendor/etc/init.pc_ptl.cfg` | 已 patch | `import` 增加绝对路径 + `boot` job 增加 `start hwdec_probe` |

**为什么放 vendor 而不是 system**：pc_ptl 的 p2(system) 只剩 **23 MiB** 空闲，而这堆库
约 70 MB；p3(vendor) 有 **~477 MiB** 空闲。`/vendor/lib64` 也在 OHOS musl 的 namespace
搜索路径里（`/system/etc/ld-musl-namespace-x86_64.ini` 的
`namespace.default.lib.paths` 含 `/vendor/lib64`），所以放 vendor 完全可行。

### 依赖图（`readelf -d`，全部可解析）
```
hwdec_probe        -> libvpl.so.2, libhilog_ndk.z.so, libc.so
libvpl.so.2        -> libc.so
libmfx-gen.so.1.2  -> libdrm.so.2, libva-drm.so.2, libva.so.2, libc.so
libva-drm.so.2     -> libva.so.2, libdrm.so.2, libc.so
iHD_drv_video.so   -> libigdgmm.so.12, libc.so      ← 注意：不经 libdrm（gmmlib 直接做 DRM ioctl）
libigdgmm.so.12    -> libc.so
```

---

## 5. 探针（`device/pc/ptl/hwdec_probe/hwdec_probe.c`）

* oneVPL 2.x API：`MFXLoad` → 过滤（`Impl=hardware` / `CodecID` / `ApiVersion≥2.2`）→
  `MFXCreateSession` → `MFXVideoDECODE_DecodeHeader` → `Init` → 按 **NAL 逐个**
  `DecodeFrameAsync` → 帧 surface `Synchronize`。
* 码流：自己按 Annex-B 切 NAL（支持 3/4 字节 start code），按 NAL 投喂，
  规避 oneVPL 2.x 没有"已消费字节数"的问题。
* 输出（全部带 `HWDEC: ` 前缀）：
  * `HWDEC: impl name=... api=2.17 accel_mode=... impl_type=1 vendor=0x8086`
  * `HWDEC: header w=.. h=.. fourcc=NV12`
  * `HWDEC: frame N decoded 512x336 fourcc=NV12`
  * `HWDEC: SUMMARY frames=N nals=M format=NV12 512x336 wall_ms=.. cpu_ms=.. fps=.. cpu_ratio=..%`
  * `HWDEC: RESULT=OK decoded_frames=N` / `HWDEC: RESULT=FAIL reason=...`
* **永不 panic**：所有失败路径都打印原因并 `return 0`（init 服务不会因它反复重启）。
* 诊断（真机排障用）：`implementations found=N`、VA 层 `vaInitialize rc=.. (vaErrorStr)`、
  `dlopen(libmfx-gen.so.1.2) OK/FAILED`、hilog 自检各级别返回值。
* 日志双写：① 自身写日志文件（`/sys_prod/hwdec_probe.log`，不可写则回落
  `/data/local/tmp/hwdec_probe.log`）；② `OH_LOG_Print` 进 hilog（tag `HWDEC`，
  domain `0xD003C00`）。**注意 hilog 级别过滤会丢掉 `LOG_DEBUG`**，探针用 `LOG_INFO`，
  实测 `hilog_print_failures=0`。

---

## 6. QEMU 结构化校验（x86_64_virt，QEMU 里没有 Intel GPU）

> 脚本：`prepare_qemu_test.sh`（重建带注入的 system/vendor 副本 + overlay）、
> `launch_qemu_test.sh`（QEMU，VNC :28，串口 socket `run/ser.sock`，
> 通过 `work/qemu-hwdec` 软链启动以免被别的会话 `pkill qemu-system-x86_64` 误杀）。

**结论（原始输出见 `evidence/qemu_x86_64_virt_probe.log`）**：

```
HWDEC: hilog selftest ndk debug=-1 info=48 warn=48 error=49
HWDEC: start probe stream=/system/etc/hwdec/sample.h264 log=opened max_frames=120
HWDEC: stream loaded bytes=191113
HWDEC: codec=AVC
HWDEC: diag vaInitialize rc=3 (invalid VADisplay
HWDEC: implementations found=0
HWDEC: diag dlopen(libmfx-gen.so.1.2) OK
HWDEC: diag dlopen(/vendor/lib64/libmfx-gen.so.1.2.17) OK
HWDEC: diag dlopen(/vendor/lib64/libmfx-gen.so.1.2) OK
HWDEC: FAIL no oneVPL implementation loaded (no usable HW device?)
HWDEC: hilog_print_failures=0
HWDEC: RESULT=FAIL reason=no_implementation
PROBE_EXIT=0
```

即：

1. 探针二进制在 **OHOS musl x86_64** 上正常加载运行（loader 从 `/vendor/lib64` 解析到
   `libvpl.so.2`），**不 panic、退出码 0**；
2. dispatcher、GPU runtime、libva、libdrm、iHD 驱动**全部存在且可 dlopen**；
3. 唯一失败点是**没有可用的硬件设备**：QEMU 里 `/dev/dri/card0` 是 virtio-gpu
   （`card0-Virtual-1`），`vaInitialize()` 返回 3 → iHD 驱动拒绝该设备 →
   dispatcher 枚举到 0 个实现。**这正是 QEMU 无法验证硬解的原因**（与真机预期一致）：
   真机上是 Intel PTL + xe，iHD 驱动会接受 `/dev/dri/renderD128`。
4. **init 服务自动跑通**：开机后 init 的 `boot` job 执行 `start hwdec_probe`，
   `/sys_prod/hwdec_probe.log` 被创建（x86_64_virt 的 sys_prod 是 rw），
   `/data/local/tmp/hwdec_probe.log` 也有副本。
5. 探针脚本里 `mount -o remount,rw /sys_prod` 失败也不影响（回落路径）。

### 6.1 pc_ptl 磁盘镜像注入验证（scratch.img）
```
cp --sparse=always partdisk/media/ohos_part_pc_ptl.img fix_hwdec_probe/scratch.img
bash fix_hwdec_probe/inject.sh fix_hwdec_probe/scratch.img
```
结果：20 个文件/软链逐个 sha256 校验 **全部 OK**（输出见本节上文"产物清单"），
两个分区 `e2fsck -f -y` 通过，GPT/分区大小/其它分区未动。
**幂等性**：连续执行两次，第二次同样 20/20 OK、文件内容 sha256 完全一致；
镜像级 sha 会变（`9025e4a0…` → `c28b8d2b…`），因为 ext4 每次写都会更新 inode
时间戳与 journal —— 这是文件系统元数据差异，**内容幂等**。

---

## 7. 真机判据（pc_ptl，Intel PTL）

```sh
# 1) 探针日志（/sys_prod 若只读则用 /data/local/tmp 的副本）
cat /sys_prod/hwdec_probe.log
# 期望（成功）：
#   HWDEC: impl name=... api=2.17 accel_mode=... impl_type=1 vendor=0x8086
#   HWDEC: header w=512 h=336 fourcc=NV12
#   HWDEC: frame 1 decoded 512x336 fourcc=NV12
#   HWDEC: SUMMARY frames=130 nals=380 format=NV12 512x336 wall_ms=.. cpu_ms=.. fps=.. cpu_ratio=..%
#   HWDEC: RESULT=OK decoded_frames=130
# 失败时会有明确 reason：no_implementation / no_hw_session / decode_header / no_frame_decoded ...

# 2) hilog
hilog -T HWDEC            # 或 hilog -x | grep HWDEC

# 3) 关键中间量（判断到底卡在哪一层）
#    implementations found=0  -> iHD 没认到设备（/dev/dri/renderD128、xe 驱动、firmware）
#    vaInitialize rc=3        -> 同上（libva 层）
#    implementations found>0 但 create session 失败 -> 编码/解码 profile 不支持
```

硬件是否真的在解码：**`cpu_ratio` 应该很低**（几百帧解码若 CPU 占用接近 100%，
说明实际走了软解/回退）。更强的判据是 `dmesg`/`hilog` 里出现 xe 的
`exec queue`/`DRM_XE_ENGINE_CLASS_VIDEO_DECODE` 相关记录。

> 前置检查（真机）：
> * `/dev/dri/renderD128` 存在且权限 666 —— pc_ptl 的 `init.pc_ptl.cfg` boot job 已经
>   `chmod 666 /dev/dri/renderD128`，**本轮未改动**；
> * xe 固件（`i915/xe3lpd_dmc.bin`、`xe/ptl_guc_70.bin`…）已在 §17 注入；
> * 若 iHD 报 "no DRM device"，检查 `/sys/class/drm/renderD128/device/` 是否存在。

---

## 8. 回退

* **镜像级**：`inject.sh` 只做"rm + write"，回退 = 用注入前的分区覆盖回去
  （备份 `partdisk/media/ohos_part_pc_ptl.pre_batch6.img.zst` 之类）。
  由于只新增文件 + patch 一个 init cfg，回退也可以直接在镜像里删：
  ```
  debugfs -w -R "rm /vendor/lib64/libvpl.so.2" ... (逐个删)
  debugfs -w -R "rm /etc/init.hwdec_probe.cfg" ...
  # 并把 init.pc_ptl.cfg 里的 import / start hwdec_probe 两行删掉
  ```
* **代码级**：树内只新增了 `device/pc/ptl/hwdec_probe/`（4 个新文件），
  **没有修改任何既有仓库文件**；`git checkout`/删除该目录即可完全回退。
* 上游补丁只有 `src/media-driver-ohos-port.patch`（2 文件 7 行，在 `out/` 的副本里，
  仓库源码未动）。

---

## 9. 遗留 / 下一步

1. **真机硬解尚未验证**（本轮无 Intel GPU 机器）。真机跑完 §7 的判据后，才能确认
   "xe exec queue + iHD + oneVPL"在 PTL 上真的能解 H.264/HEVC。
2. **只做了 H.264 Annex-B 探针**；HEVC 走同一路径（`codec` 参数可切 `hevc`），
   但样本还没有 HEVC 版本。
3. **没有写 OHOS codec HDI**（任务边界）。下一步：用本轮这套 oneVPL 运行时，
   在 `drivers/peripheral/codec` 下实现一个 OHOS 视频解码 HDI（`OH_VideoDecoder_*`），
   让 ArkWeb/播放器通过 `native_media_vdec` 走硬解（而不是引擎内 ffmpeg 软解）。
4. **iHD 驱动 42 MB**（含各代 GPU kernel 二进制）。若 p3 空间紧张，可用
   `-DENABLE_NONFREE_KERNELS=OFF` 重新构建以裁掉闭源 kernel。
5. `iHD_drv_video.so` 是 26.4.1 的"全平台"构建；若真机上 iHD 认不到 xe 设备，
   可能需要换用与 PTL 更贴近的 media-driver 版本（Xe3P/Xe_M 路径已在 26.4.1 内）。
6. 探针目前只统计 CPU 时间（`CLOCK_PROCESS_CPUTIME_ID`）与墙钟；"是否走硬件"目前
   靠 `impl_type=hardware` + `accel_mode` + 低 `cpu_ratio` 间接判断，
   还没有直接读 xe exec queue 计数（可加 DRM fdinfo 统计）。

---

## 10. 目录索引

```
out/x86_64_virt/ohos-dbg/fix_hwdec_probe/
├── SUMMARY.md                  本报告
├── ohos_x86_64.cmake           CMake 交叉工具链（OHOS musl x86_64）
├── ohos_x86_64_cross.ini       Meson 交叉文件
├── build_probe.sh              探针构建脚本
├── package.sh                  收集产物 + 生成 manifest.txt
├── inject.sh                   <image> 注入（幂等，pc_ptl 磁盘镜像）
├── inject_raw.sh               <raw img> <p2|p3> 注入（x86_64_virt 的 .img 用）
├── prepare_qemu_test.sh        造 QEMU 验证镜像
├── launch_qemu_test.sh         QEMU 启动（VNC :28，串口 socket）
├── manifest.txt                产物清单（含 sha256）
├── pkg/                        产物树（p2/..., p3/...）
├── src/                        libdrm / libva / media-driver / gmmlib
│                               + media-driver-ohos-port.patch
├── onevpl_src/                 oneVPL dispatcher 源码 (github.com/intel/libvpl)
├── vpl-gpu-rt/                 oneVPL GPU Runtime 源码 (github.com/intel/vpl-gpu-rt)
├── stage/                      交叉编译安装前缀
├── build/                      构建目录 + hwdec_probe
├── sample/                     H.264 样本
├── logs/                       各组件构建日志
├── evidence/                   QEMU 证据
├── work/                       临时镜像/分区副本/日志
└── scratch.img                 pc_ptl 磁盘镜像副本（已注入验证）
```
