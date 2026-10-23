# ArkWeb 引擎编解码能力体检 + B 站视频「只有 mp4a / 只播一两帧」归因（2026-10-21）

> 任务：检查我们用的**社区预编译 x86_64 ArkWeb 引擎**（`ArkWebCore-x86_64.hap`，sha256 `50cd246f…`）
> 到底支持哪些**视频/音频解码器**，解释用户看到的「解码器好像是 mp4a」，并给出可落地的解法。
> **本轮未改动任何交付镜像**（`partdisk/media/ohos_part_pc_ptl.img` 仍为 `0e56e271…`／`f8486d46…` 系列，未触碰）。
>
> 产物目录：`out/x86_64_virt/ohos-dbg/fix_web_codec/`
> （`work/`=解包出的引擎库与探针，`evidence/`=命令输出，`scripts/`=可复跑脚本）

---

## 0. 一句话结论

1. **这个引擎是"含专有编解码器"的构建**：ffmpeg 里 **H.264（avc1）和 AAC（mp4a）都在**，
   还有 VP8 / VP9(libvpx) / AV1(dav1d) / MP3 / Opus / Vorbis / FLAC / Theora。
2. **唯一缺的是 HEVC/H.265**（`ff_hevc_decoder` **不存在**，Chromium M114 的
   `enable_hevc_parser_and_hw_decoder` 默认关闭 → 连 HEVC 解析器都没有），
   另外 **AC3/EAC3** 也没有。
3. 所以「只看到 mp4a」= **B 站给的那一路视频是 HEVC(`hev1`/`hvc1`) 或 AV1 轨，
   我们的引擎解不了 → 视频轨被丢弃/不出帧，只剩 AAC 音频轨（`mp4a.40.2`）在播**。
4. 「只播一两帧 + 极卡」是**另一个独立问题**：**完全没有硬件解码**
   （无 libva/VAAPI、OHOS 侧也没有 codec HDI 实现），H.264/AV1 全靠 CPU 软解，
   3072×1920 面板 + 1080p60 直播流 → CPU 打满。
5. **最省事的解法**：改自带浏览器（ArkTS）注入一小段 JS，把 **HEVC 从
   `MediaSource.isTypeSupported()` 里屏蔽掉** → B 站前端会自动降级到 AVC；
   再配 `onInterceptRequest` 把 playurl 的 `fnval=4048` 改成 `fnval=16`、
   直播的 `codec=0,1,2` 改成 `codec=0` 作为双保险。

---

## 1. 被检查的对象（指纹）

| 项 | 值 |
|---|---|
| HAP | `out/x86_64_virt/ohos-dbg/porting/vendor_opc/common/hap/ArkWebCore-x86_64.hap` |
| HAP sha256 | `50cd246f5058ee86e9cd96f4e00599f97f4af69daa594b7093a36a2cc619a063`（196,329,460 B） |
| module / 版本 | `entry` / `5.1.0.107`（bundle `com.ohos.arkwebcore`，`license_file_path=/system/etc/noticeFile/NWeb_OpenSource.html`） |
| **引擎内核版本** | **`Chrome/114.0.5735.197`**（= Chromium **M114**，2023-06） |
| `libs/x86_64/libarkweb_engine.so` | 164,924,848 B，sha256 `3a973c3ff67028f12c81c108ce65f91d8f3bb90dd0c9d2013af25a8c0ca50282` |
| `libs/x86_64/libffmpeg.so` | 2,712,088 B，sha256 `74ecc73d476d184fe42812874873ce86efd08253b3d59635b1e05763a76e3a93` |
| 其它 | `libarkweb_render.so` 1,628,992 B；`libarkweb_crashpad_handler.so` 2,672,752 B |

解包命令：
```sh
cd out/x86_64_virt/ohos-dbg/fix_web_codec/work
unzip -o -j ../../../porting/vendor_opc/common/hap/ArkWebCore-x86_64.hap 'libs/x86_64/*' -d libs
```

---

## 2. 引擎实际支持的编解码器清单（硬证据）

### 2.1 方法 A：ffmpeg 导出的 `ff_*_decoder` 数据符号（= 编进库的解码器全集）

Chromium 的 ffmpeg 把每个 AVCodec 描述符作为**动态数据符号**导出，
`avcodec_find_decoder()` 就是遍历这张表 → 导出了哪些 `ff_xxx_decoder`，
就等于**编进这个 .so 的解码器全集**。

```sh
cd out/x86_64_virt/ohos-dbg/fix_web_codec/work/libs
nm -D --defined-only libffmpeg.so | grep -E ' [DB] ff_.*_decoder$' | sort -k3
```
输出（完整，19 个）：
```
ff_aac_decoder          ff_aac_latm_decoder   ff_flac_decoder
ff_h264_decoder         ff_libopus_decoder    ff_mp3_decoder
ff_pcm_alaw_decoder     ff_pcm_f32le_decoder  ff_pcm_mulaw_decoder
ff_pcm_s16be_decoder    ff_pcm_s16le_decoder  ff_pcm_s24be_decoder
ff_pcm_s24le_decoder    ff_pcm_s32le_decoder  ff_pcm_u8_decoder
ff_theora_decoder       ff_vorbis_decoder     ff_vp3_decoder
ff_vp8_decoder
```
> **没有 `ff_hevc_decoder`**、没有 `ff_av1_decoder`、没有 `ff_vp9_decoder`（VP9 不走 ffmpeg，走 libvpx）、
> 没有 `ff_ac3_decoder` / `ff_eac3_decoder` / `ff_alac_decoder`。

### 2.2 方法 B：**运行期**直接问 ffmpeg（最硬的证据）

`libffmpeg.so` 的 `NEEDED` 只有 `libc.so`（musl 名字）→ 可以在**宿主机**用 glibc 直接
`dlopen` 它并调用 `avcodec_find_decoder_by_name()`。musl 版引用了 `atan/atanf`（glibc 里在 libm），
所以要 `LD_PRELOAD=libm.so.6`。

脚本：`fix_web_codec/scripts/probe_ffmpeg_codecs.sh`（已封装好，可复跑）
输出（`evidence/ffmpeg_codec_probe.txt`）：
```
avutil_license: LGPL version 2.1 or later
avcodec_version: 3934052

=== avcodec_find_decoder_by_name ===
  h264         -> h264                      ✅ 有
  hevc         -> (NULL) NOT SUPPORTED      ❌ 无
  h265         -> (NULL) NOT SUPPORTED      ❌ 无
  aac          -> aac                       ✅ 有
  aac_latm     -> (NULL) NOT SUPPORTED
  vp8          -> vp8                       ✅ 有
  vp9          -> (NULL) NOT SUPPORTED      （ffmpeg 无，Chromium 走 libvpx）
  av1          -> (NULL) NOT SUPPORTED      （ffmpeg 无，Chromium 走 dav1d）
  mp3          -> mp3                       ✅ 有
  libopus      -> libopus                   ✅ 有
  vorbis       -> vorbis                    ✅ 有
  theora       -> theora                    ✅ 有
  flac         -> flac                      ✅ 有
  ac3          -> (NULL) NOT SUPPORTED      ❌
  eac3         -> (NULL) NOT SUPPORTED      ❌
  mpeg4        -> (NULL) NOT SUPPORTED      ❌
  vp3          -> vp3                       ✅ 有
  alac         -> (NULL) NOT SUPPORTED      ❌
  pcm_s16le    -> pcm_s16le                 ✅ 有
```
> `avutil_license = LGPL` —— 说明这是 **LGPL 版 ffmpeg**（不是 Chrome 品牌版），
> 但 **H.264/AAC 解码器被显式编进去了**（ffmpeg 里 H.264/AAC *解码* 本身是 LGPL 的，
> 受限的是 x264/AAC *编码*）。**结论：这是一个"刻意带了 H.264 + AAC"的定制构建**
> （正好覆盖 B 站/优酷/腾讯视频的 AVC+AAC 基本需求），**但没带 HEVC**。

### 2.3 方法 C：引擎侧第三方解码库（VP9 / AV1 / HEVC 的判定）

```sh
strings -a libarkweb_engine.so | grep -E 'Dav1dVideoDecoder|LibvpxVp9Decoder|OpenH264VideoEncoder|...'
```
关键证据（`evidence/codec_symbols.txt`）：
```
WebM Project VP9 Decoder v1.13.0-243-g27171320f     ← libvpx 在，VP9 可解
Dav1dVideoDecoder / dav1d_open / dav1d_send_data / dav1d_get_picture
                                                     ← dav1d 在，AV1 可解
OpenH264VideoEncoder / CWelsH264SVCEncoder           ← OpenH264 只用于【编码】（WebRTC）
ff_h264dsp_init_x86 / ff_h264qpel_init_x86 / ff_qpeldsp_init_x86
                                                     ← ffmpeg 的 H.264 x86 SIMD 优化【在】→ 软解不算特别慢
"OhMedia::FFmpegDemuxer unsupported video decoder type with codec"   ← ★ 视频轨被丢弃的日志
"HEVC decoding is not supported."                   ← ★ 选了 HEVC 的日志
"FFmpeg H.264 decoder not found."                   ← 防御性日志（本引擎不会触发）
"OhosVideoDecoder::CreateCodec video/hevc"          ← 平台解码路径会尝试 HEVC（但设备无 codec HDI）
"Hardware decoder has returned an error. Trying Software decoder."
OhMedia::FFmpegDemuxer / FFmpegVideoDecoder / FFmpegAudioDecoder / ChunkDemuxer
```

### 2.4 最终清单

| 编码 | MIME/codecs 串 | ffmpeg | libvpx | dav1d | 平台硬解 | **总判定** |
|---|---|:--:|:--:|:--:|:--:|---|
| **H.264/AVC** | `video/mp4; codecs="avc1.*"` / `avc3.*` | ✅ `ff_h264_decoder` | – | – | ❌ | **支持**（纯 CPU 软解，带 x86 SIMD） |
| **AAC** | `audio/mp4; codecs="mp4a.40.2"` | ✅ `ff_aac_decoder` | – | – | – | **支持** |
| AAC-LATM | `audio/mp4a-latm` | ✅(符号在) | – | – | – | 支持 |
| VP8 | `video/webm; codecs="vp8"` | ✅ | ✅ | – | ❌ | 支持（软解） |
| **VP9** | `video/webm; codecs="vp09.*"` | ❌ | ✅ 1.13 | – | ❌ | **支持**（软解） |
| **AV1** | `video/mp4; codecs="av01.*"` | ❌ | – | ✅ dav1d | ❌ | **支持**（软解） |
| **HEVC/H.265** | `video/mp4; codecs="hev1.*"` / `hvc1.*` | ❌ | ❌ | ❌ | ❌（设备无 codec HDI） | **不支持** ★ |
| AC3 / EAC3 | `audio/ac3` | ❌ | – | – | ❌ | 不支持 |
| MP3 / Opus / Vorbis / FLAC / Theora / VP3 / PCM | — | ✅ | – | – | ❌ | 支持 |

**HEVC 为何彻底没有（三重堵死）**
1. ffmpeg 里没有 `ff_hevc_decoder`（§2.1/2.2 实测）；
2. Chromium **M114** 的 `media/media_options.gni`：`enable_hevc_parser_and_hw_decoder`
   "默认仅 fuzzer / Windows / Mac / Android 开启" → Linux/OHOS **连 HEVC 解析器都没有**
   （引擎里搜不到任何 `h265_parser`/`hevc_parser` 符号）；
3. OHOS 平台解码（`OhosVideoDecoder` → OHOS `av_codec` 服务）也救不了：
   `drivers/peripheral/codec/hal/` 在本树里**只有 `idl_service`，没有任何厂商解码器实现**
   （vendor.img 里也搜不到 codec HDI 库），所以 `video/hevc` 创建解码器必然失败。

**为什么"有 H.264 却还是没画面"→ 站点选了什么**

B 站点播用 DASH。**同一个清晰度会同时返回两种编码**（实测 API 响应结构）：
```
{ "id": 80, "codecid": 12, "codecs": "hev1.2.4.L156.90" }   ← HEVC
{ "id": 80, "codecid":  7, "codecs": "avc1.640028"      }   ← AVC
{ "id": 64, "codecid": 12, ... } { "id": 64, "codecid": 7, ... }
```
（`codecid`：7=AVC、12=HEVC、13=AV1；`fnval=4048` 时连 AV1 一起给）

前端靠 `MediaSource.isTypeSupported('video/mp4; codecs="hev1...."')` 决定挑哪一路。
**若引擎谎报 HEVC 可用**（OHOS 分支的 `isTypeSupported` 走的是"平台能力"查询，
在没有 codec HDI 的机器上判定逻辑不确定），前端就会挑 HEVC → 我们解不了 →
**视频轨要么被 `FFmpegDemuxer` 直接丢弃（日志 `unsupported video decoder type with codec`），
要么 `FFmpegVideoDecoder` 初始化失败（日志 `HEVC decoding is not supported.`）→ 只剩音频 mp4a**。

---

## 3. 「解码器好像是 mp4a」到底是什么意思

* `mp4a` / `mp4a.40.2` 是 **MP4 容器里 AAC 音频轨的 codec id**（`mp4a` = MPEG-4 Audio，
  `.40.2` = AAC-LC object type）。**它是音频，不是视频**。
* 因此"解码器只看到 mp4a"= **页面上只剩一条音频轨在解码，视频轨一条都没成功**。
* 这与"只有一两帧"并不矛盾：**能解出来的那一两帧通常是 AVC 首帧/关键帧**，
  之后要么被丢弃（HEVC 轨整体丢弃 → 只剩音频），要么软解跟不上（AVC/AV1 轨 CPU 打满 → 画面定格）。
* 三个候选根因，按可能性排序：

  | # | 机制 | 判据（真机 hilog） |
  |---|---|---|
  | **A** | **站点挑了 HEVC 轨**（`hev1`/`hvc1`），引擎无 HEVC → 视频轨丢弃 | `unsupported video decoder type with codec` 或 `HEVC decoding is not supported.` 或 `OhosVideoDecoder::CreateCodec video/hevc` |
  | **B** | 站点挑了 **AV1** 轨（`av01`），dav1d 能解但纯软解，1080p60 直接卡死 | `Dav1dVideoDecoder` 日志 + `web_render` 进程 CPU 100% |
  | **C** | 挑的是 **AVC** 轨，但**纯软解跟不上**（3072×1920 + 1080p60） | `FFmpegVideoDecoder` 正常、无 A 类日志，但 `web_render` CPU 打满、掉帧 |

  > 若真机 hilog 里 **A 类日志一条都没有**，但视频仍只有一两帧 → 是 **C**（纯性能问题），
  > 那就按 §5 的性能方案处理。

* ⚠️ **另一条独立的直播坑**：B 站直播的 `http_stream` 协议是 **FLV** 容器，
  **Chromium 没有 FLV 解封装器**（引擎里搜不到 `FlvDemuxer`；只有 `.m3u8` /
  `application/vnd.apple.mpegurl` → 有 HLS）。所以直播必须走
  `http_hls` + `ts`/`fmp4`（前端正常情况下会自动选 fmp4）。
  若页面退化成 FLV → **连一帧都出不来**。

---

## 4. 可落地的解决办法（按性价比排序）

### 方案 0（零改动，用户自己就能做）—— 先排除站点/账号因素

1. B 站播放器 → **清晰度选 1080P / 720P / 480P**（AVC 轨），**不要**选
   4K / 8K / 杜比视界 / HDR / 杜比全景声（那些**只有** HEVC/AV1）。
2. 关掉"高帧率 / 高码率"（1080P60 → 1080P）。
3. 直播 → 画质选 **"流畅"/"高清"**（qn 80/150，别选"原画/蓝光/超清"）。
4. 用 B 站 **APP 客户端**或手机浏览器播同一个视频对比：
   * APP 能播 → 站点侧没问题，是我们的引擎能力/性能问题；
   * APP 也只有声音 → 账号/该视频本身只有 HEVC 版本。
5. 看 `chrome://media-internals`（引擎里存在该字符串）里的
   `video_decoder` / `original_video_decoder` / `codec` 字段 —— 这是**最直接的确认**。

### 方案 1（推荐，半天工作量，只改自带浏览器 HAP，不动系统镜像）

我们已经有 **`Browser.hap` 的现成构建管线**（§21 修 UA 时用过：
`out/x86_64_virt/ohos-dbg/porting/browser_src/` + hvigor），所以下面两条都可以直接落地：

**(1a) 屏蔽 HEVC，让站点自动降级 AVC（治本、最稳）**

在 ArkWeb 页面加载后注入（ArkTS 侧 `webview.runJavaScript(...)`，或用
`javaScriptProxy` + `onPageBegin` 注入）：

```js
(function () {
  var BAD = /(hev1|hvc1|h265)/i;          // 只屏蔽 HEVC；AV1(av01)/VP9 我们能解，别动
  try {
    var MS = window.MediaSource;
    if (MS && MS.isTypeSupported) {
      var orig = MS.isTypeSupported.bind(MS);
      MS.isTypeSupported = function (t) {
        try { if (BAD.test(t || '')) return false; } catch (e) {}
        return orig(t);
      };
    }
  } catch (e) {}
  try {
    var V = window.HTMLVideoElement;
    if (V && V.prototype && V.prototype.canPlayType) {
      var cp = V.prototype.canPlayType;
      V.prototype.canPlayType = function (t) {
        try { if (BAD.test(t || '')) return ''; } catch (e) {}
        return cp.call(this, t);
      };
    }
  } catch (e) {}
})();
```
> 注意：页面 JS 里 `MediaSource.isTypeSupported` 可能被站点在**自己脚本之前**缓存，
> 注入时机要放在 `onPageBegin` 之后尽早执行；必要时再叠加 (1b) 的请求改写兜底。

**(1b) 直接改写 B 站取流接口参数（双保险，ArkWeb `onInterceptRequest`）**

ArkWeb 的 `Web` 组件支持 `onInterceptRequest`，可以在拦截时**替换 URL**：

```ts
// 伪代码：ArkTS，Web 组件
onInterceptRequest((event) => {
  let url: string = event.request.getRequestUrl();
  let out = url;
  // 点播：强制 DASH(AVC 优先)，去掉 4K/8K/杜比/AV1 位
  if (url.includes('/x/player/playurl') || url.includes('/pgc/player/web/playurl')) {
    out = out.replace(/fnval=\d+/, 'fnval=16');        // 16 = DASH（不含 AV1/4K/杜比位）
    if (!out.includes('prefer_codec_type=')) out += (out.includes('?') ? '&' : '?') + 'prefer_codec_type=1'; // 1 = H264
  }
  // 直播：只要 AVC
  if (url.includes('/xlive/web-room/v2/index/getRoomPlayInfo')) {
    out = out.replace(/codec=[0-9,%]+/, 'codec=0');     // 0 = avc, 1 = hevc, 2 = av1
    out = out.replace(/format=[0-9,%]+/, 'format=0,1,2');
  }
  return { url: out };
});
```
参数语义（来自 bilibili-API-collect，2026-06 实测矩阵）：

| 接口 | 参数 | 取值 |
|---|---|---|
| `api.bilibili.com/x/player/playurl`（点播） | `fnval` | `1`=MP4(**仅 H.264**)、`16`=DASH、`64`=HDR(HEVC)、`128`=4K、`256`=杜比音频、`512`=杜比视界、`1024`=8K、`2048`=AV1、`4048`=全部 DASH |
| | `prefer_codec_type` | `1`=H264 / `2`=H265 / `3`=AV1（单选偏好） |
| | `qn` / `fourk` | 清晰度 / 是否允许 4K（`fourk=0` 封顶 1080P） |
| `api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo`（直播） | `codec` | `0`=avc / `1`=hevc / `2`=av1 |
| | `format` | `0`=flv / `1`=ts / `2`=fmp4（**fmp4/ts 走 HLS，Chromium 能解；flv 不行**） |
| | `protocol` | `0`=http_stream / `1`=http_hls |

> ⚠️ `fnval=1`（纯 MP4）虽然**保证只有 H.264**，但只给 360P/480P 低清且限速，
> 只适合当"验证链路通不通"的探针，不要当最终方案。最终用 **`fnval=16` + `prefer_codec_type=1`
> + 方案 1a 屏蔽 HEVC** 的组合。

**(1c) 顺手做的两件小事**
* 直播：若发现前端选了 FLV，用 1b 的 `format` 强制 `2`（fmp4）。
* 给页面注入一个 `prefer_codec_type` 兜底（有些站点用自有 API 而非 B 站标准接口）。

### 方案 2（换引擎以获得 HEVC）——可行性低，代价大

| 途径 | 可行性 | 代价 |
|---|---|---|
| 社区现成 x86_64 预编译 | ❌ 目前**没有**带 HEVC 的 x86_64 ArkWeb；社区 `vendor_opc` 给的就是我们现在这个 5.1.0.107 / Chrome 114 | — |
| 自己用 `chromium_arkweb` 源码构建 | ⚠️ 理论可行 | **本树无 chromium 源码**（manifest 里没有 `chromium_arkweb`/`chromium_src`）；需 `repo init` 拉几十 GB + `git lfs pull`；全量编译 ~100GB 磁盘（当前根分区剩 ~92G，**且历史备份占 85G**，要先清理）；版本要对齐 OH 7.0/M144（社区配方是 6.0/M132）；还要重新签名 |
| 构建期开关（若真要自建） | — | `proprietary_codecs=true` + `ffmpeg_branding="Chrome"` + `enable_hevc_parser_and_hw_decoder=true` + ffmpeg `CONFIG_HEVC_DECODER=1`；**注意**：Chromium 的 ffmpeg 只有在 `ffmpeg_branding="Chrome"` 时才带 HEVC 解码器（Chromium 官方构建 HEVC 走平台解码而非 ffmpeg），这会让 .so 再大几 MB |

**结论：不建议为了 HEVC 走这条路。** 方案 1（屏蔽 HEVC → 强制 AVC）能覆盖 B 站绝大多数内容，
且改动只在 `Browser.hap` 里、可秒级回滚。

### 方案 3（长期：让真机用上硬件解码）—— 有价值但工程量大

* 真机是 Intel PTL，**GPU 有 VPU**，但：
  * **没有 OHOS codec HDI 实现**（`drivers/peripheral/codec/hal/` 只有 `idl_service`）→
    Chromium 的 OHOS 平台解码路径（`OhosVideoDecoder` → `av_codec` 服务）拿不到任何解码器；
  * Chromium M114 的 **VA-API 视频解码器**（`VaapiVideoDecoder`，引擎里能看到相关字符串）
    在 OHOS 分支上**没有启用**（OHOS 的 `target_os` 不是 linux/chromeos）。
* 两条可走的技术路线：
  1. **给 Chromium OHOS 分支开 VA-API**：改 `media/media_options.gni` 打开 `VaapiVideoDecoder`
     + 往系统里放 `libva2` + Intel `iHD_drv_video.so`（宿主 Ubuntu 上有，可取），
     并让渲染进程能访问 `/dev/dri/renderD128`。
     → 真机上 **H.264/HEVC/AV1 全部硬解**，直播 1080p60 无压力。
     代价：需要改 Chromium（→ 必须自建引擎，见方案 2）+ 调试 VAAPI。
  2. **补一个 OHOS codec HDI（软件或转发到 VAAPI）**，让现有 `OhosVideoDecoder` 路径能用。
     代价：实现 `drivers/peripheral/codec/hal` 的解码器（工作量大，但不用碰 Chromium）。
* 现实建议：先做方案 1 拿到"能看"，再评估方案 3。

### 方案 4（与编解码器无关的"卡"）—— 见 §5

---

## 5. 「卡顿」的独立判断（即使有 H.264 也一样卡）

### 5.1 现状：100% 软件解码，没有任何硬件加速

| 环节 | 现状 | 证据 |
|---|---|---|
| 硬件解码 | **无** | 设备无 OHOS codec HDI（`drivers/peripheral/codec/hal/` 仅 `idl_service`；vendor.img 无 codec 库）；Chromium OHOS 分支未启用 VA-API |
| H.264 软解性能 | 有 x86 SIMD（`ff_h264dsp_init_x86` 等）→ 1080p 可跑，但 1080p60 / 4K 会打满 CPU | `ff_h264dsp_init_x86` / `ff_h264qpel_init_x86` |
| AV1 软解 | dav1d（多线程，AVX2）→ 1080p 尚可，4K 必爆 | `dav1d_*` 符号 |
| 渲染 | 3072×1920 面板，每帧全屏合成 | §29.1/§30.3 已确认「每帧 DRM FB 重建」已优化，但**像素量是 590 万/帧** |
| 引擎开关 | `--disable-accelerated-video-decode` **存在**，`--enable-accelerated-video-decode` **不存在** → **没有开关能打开硬解** | 引擎字符串计数 |

⇒ **一个 1080p60 的直播流 ≈ 每秒 60×2.1M 像素的 H.264 软解 + 每帧 5.9M 像素的合成**，
在 3072×1920 的桌面上，CPU 必然打满 → "只播一两帧、然后卡住"。

### 5.2 可立即用（不改镜像）的降载手段

1. **降清晰度**：直播选"流畅/高清"（qn 80/150）；点播选 720P → 像素量降 4~9 倍。
2. **降显示分辨率**：`param set persist.display.resolution 1920x1200`
   （§31.4 已验证可用，像素量降到 1/2.6）→ 合成负载大降。
3. **关掉"高帧率/高码率"**（1080P60 → 1080P）。
4. **别在浏览器里全屏 + 别同时开多个视频**（MSE 软解 + 合成叠加）。
5. 关掉页面的其它 GPU 负载（动画/毛玻璃），把 CPU/合成预算留给解码。

### 5.3 引擎侧可调项（若 ArkWeb 允许透传 Chromium 开关）

ArkWeb 的 `nweb` 启动参数可加 Chromium switch（引擎里这些开关名存在）：

| 开关 | 作用 | 建议 |
|---|---|---|
| `--disable-accelerated-video-decode` | 强制软解（本机本来就软解，无影响，但可排除"误走平台路径导致的失败/卡顿"） | 诊断时加 |
| `--disable-features=<X>` | 关掉某些 media feature（如尝试关 HLS/DASH 路径） | 诊断用 |
| `--enable-features=VaapiVideoDecoder` | **当前无效**（OHOS 分支没编 Vaapi 视频解码器） | 需改 Chromium，见方案 3 |
| `--disable-gpu` | 关 GPU 合成 → 会更慢（软渲），**不推荐** | ❌ |

> ⚠️ 这些开关的**实际生效性**取决于 ArkWeb 启动参数是否透传（`NWeb`/CEF 的
> `command_line->AppendSwitch`）。需要先确认；本轮未在真机验证。

### 5.4 "直播只播一两帧"的一个额外嫌疑：flv

B 站直播 `http_stream` 协议给的是 **FLV**，Chromium **没有 FLV 解封装器**
（引擎里只有 `.m3u8` / `application/vnd.apple.mpegurl`，无 `FlvDemuxer`）。
若前端没选 HLS/fmp4 而是 FLV → 表现为"完全不出画面/只出首帧"。
用方案 1b 的 `format=2`（fmp4）可以钉死。

---

## 6. 真机判据（照抄执行）

### 6.1 引擎能力静态确认（不需联网）

```sh
# 推脚本
hdc file send out/x86_64_virt/ohos-dbg/fix_web_codec/scripts/device_codec_check.sh /data/local/tmp/
hdc shell "sh /data/local/tmp/device_codec_check.sh"
```
脚本会打印（真机期望值）：
```
[YES] ff_h264_decoder            ← H.264 在
[ NO] ff_hevc_decoder            ← HEVC 不在
[YES] ff_aac_decoder             ← AAC 在
[YES] dav1d_open                 ← AV1 在
[YES] "WebM Project VP9 Decoder" ← VP9 在
```
（`scripts/device_codec_check.sh` 会把结果同时写到 `/data/local/tmp/codec_check.txt`）

### 6.2 运行时确认"站点到底挑了哪一路"

```sh
hdc shell "hilog -x | grep -iE 'unsupported video decoder type|HEVC decoding is not supported|FFmpeg H.264 decoder not found|OhosVideoDecoder::CreateCodec|FFmpegDemuxer|FFmpegVideoDecoder|Dav1dVideoDecoder|LibvpxVp9Decoder'"
```
判据：
* 出现 `unsupported video decoder type with codec` → **视频轨被丢弃**（根因 A）；
* 出现 `HEVC decoding is not supported.` → **站点挑了 HEVC**（根因 A）；
* 出现 `OhosVideoDecoder::CreateCodec video/hevc` → 平台路径尝试失败；
* 出现 `Dav1dVideoDecoder` → 站点挑了 AV1（根因 B）；
* 出现 `FFmpegVideoDecoder` 且无 A 类日志 → 挑的是 AVC，**问题在性能**（根因 C）。

### 6.3 页面内直接问引擎

在浏览器里打开任意页面，用 ArkWeb 的 `runJavaScript`（或临时页面）执行：
```js
['video/mp4; codecs="avc1.42E01E"',
 'video/mp4; codecs="hev1.1.6.L93.B0"',
 'video/mp4; codecs="hvc1.1.6.L93.B0"',
 'video/mp4; codecs="av01.0.05M.08"',
 'video/webm; codecs="vp9"',
 'audio/mp4; codecs="mp4a.40.2"'
].map(t => [t, MediaSource.isTypeSupported(t), document.createElement('video').canPlayType(t)])
```
期望（若 isTypeSupported 对 hev1 返回 **true** → 就是根因 A，必须用方案 1a 屏蔽）：
```
avc1  → "probably" / "maybe"
hev1  → ""            ← 若为 "probably" 就是谎报
av01  → "probably"
vp9   → "probably"
mp4a  → "probably"
```
（也可直接开 `chrome://media-internals` 看 `video_decoder` / `codec` / `original_video_decoder`。）

### 6.4 性能判据

```sh
# 播放时看谁在吃 CPU（ohos-diag perf 已在 §30.2 加好）
hdc shell "ohos-diag perf"
# 或
hdc shell "top -b -n 1 -o %CPU,ARGS | head -20"   # 看 web_render / com.ohos.browser:render
```
判据：`web_render` 进程 %CPU 接近 100%（单/多核）→ 软解打满 → 走 §5.2 降载。

---

## 7. 交付与回退

| 项 | 说明 |
|---|---|
| **交付镜像** | **本轮未改动**（`partdisk/media/ohos_part_pc_ptl.img` 未触碰） |
| 新增文件 | `out/x86_64_virt/ohos-dbg/fix_web_codec/SUMMARY.md`（本文）<br>`out/x86_64_virt/ohos-dbg/fix_web_codec/scripts/probe_ffmpeg_codecs.sh`（宿主复跑引擎解码器清单，**已验证可用**）<br>`out/x86_64_virt/ohos-dbg/fix_web_codec/scripts/device_codec_check.sh`（真机自检，**已在宿主用同一批库做过自测**：`evidence/device_check_selftest.txt`）<br>`out/x86_64_virt/ohos-dbg/fix_web_codec/evidence/{ffmpeg_codec_probe.txt,codec_symbols.txt,device_check_selftest.txt}`<br>`out/x86_64_virt/ohos-dbg/fix_web_codec/work/`（解包的引擎库 186M + 探针源码，**可删**） |
| 回退 | 全部为新增文件，删掉 `fix_web_codec/` 即可；镜像无需回退 |

### 下一步建议（按顺序）

1. **真机跑 §6.1 + §6.2**，确定是根因 A/B/C 哪一个（5 分钟）。
2. 若是 A（HEVC）：做方案 1a + 1b（改 `Browser.hap`，有现成 hvigor 管线）→ 站点自动降级 AVC。
3. 若是 C（纯软解）：先做 §5.2 的降载（降分辨率 + 降清晰度）→ 直播至少能流畅播。
4. 中期：评估方案 3（VA-API / OHOS codec HDI）以拿到真机硬解。

---

## 8. 关键文件:行号索引（供后续定位）

* 引擎内的 Chromium 版本串：`Chrome/114.0.5735.197`
* HEVC 缺失的三重原因：
  * ffmpeg 侧：导出符号表里**没有** `ff_hevc_decoder`（对照 `ff_h264_decoder` 存在）
  * Chromium M114 `media/media_options.gni`：`enable_hevc_parser_and_hw_decoder`（默认关，仅 win/mac/android/fuzzer）
  * OHOS 平台侧：`drivers/peripheral/codec/hal/` 仅 `idl_service`（无厂商解码器实现）
* 视频轨丢弃日志串：`OhMedia::FFmpegDemuxer unsupported video decoder type with codec`
* 平台解码失败日志串：`OhosVideoDecoder::CreateCodec video/hevc`、`Hardware decoder has returned an error. Trying Software decoder.`
* FLV 不支持：`libarkweb_engine.so` 内无 `FlvDemuxer`；有 `.m3u8` / `application/vnd.apple.mpegurl`
* 开关存在性：`--disable-accelerated-video-decode`（有）、`--enable-accelerated-video-decode`（无）
