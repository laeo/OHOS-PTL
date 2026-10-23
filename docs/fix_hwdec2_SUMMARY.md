# fix_hwdec2 —— Intel 硬解探针修复（oneVPL DataLength + libva DRI 路径 + 音频判据）

**任务**：真机（pc_ptl / Intel PTL / xe）上 `hwdec_probe` 报
`HWDEC: FAIL DecodeHeader sts=-10` → 要求定位并修好驱动搜索路径、VA 显示打开、
oneVPL 调用参数，产出可注入的 `inject.sh`，并顺手修 `ohos-diag` 的音频误报。

* 工作目录：`out/x86_64_virt/ohos-dbg/fix_hwdec2/`
* 树内改动（**只有 3 个文件**）：
  * `device/pc/ptl/hwdec_probe/hwdec_probe.c`（探针重写，v1 → v2）
  * `device/pc/ptl/hwdec_probe/hwdec_probe.sh`（驱动搜索路径环境变量）
  * `base/startup/ohos_diag/ohos-diag`（音频判据）
* **交付镜像未改动**：`partdisk/media/ohos_part_pc_ptl.img`
  sha256 仍为 `575eefcc45fe0146c3a57f4fb9d8cb4bf8e42f76a75fff7fcb8c4c6082e1a129`
  （注入只做在 `fix_hwdec2/scratch.img` 稀疏副本上）。

---

## 0. 结论速览

| 项 | 状态 |
|---|---|
| `DecodeHeader sts=-10` 的真正原因 | **`mfxBitstream.DataLength` 从未赋值 → 运行时看到的是"空码流" → 返回 `MFX_ERR_MORE_DATA`**（-10 **不是** `MFX_ERR_INVAL`） |
| libva 编译期 DRI 路径指向宿主暂存目录 | **确实是真 bug**，已用 `-Ddriverdir=/vendor/lib64/dri` 重编修复；另有 `LIBVA_DRIVERS_PATH` / `LIBVA_DRIVER_NAME` 兜底 |
| 上一版 `vaInitialize rc=3` | **是探针自己用错 API 造成的假警报**（`vaInitialize(&dpy)` 且 `dpy==NULL` → 必然返回 `VA_STATUS_ERROR_INVALID_DISPLAY=3`），根本没测到驱动 |
| oneVPL 解码通路 | **已在本机真实 Intel PTL GPU 上跑通**（同一份设备样本，60 帧，512x384，cpu_ratio≈41%） |
| 纯 VA-API 通路 | 显示/驱动探测 OK，但 iHD 的 AVC VLD 需要"经典 slice 参数缓冲"，`vaEndPicture` 仍返回 rc=18 → **留作遗留**，不影响 oneVPL 主路 |
| 探针输出 | 解码帧数 / 每帧耗时 / **CPU 占用（`CLOCK_PROCESS_CPUTIME_ID`）** / `cpu_ratio` 全部打印 |
| `inject.sh <image>` | ✅ 幂等、逐文件 sha256 自校验；**不碰交付镜像** |
| QEMU 验证 | ✅ 新探针在 OHOS musl 上跑起来，libva 正确找到 `/vendor/lib64/dri/iHD_drv_video.so`，无 Intel GPU 时**优雅失败退出 0** |
| `ohos-diag` 音频判据 | ✅ `aplay -D default` 的 "Resource busy"（audio_host 独占）不再误报 FAIL；新增 `aplay -D null` 与"独占者"两项 |

---

## 1. 根因一（决定性）：`mfxBitstream.DataLength` 没赋值 → `MFX_ERR_MORE_DATA`

### 1.1 `-10` 是什么

真机日志（`out/x86_64_virt/ohos-dbg/diagwork/d4/H_hwdec_probe.log`）：

```
HWDEC: FAIL DecodeHeader sts=-10
```

**`-10` 不是 `MFX_ERR_INVAL`**。oneVPL 2.x 的错误码表：

```
out/.../fix_hwdec2/onevpl_src/api/vpl/mfxdefs.h:285
    MFX_ERR_MORE_DATA                   = -10,  /*!< Expect more data at input. */
```

即"**输入端数据不足**"。这本身就是一条线索：**解码器根本没看到码流**。

### 1.2 v1 探针的 bug（file:line）

上一版探针（备份：`fix_hwdec2/evidence/hwdec_probe_v1.c.bak`）：

```c
434:    mfxBitstream bs;
435:    memset(&bs, 0, sizeof(bs));
436:    bs.Data = buf;
437:    bs.MaxLength = (size_t)fsize;      /* ← 只给了缓冲区大小 */
438:    bs.CodecId = codec;                /* ← DataLength 仍然是 0 !! */
...
495:        nalBs.Data = buf + nalOff;
496:        nalBs.MaxLength = nalLen;     /* ← 每个 NAL 也没给 DataLength */
```

`mfxBitstream.DataLength` 才是"**有效数据字节数**"，`MaxLength` 只是缓冲区容量。
oneVPL 运行时按 `DataLength` 判断"还有多少码流"，`DataLength == 0` ⇒
`DecodeHeader` 认为"头数据还没收全" ⇒ 返回 `MFX_ERR_MORE_DATA (-10)`。
**真机的 `-10` 与 QEMU 上的 `implementations found=0` 是两回事**：
真机上运行时、iHD 驱动、xe 都已经就位（`impl[0] name=mfx-gen … vendor=0x8086`），
唯一缺的就是"这段码流有多长"。

### 1.3 修法

v2 探针改成**官方 oneVPL 的喂流方式**（`VplFeedMore()`，
与 oneVPL hello-decode 样例同构）：

```c
/* 把没被消费的码流挪到缓冲区头部，再从文件追加 */
static int VplFeedMore(mfxBitstream *bs, FILE *f)
{
    if (bs->DataOffset > 0) { memmove(...); bs->DataLength = remaining; bs->DataOffset = 0; }
    bs->DataLength += (mfxU32)fread(bs->Data + bs->DataLength, 1, bs->MaxLength - bs->DataLength, f);
    ...
}
```

并且：

* `bs.DataLength` 由 `VplFeedMore()` 真实填充（`DataLength=191113 MaxLength=1048576`）；
* 参数补齐：`CodecId` / `FrameRateExtN=30,FrameRateExtD=1` / `NumThread=0` /
  `IOPattern=MFX_IOPATTERN_OUT_SYSTEM_MEMORY`；
* `DecodeHeader` 失败时**自动退回"最小参数集"再试一次**（有些运行时不吃 FrameRate）；
* 失败时把 `MFX_ERR_MORE_DATA` / `MFX_ERR_INVALID_VIDEO_PARAM` / `MFX_ERR_UNSUPPORTED`
  的名字一起打出来（不再只打一个数字）。

### 1.4 **决定性验证：在本机真实 Intel PTL GPU 上解出来了**

用**与设备完全相同的那份样本**（`moonlight.264`，191 113 B）编译一份 glibc 版探针，
在本机（Intel Core Ultra X7 358H / PTL / xe）上跑：

```
$ LD_LIBRARY_PATH=hwdec/build/vpl_install/lib:... timeout 120 ./build/hwdec_probe_host \
      hwdec/samples/h264_moonlight.264 evidence/host_moonlight.log 60 avc auto
HWDEC: vpl impl[0] name=mfx-gen api=2.17 accel_mode=0x400 impl=0x2 vendor=0x8086
HWDEC: vpl implementations found=1
HWDEC: vpl bitstream prepared: DataLength=191113 MaxLength=1048576 codec_id=541283905
HWDEC: vpl params: CodecId=541283905 FrameRate=30/1 NumThread=0 IOPattern=0x20
HWDEC: vpl header w=512 h=384 fourcc=NV12 profile=77 level=13      ← DecodeHeader 成功
HWDEC: vpl frame 1 decoded 512x384 fourcc=NV12 in 2.95 ms
HWDEC: vpl frame 2 decoded 512x384 fourcc=NV12 in 1.21 ms
HWDEC: vpl frame 3 decoded 512x384 fourcc=NV12 in 0.44 ms
HWDEC: vpl frame 30 decoded 512x384 fourcc=NV12 in 1.56 ms
HWDEC: vpl frame 60 decoded 512x384 fourcc=NV12 in 0.34 ms
HWDEC: vpl SUMMARY frames=60 format=NV12 512x384 wall_ms=51.0 cpu_ms=20.9 fps=1175.3 \
      cpu_ratio=40.9% min_frame_ms=0.33 max_frame_ms=2.95
HWDEC: RESULT=OK decoded_frames=60 cpu_ratio=40.9%
```

完整日志：`fix_hwdec2/evidence/host_moonlight.log`。
**同一条命令在修复前是 `DecodeHeader sts=-10`。**

---

## 2. 根因二：libva 编译期 DRI 路径指向宿主暂存目录（真 bug，已修）

### 2.1 现象

```
$ strings stage/usr/lib/libva.so.2.2500.0 | grep -i fix_hwdec
/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/fix_hwdec_probe/stage/usr/lib/dri
```

这个路径在设备上**不存在**（设备上的 iHD 驱动在 `/vendor/lib64/dri/iHD_drv_video.so`）。
它来自 libva 的 meson 选项：

```
out/.../fix_hwdec_probe/src/libva/va/meson.build:79
    c_args : ... ['-DVA_DRIVERS_PATH="' + driverdir + '"'],
```

上一轮构建用的是默认 `driverdir = <prefix>/lib`（= 宿主暂存目录）。
libva 优先用环境变量 `LIBVA_DRIVERS_PATH`（`src/libva/va/va.c:369-372`，
`":"` 分隔多目录，`ENV_VAR_SEPARATOR`），否则用编译期的 `VA_DRIVERS_PATH`。

### 2.2 修法（双保险）

1. **重编 libva，用设备路径**（`fix_hwdec2/stage/usr`）：

```sh
cd out/x86_64_virt/ohos-dbg/fix_hwdec2
export PKG_CONFIG_LIBDIR=$PWD/../fix_hwdec_probe/stage/usr/lib/pkgconfig
meson setup build/libva src/libva --cross-file ohos_x86_64_cross.ini \
      --prefix=$PWD/stage/usr --libdir=lib \
      -Ddriverdir=/vendor/lib64/dri \
      -Dwith_x11=no -Dwith_glx=no -Dwith_wayland=no -Dwith_win32=no -Ddisable_drm=false
ninja -C build/libva && ninja -C build/libva install
# 结果：strings libva.so.2.2500.0 | grep vendor → /vendor/lib64/dri
```

2. **环境变量兜底**（`device/pc/ptl/hwdec_probe/hwdec_probe.sh` + 探针内部）：
   `LIBVA_DRIVERS_PATH=/vendor/lib64/dri:/system/lib64/dri`、`LIBVA_DRIVER_NAME=iHD`
   —— **只在目录真实存在时才设置**，否则会破坏宿主/系统里已有的正确配置
   （这一点在宿主验证时踩到过，见 §2.3）。

### 2.3 QEMU 上的正向证据（驱动被找到了）

`fix_hwdec2/evidence/qemu_hwdec_probe.log`：

```
HWDEC: diag env LIBVA_DRIVERS_PATH=/vendor/lib64/dri:/system/lib64/dri
HWDEC: diag env LIBVA_DRIVER_NAME=iHD
HWDEC: diag file /vendor/lib64/dri/iHD_drv_video.so present size=42179104
...
libva info: VA-API version 1.25.0
libva info: User environment variable requested driver 'iHD'
libva info: Trying to open /vendor/lib64/dri/iHD_drv_video.so      ← 路径正确
libva info: Found init function __vaDriverInit_1_25
DRM_IOCTL_VERSION, unsupported drm device by media driver: virt  ← QEMU 是 virtio-gpu，不是 Intel GPU
libva error: /vendor/lib64/dri/iHD_drv_video.so init failed
HWDEC: diag vaInitialize(/dev/dri/renderD128) rc=18 (invalid parameter)
HWDEC: RESULT=FAIL reason=no_va_display
```

> 注意：探针把 **stderr 重定向进日志文件**，所以 libva / iHD 驱动自己的
> "Trying to open …" / "unsupported drm device …" 都能进 `/sys_prod/hwdec_probe.log`
> —— 这是本轮新增的诊断能力（v1 这些信息全丢在 stderr 里）。

---

## 3. 根因三：上一版的 `vaInitialize rc=3` 是**探针自己用错 API**（假警报）

v1（`evidence/hwdec_probe_v1.c.bak:348-357`）：

```c
int (*vaInit)(void **) = (int (*)(void **))dlsym(vah, "vaInitialize");
void *dpy = NULL;
int rc = vaInit(&dpy);              /* ← dpy 是 NULL！ */
```

libva 2.x 的 `vaInitialize` 签名是 `vaInitialize(VADisplay dpy, int *major, int *minor)`
（`src/libva/va/va.c:714`），并且第一行就

```c
src/libva/va/va_internal.h:49
#define CHECK_DISPLAY(dpy) if (!vaDisplayIsValid(dpy)) { return VA_STATUS_ERROR_INVALID_DISPLAY; }
```

`VA_STATUS_ERROR_INVALID_DISPLAY = 3`（`src/libva/va/va.h:267`）。
⇒ **`vaInitialize(&dpy)`（dpy=NULL）必然返回 3**，与驱动在不在毫无关系。
真机日志里的 `rc=3 (invalid VADisplay` 就是这么来的 —— **它没有测到任何东西**
（而且 `vaErrorStr` 的输出还被截断了）。

### 3.1 v2 的正确做法

```c
open("/dev/dri/renderD128")  →  vaGetDisplayDRM(fd)  →  vaInitialize(dpy, &major, &minor)
```

* 依次尝试 `renderD128` → `card0` → `card1`，打印每个节点的 `stat`（mode/uid/gid）；
* 打印 **完整的 rc + `vaErrorStr()`**（不再截断），并附 `VA_STATUS_ERROR_INVALID_DISPLAY` 常量对照；
* 打印 `vaQueryVendorString()`（真机上应出现 `Intel iHD driver for Intel(R) …`）；
* 服务是 root，权限 OK；另外把 `/dev/dri/*` 的权限一起打进日志。

---

## 4. 纯 VA-API 通路（备路）：现状与遗留

v2 里也实现了完整 VA-API 解码（`vaCreateConfig/vaCreateSurfaces/vaCreateContext/
vaCreateBuffer/vaRenderPicture/vaEndPicture` + 首帧非零像素校验），过程中修正了两个坑：

1. **`vaCreateBuffer` 的 `num_elements` 必须为 1**
   （Intel media driver：`media_ddi_decode_base.cpp:980`
   `if(type != VASliceParameterBufferType && numElements > 1) return VA_STATUS_ERROR_INVALID_PARAMETER;`）。
   传 `(total, total)` 会得到 `rc=18`。
2. **一个 picture 可能由多个 slice 组成**（本样本每帧 2 个 slice，
   `first_mb_in_slice` = 0 / 384），必须把同一 picture 的所有 slice
   **拼进同一个 slice data buffer** 再提交，否则只解出半张图。

修完这两点后，宿主（iHD 26.3.2）上的 VA 通路仍停在：

```
HWDEC: va EndPicture failed rc=18 (invalid parameter)
```

原因在 media driver 里：`SetDecodeParams()` 要求 `DecodeParams.m_numSlices != 0`
（`media_ddi_decode_base.cpp:673`），而该计数只在**经典 `VASliceParameterBufferType`**
分支里累加（`media_ddi_decode_avc.cpp:442`）—— 也就是说 iHD 的 AVC VLD 目前只支持
"逐 slice 显式提交 + slice 参数缓冲"这一种形式，而不是"整帧压缩数据一锅端"。
`oneVPL` 走的是 runtime 内部的解析路径，所以不受影响。

**结论**：主路（oneVPL）已在真实 GPU 上验证可用；VA 通路保留为"显示/驱动探测 +
将来实现 codec HDI 的参考实现"，本轮不强行打通。

---

## 5. 探针输出（真机判据用）

v2 探针每次开机自动跑（init 服务 `hwdec_probe`，`once`，root），输出到
`/sys_prod/hwdec_probe.log`（不可写则回落 `/data/local/tmp/hwdec_probe.log`），
同时进 hilog（tag `HWDEC`）。

关键行：

```
HWDEC: vpl impl[0] name=mfx-gen api=2.17 accel_mode=0x400 impl=0x2 vendor=0x8086
HWDEC: vpl implementations found=1
HWDEC: vpl bitstream prepared: DataLength=191113 MaxLength=1048576 codec_id=541283905
HWDEC: vpl header w=512 h=384 fourcc=NV12 profile=77 level=13
HWDEC: vpl frame 1 decoded 512x384 fourcc=NV12 in 2.95 ms
HWDEC: vpl frame 60 decoded 512x384 fourcc=NV12 in 0.34 ms
HWDEC: vpl SUMMARY frames=60 format=NV12 512x384 wall_ms=51.0 cpu_ms=20.9 fps=1175.3 \
      cpu_ratio=40.9% min_frame_ms=0.33 max_frame_ms=2.95
HWDEC: SUMMARY path=onevpl frames=60 wall_ms=51.0 cpu_ms=20.9 fps=1175.3 cpu_ratio=40.9%
HWDEC: RESULT=OK decoded_frames=60 cpu_ratio=40.9%
```

* **解码帧数**：`frames=N` / `decoded_frames=N`
* **每帧耗时**：`frame N decoded ... in X.XX ms` + `min_frame_ms` / `max_frame_ms`
* **CPU 占用**：`cpu_ms`（`clock_gettime(CLOCK_PROCESS_CPUTIME_ID)`）与
  `cpu_ratio = cpu_ms/wall_ms*100%` —— 判定"真硬件"的指标（越低越好）

---

## 6. `inject.sh`（幂等，不碰交付镜像）

```sh
cd /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/fix_hwdec2
bash package.sh                 # 收集产物 + 生成 manifest.txt
bash inject.sh <image>          # 注入（幂等，逐文件 sha256 自校验）
```

`inject.sh` 做的事：

* p2(system)：`/system/bin/hwdec_probe`（v2）、`/system/bin/hwdec_probe.sh`（带环境变量）、
  `/system/etc/hwdec/sample.h264`(+`sample_min.h264`)；
* p3(vendor)：`libvpl.so.2.17`、`libmfx-gen.so.1.2.17`(+`enctools.so`)、
  **重编的 `libva.so.2.2500.0` / `libva-drm.so.2.2500.0`（`-Ddriverdir=/vendor/lib64/dri`）**、
  `libdrm.so.2.134.0`、`libigdgmm.so.12.10.0`、`/vendor/lib64/dri/iHD_drv_video.so`、
  `/vendor/etc/init.hwdec_probe.cfg`；
* patch `/vendor/etc/init.pc_ptl.cfg`：`import` 增加 `"/vendor/etc/init.hwdec_probe.cfg"`
  （**必须是绝对路径**，OHOS init 的 import 先按参数名解析），`boot` job 末尾追加
  `"start hwdec_probe"`（放在 `/dev/dri/*` 的 chmod 之后）；
* 两个分区各一次 `e2fsck -f -y`；最后逐文件 sha256 读回校验。

### 6.1 本轮实测

```
$ cp --sparse=always partdisk/media/ohos_part_pc_ptl.img fix_hwdec2/scratch.img
$ bash fix_hwdec2/inject.sh fix_hwdec2/scratch.img
    OK: /lib64/libva.so.2.2500.0  sha256=c2c8ee0115e25ea8f6211da42953808c4071275876a1aa20bcf548cd5da17578
    OK: /system/bin/hwdec_probe   sha256=888c64daa783d9c0764fb8ce9973bc72f32af0e6ab286912173a6363a13e538f
    ... 20 个文件/软链全部 OK
=== OK: oneVPL hw decode stack injected into scratch.img
    (sha256 of image: 8f2125c32533366e1e27aa4fb4cb64c09b0e3bce513b88c25a73de15b989e0f2)
```

* `scratch.img` = 交付镜像的稀疏副本（**交付镜像本身 sha256 未变**）。
* 幂等：连跑两次，**每个文件的 sha256 完全一致**（第二次镜像级 sha 由
  `8f2125c3…` 变为 `745cb8a7…`，差异只来自 ext4 的 inode 时间戳与 journal，
  **内容幂等**）。

---

## 7. QEMU 验证（x86_64_virt，无 Intel GPU ⇒ 只能验"优雅失败"）

脚本：`prepare_qemu_test.sh`（造 system/vendor 副本 + 注入 + overlay）、
`launch_qemu_test.sh`（QEMU，VNC :28，串口 socket `run/ser.sock`，
通过 `work/qemu-hwdec2` 软链启动，避免被别的会话 `pkill qemu-system-x86_64` 误杀）。

结果（`fix_hwdec2/evidence/qemu_hwdec_probe.log`）：

* 探针二进制在 **OHOS musl x86_64** 上正常加载运行（`libvpl.so.2` 从 `/vendor/lib64` 解析到）；
* **libva 找到了 `/vendor/lib64/dri/iHD_drv_video.so`**（重编后的编译期路径生效）；
* 唯一失败原因是 QEMU 没有 Intel GPU：
  `DRM_IOCTL_VERSION, unsupported drm device by media driver: virt`；
* 探针**优雅失败、退出码 0**，`RESULT=FAIL reason=no_va_display`；
* init 服务开机自动跑通（`/sys_prod/hwdec_probe.log` 被创建）。

---

## 8. `ohos-diag` 音频判据修正（顺手项）

**问题**：真机 `aplay -D default` 报
`aplay: main:850: audio open error: Resource busy` → 被判 FAIL。
但这是**正常现象**：ALSA 设备被 OHOS 的 `audio_host` **独占**。

**改法**（`base/startup/ohos_diag/ohos-diag`）：

| 判据 | 之前 | 现在 |
|---|---|---|
| `audio/aplay-null-playback` | — | **新增**：`aplay -D null` 能播 ⇒ alsa-lib + PCM 通路 OK |
| `audio/aplay-default-playback` | 播不出 ⇒ FAIL | 播得出 ⇒ PASS；**"Resource busy" 且 `audio_host` 在跑 ⇒ PASS（注明独占）**；"Resource busy" 但没有 audio_host ⇒ WARN；其它 ⇒ FAIL |
| `audio/device-exclusive-owner` | — | **新增**：`audio_host` 运行中 ⇒ PASS（说明设备由 OHOS 音频服务独占） |

修复清单（`[修复清单]` 段）的期望值同步更新。

**验证**：把改后的 `ohos-diag` 注入 QEMU guest 实跑（`fix_hwdec2/evidence/qemu_verdict_audio.txt`）：

```
aplay -D null        | alsa+PCM 通路可用                | aplay -D null failed: ALSA lib ... snd_pcm_open_noupdate | FAIL
aplay -D default    | 播放成功，或设备被 audio_host 独占(Resource busy，非故障) | ... | FAIL
设备独占者           | audio_host 运行中                | audio_host running (pid 456) -> ALSA device is used exclusively by the OHOS audio server | PASS
```

（QEMU 里根本没有声卡，所以两条 aplay 都是 FAIL —— 这是**正确**的判定；
真机上应当是 `aplay -D null` PASS + `aplay -D default` PASS(独占) + `设备独占者` PASS。）

---

## 9. 真机判据（pc_ptl，Intel PTL）

```sh
# 1) 探针日志
cat /sys_prod/hwdec_probe.log        # 或 /data/local/tmp/hwdec_probe.log
# 期望：
#   HWDEC: vpl header w=512 h=384 fourcc=NV12 profile=77 level=13
#   HWDEC: vpl frame N decoded 512x384 fourcc=NV12 in X.XX ms
#   HWDEC: SUMMARY path=onevpl frames=N wall_ms=.. cpu_ms=.. fps=.. cpu_ratio=..%
#   HWDEC: RESULT=OK decoded_frames=N cpu_ratio=..%

# 2) hilog
hilog -T HWDEC

# 3) 判定"真硬件"
#    cpu_ratio 很低（本样本宿主实测 40.9%，且 0.34~2.95 ms/帧）
#    + vpl impl name=mfx-gen accel_mode=0x400(VAAPI) vendor=0x8086
#    + 可选：dmesg 里出现 xe 的 exec queue / VIDEO_DECODE 记录
```

失败时探针**始终退出 0** 并写明 `reason=`（`no_implementation` / `no_va_display` /
`decode_header` / `no_frame_decoded` …），不会 panic、不会拖垮 init。

> 前置条件（与上一轮相同，本轮未改）：`/dev/dri/renderD128` 存在且权限 666
> （`init.pc_ptl.cfg` 的 boot job 已 chmod）；xe 固件已注入（§17）。

---

## 10. 回退

| 层次 | 怎么退 |
|---|---|
| 镜像 | **交付镜像没动过**（sha `575eefcc…`）。要退 `scratch.img`，直接重新 `cp --sparse` 一次即可 |
| 注入 | `debugfs -w -R "rm /vendor/lib64/..."` 逐个删 + 把 `/vendor/etc/init.pc_ptl.cfg` 的 import / `start hwdec_probe` 两行去掉；或直接用注入前的分区覆盖回去 |
| libva | 用 `fix_hwdec_probe/stage/usr/lib/libva.so.2.2500.0`（旧的、编译期路径指向宿主暂存目录的那份）覆盖回去即可（那时靠 `LIBVA_DRIVERS_PATH` 环境变量也能工作） |
| 探针 | `cp fix_hwdec2/evidence/hwdec_probe_v1.c.bak device/pc/ptl/hwdec_probe/hwdec_probe.c`；补丁见 `fix_hwdec2/evidence/hwdec_probe.patch` |
| `ohos-diag` | `cp fix_hwdec2/evidence/ohos-diag.old base/startup/ohos_diag/ohos-diag`；补丁见 `fix_hwdec2/evidence/ohos-diag-audio.patch` |

---

## 11. 遗留

1. **真机硬解尚未验证**（本轮没有 Intel GPU 机器）。宿主已证明同一份样本、同一套
   oneVPL 调用能解出 60 帧，但设备上的 `libmfx-gen`（自编 26.4.1）+ `libva 2.25`
   组合仍需真机确认。
2. **纯 VA-API 解码路径未打通**（iHD AVC VLD 需要经典 slice 参数缓冲），
   详见 §4。下一步若要写 OHOS codec HDI，建议直接走 oneVPL（省掉这一层）。
3. **HEVC 未测**：探针支持 `codec=hevc`，但设备里只有 H.264 样本
   （`hwdec/samples/hevc_sintel_272p_logo.265.part` 可裁一段塞进 `/system/etc/hwdec/`）。
4. `iHD_drv_video.so` 42 MB（各代 GPU kernel 二进制全带）；p3(vendor) 空间够，
   但如需瘦身可用 `-DENABLE_NONFREE_KERNELS=OFF` 重编。
5. 探针只在开机跑一次（`once`）；若要反复验证，可手工
   `/system/bin/hwdec_probe.sh`。
6. `mfxVideoParam` 目前用 `MFX_IOPATTERN_OUT_SYSTEM_MEMORY`；若将来要零拷贝，
   需要改用 video memory + `MFXVideoCORE_AllocFrame`（oneVPL 2.x 的
   `mfxVideoCORE` 接口）——本轮未做。

---

## 12. 目录索引

```
out/x86_64_virt/ohos-dbg/fix_hwdec2/
├── SUMMARY.md                     本报告
├── build_probe.sh                 探针构建（OHOS musl x86_64）
├── package.sh                     收集产物 + manifest.txt
├── inject.sh                      <image> 注入（幂等、pc_ptl 磁盘镜像）
├── inject_raw.sh                  <raw ext4 img> <p2|p3> 注入（QEMU 用）
├── prepare_qemu_test.sh           造 QEMU 验证镜像
├── launch_qemu_test.sh            QEMU 启动
├── ser_b64.py                     串口取文件（base64）
├── manifest.txt                   产物清单（含 sha256）
├── pkg/                           产物树（p2/..., p3/...）
├── stage/usr/                     **重编的 libva（-Ddriverdir=/vendor/lib64/dri）**
├── build/                         hwdec_probe（OHOS musl）+ hwdec_probe_host（glibc 验证版）
├── logs/                          构建日志
├── evidence/
│   ├── host_moonlight.log         ★ 宿主真实 GPU 上的 oneVPL 解码成功日志
│   ├── qemu_hwdec_probe.log       ★ QEMU 上新探针的完整日志（libva 找到驱动 + 优雅失败）
│   ├── qemu_verdict_audio.txt     ★ ohos-diag 音频段在设备 shell 上的实测 VERDICT
│   ├── hwdec_probe_v1.c.bak       旧探针备份
│   ├── hwdec_probe.patch          新旧探针 diff
│   ├── ohos-diag.old / .new       ohos-diag 改前/改后
│   ├── ohos-diag-audio.patch      ohos-diag 音频判据 diff
│   └── delivered_image_sha_before.txt
├── work/                          QEMU 用镜像副本 / 分区副本
└── scratch.img                    pc_ptl 磁盘镜像稀疏副本（已注入，未交付）
```
