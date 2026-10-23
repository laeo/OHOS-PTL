# 自带浏览器 Browser.hap：屏蔽 HEVC + 改写媒体取流参数（2026-10-21）

> 目标：x86_64 真机（`pc_ptl`，2in1）上的 OHOS 自带浏览器在 B 站只出声音不出画面，
> 根因已定性为**引擎无 HEVC 解码器**（社区 x86_64 Chromium 114 引擎）而站点下发了
> HEVC 轨。本轮改**自带浏览器 `Browser.hap`**，让站点只能拿到 AVC 轨。
>
> 结论先行：
> 1. **改了 2 个文件**（1 新增 + 1 修改），全在**副本** `out/x86_64_virt/ohos-dbg/porting/browser_src/`
>    （仓库 `applications/standard/browser` 未动）。
> 2. 三层防护：**(a) 页面层 JS** 屏蔽 HEVC + 改写取流 URL + 过滤 DASH 响应；
>    **(b) 网络层 `onInterceptRequest`** 改写 URL 并回填响应；**(c) WBI 签名请求保护**
>    （带 `w_rid` 的请求**不改参数**，否则服务端 -403 会导致“完全播不了”）。
> 3. **QEMU 端到端验证通过**（`fix_browser_avc/evidence/probe_requests.log`）：
>    HEVC 被屏蔽、AVC 不受影响、直播取流参数被改写、DASH 响应里 HEVC/AV1 轨被剔除。
> 4. **重要技术结论**：ArkWeb 的 `onInterceptRequest` **无法直接改写请求 URL**
>    （回调拿到的是只读 `WebResourceRequest`），所以“改写取流参数”的**真正生效路径是页面层
>    JS**（`fetch` / `XMLHttpRequest.open` 改写后再交给引擎）；`onInterceptRequest` 作为
>    网络层兜底（引擎侧发起的请求才走这条路）。
> 5. 交付镜像 `partdisk/media/ohos_part_pc_ptl.img` **本轮未改**（按要求），
>    注入脚本 `fix_browser_avc/inject.sh <image>` 已用稀疏副本验证过。

---

## 0. 产物一览

| 项 | 值 |
|---|---|
| **源码副本** | `out/x86_64_virt/ohos-dbg/porting/browser_src/`（仓库 `applications/standard/browser` **未改**） |
| **新增文件** | `feature/web/src/main/ets/WebMediaCodecGuard.ets`（326 行） |
| **修改文件** | `feature/web/src/main/ets/BrowsePageView.ets`（4 处：import / 注入脚本数组 / `javaScriptOnDocumentStart` / `onInterceptRequest`） |
| **补丁** | `fix_browser_avc/patch/browser_codec_guard.patch`（379 行，`patch -p1` 可反向回退） |
| **原文件备份** | `fix_browser_avc/orig/`（`BrowsePageView.ets` 改前版本；`WebMediaCodecGuard.ets` 为空=新增文件） |
| **新 HAP** | `fix_browser_avc/Browser.hap`（= `porting/browser_src/product/entry/build/default/outputs/default/entry-default-signed.hap`）<br>sha256 **`1430bc9422095725f9a34f1cfed208d9d9ba3cc1b933ad7d6f2d4073c941a5f9`**，2,595,967 B |
| **签名** | 与上一版（`fix_ua` 的桌面 UA 版，sha `4177f282…`）**同一证书/同一 profile**：<br>HAP 内嵌的 profile 与 `fix_ua/PRE.p7b`、`fix_ua/NEW.p7b` **逐字节相同** → 预装授权条目**无需改** |
| **构建** | `fix_browser_avc/build_browser.sh`（日志 `build_browser.log`），hvigor `assembleHap --mode module -p module=entry` |
| **注入脚本** | `fix_browser_avc/inject.sh <disk-image>`（p2 原地替换，**必须显式给镜像参数**）<br>`fix_browser_avc/inject_qemu_system.sh`（QEMU ext4 system.img 用） |
| **QEMU 探针** | `fix_browser_avc/probe_server.py`（宿主 HTTP 服务器 + 探针页 + 请求日志） |
| **JS 语法兜底** | `fix_browser_avc/check_guard_js.py`（从 HAP 抽出注入脚本跑 `node --check`） |
| **证据** | `fix_browser_avc/evidence/probe_requests.log`、`evidence/probe_final.jpeg` |
| **交付镜像** | **未改**（`partdisk/media/ohos_part_pc_ptl.img` 保持原样） |

---

## 1. 改法（file:line）

### 1.1 页面层：文档起始注入脚本（主路径）

`porting/browser_src/feature/web/src/main/ets/WebMediaCodecGuard.ets`

| 位置 | 内容 |
|---|---|
| `:25` | `MEDIA_HOST_KEYS` = bilibili.com / bilibili.cn / bilivideo.com / bilivideo.cn / hdslb.com |
| `:34` | `HEVC_KEYS` = `hev1` / `hvc1` / `h265` / `hevc`（**只挡这 4 个**，不碰 avc1/av01/vp09） |
| `:177` | `buildMediaCodecGuardScript()`：返回注入脚本（8.3 KB） |
| `:186-187` | `patchStaticFn` / `patchProtoFn`：把 HEVC 的支持性查询改成“不支持” |
| `:197` | `isMediaHost()`：URL 全文或 hostname 命中媒体域 |
| `:200` | `rewriteUrl()`：取流参数改写（点播/直播规则 + `w_rid` 跳过） |
| `:201-204` | `isHevcRep` / `isAvcRep` / `filterVideoList` / `filterDashJson`：DASH 响应过滤 |
| `:206-207` | `filterJsonText` / `filtRes`：XHR `responseText` 与 fetch 响应的 DASH 过滤 |
| `:210-212` | `XMLHttpRequest.prototype.open` 改写 URL；`responseText` / `response` getter 过滤 JSON |
| `:213` | 暴露 `window.__ohBrowserCodecGuardProbe()` / `window.__ohBrowserCodecGuardStats`（自检用） |

注入点：`feature/web/src/main/ets/BrowsePageView.ets`
- `:24` `import { buildMediaCodecGuardScript, handleMediaInterceptRequest } from './WebMediaCodecGuard'`
- `:200` `private docStartScripts: ScriptItem[]`（原来的 `micGumScripts` 改名并追加第二条脚本）
- `:1453` `.javaScriptOnDocumentStart(this.docStartScripts)`
- `:1498` `.onInterceptRequest((event) => { return handleMediaInterceptRequest(event) })`

**脚本做的三件事**：

1. **屏蔽 HEVC**（只挡 HEVC，AVC/AV1/VP9 一律不动）：
   - `MediaSource.isTypeSupported` / `ManagedMediaSource` / `SourceBuffer`（静态+原型）→ HEVC 返回 `false`
   - `HTMLMediaElement/HTMLVideoElement/HTMLAudioElement.prototype.canPlayType` → HEVC 返回 `""`
2. **改写取流参数**（`fetch` + `XMLHttpRequest.open`，媒体域 + 对应 API 路径才改）：
   - 点播 `/playurl`：`fnval` → `16`（只要 DASH/AVC 轨）、补 `prefer_codec_type=1`（优先 AVC）
   - 直播 `getRoomPlayInfo`：`codec` → `0`（AVC）、`format` → `2`（fmp4；Chromium 没有 FLV 解封装器）
   - **带 `w_rid` 的 WBI 签名请求一律不改**（改了就破坏签名 → 服务端 -403 → 完全播不了，比现状更糟）
   - fetch/XHR 改写失败时**回退原 URL**（不把请求打坏）
3. **过滤 DASH 响应**（`data.dash.video` / `data.support_formats`）：
   - 删掉 HEVC（codecid 12 / codecs 含 hev1·hvc1）；有 AVC 时再删 AV1（codecid 13）→ **只留 AVC**
   - fetch 与 XHR 两条路径都覆盖

### 1.2 网络层：`onInterceptRequest`

`WebMediaCodecGuard.ets:270-325` `handleMediaInterceptRequest()`
- 只对“媒体域 + 媒体 API 路径”的请求动手，其它一律 `return null`（放行，零开销）
- 需要改写时：用 `http.createHttp()` **原生拉取改写后的 URL**，把响应体/响应头回填给 WebView
  （`setResponseIsReady(false)` → 异步取流 → `setResponseData/setResponseHeader` → `setResponseIsReady(true)`）
- 失败兜底：`502` + 空 JSON（不让请求悬挂）
- 日志：`[CodecGuard] intercept rewrite/pass ...`（hilog tag `BrowserTab`）

> **为什么页面层是主路径**：ArkWeb 的 `onInterceptRequest` 回调只给**只读**的
> `WebResourceRequest`（`getRequestUrl()` 无 setter），**无法直接改写请求 URL**。
> 页面层 JS 改写后，引擎看到的就是目标 URL，`onInterceptRequest` 只会“pass”；
> 只有引擎侧发起（不经页面 JS）的请求才会走原生拉取兜底。

### 1.3 ArkTS 侧同规则实现（供网络层用）
`WebMediaCodecGuard.ets:120-160` `rewriteMediaApiUrl()`：与页面脚本规则一致（点播/直播改写 +
`w_rid` 跳过），只是把 query 拆成参数数组手工重组，**不做 URL 归一化**（避免改 host/编码）。

---

## 2. 构建

```sh
bash out/x86_64_virt/ohos-dbg/fix_browser_avc/build_browser.sh
# → hvigorw assembleHap --mode module -p module=entry -p build_mode=release
#   JAVA_HOME=…jetbrains_s_r_o_-17-amd64-linux.2（否则 spawn java ENOENT）
#   NODE_HOME=prebuilts/build-tools/common/nodejs/node-v18.20.1-linux-x64
#   SDK=out/x86_64_virt/ohos-dbg/porting/sdk（26.0.0）
# → BUILD SUCCESSFUL（~8s 增量）+ GUARD JS CHECK: SYNTAX OK
```

> **重要教训**：注入脚本是 **TS 字符串常量**，ArkTS 编译器**不检查里面的 JS 语法**。
> 本轮就因为多了一个 `)` 导致整个脚本静默失效（页面里 `guardInstalled=false`）。
> 因此 `build_browser.sh` 末尾强制跑 `check_guard_js.py`（从 HAP 的 `ets/modules.abc`
> 里抽出脚本 → `node --check`），不通过就让构建失败。

---

## 3. QEMU 回归（实况）

启动：`scripts/run_gl_vnc.sh`（3D virgl，VNC 1280×800，`hdc` 走 `127.0.0.1:5555`），
宿主探针服务器 `probe_server.py 8899`，页面 `http://10.0.2.2:8899/probe.html`。

驱动方式（可用）：`hdc shell "aa start -a MainAbility -b com.ohos.browser -U <url>"`
（ability 名是 **MainAbility**，不是 EntryAbility）。

### 3.1 结果（`evidence/probe_requests.log`，宿主服务器侧记录）

| 探针 | 期望 | 实测 | 结论 |
|---|---|---|---|
| `guardInstalled` | true | **true** | 文档起始注入生效 ✓ |
| `MediaSource.isTypeSupported('…hev1.1.6.L93.B0')` | false | **false** | HEVC 被屏蔽 ✓ |
| `MediaSource.isTypeSupported('…hvc1.1.6.L93.B0')` | false | **false** | HEVC 被屏蔽 ✓ |
| `canPlayType('…hev1…')` | `""` | **`""`** | HEVC 被屏蔽 ✓ |
| `MediaSource.isTypeSupported('…avc1.640028')` | true | **true** | AVC 未被误伤 ✓ |
| `canPlayType('…avc1.640028')` | maybe/probably | **"probably"** | AVC 未被误伤 ✓ |
| `isTypeSupported(av01/vp09)` | 引擎原值 | false / false | 引擎本身就不支持，**我们没碰** ✓ |
| 直播取流请求 | `codec=0&format=2` | **`/xlive/web-room/v2/index/getRoomPlayInfo?codec=0&format=2&room_id=1`** | 取流参数改写生效 ✓ |
| 点播取流请求（fetch） | `fnval=16&prefer_codec_type=1` | 报错信息里 URL 已是 `…playurl?fnval=16&avid=1&prefer_codec_type=1` | 改写生效 ✓（报错本身是**测试构造**的产物，见下） |
| 点播取流请求（带 `w_rid`） | 保持原样 | `…playurl?fnval=4048&avid=1&w_rid=SIGNED` | WBI 签名保护生效 ✓ |
| DASH 响应过滤（fetch） | 只剩 AVC | **`video=[7] formats=[7]`** | HEVC(12)/AV1(13) 轨被剔除 ✓ |
| DASH 响应过滤（XHR） | 只剩 AVC | **`video=[7] formats=[7]`** | 同上 ✓ |
| `onInterceptRequest` 回调 | 被调用 | hilog `[CodecGuard] intercept pass url=…codec=0&format=2…` | 网络层兜底通路可用 ✓ |
| UA（回归 fix_ua） | 桌面 UA | `Mozilla/5.0 (PC; OpenHarmony 7.0) … Chrome/114.0.0.0 … ArkWeb/4.1.6.1` | 上一轮 UA 修复未被破坏 ✓ |

> 注：探针里点播用 `http://api.bilibili.com@10.0.2.2:8899/...` 这种“带 userinfo”的 URL 是
> 为了在 guest 里不配 DNS 也能命中“媒体域”规则；Chromium 的 `fetch` 禁止带凭据的 URL
> （`Request cannot be constructed from a URL that includes credentials`），所以那两条 fetch
> 探针报的是**构造错误**（错误信息里已能看到改写后的 URL），不是补丁问题；
> XHR 路径无此限制，已验证。

### 3.2 QEMU 侧交付状态
- QEMU 的 `out/x86_64_virt/packages/phone/images/system.img` 已换成新 HAP
  （`/system/app/com.ohos.browser/Browser.hap` = `1430bc94…`），overlay 已重建
  （`scripts/rebuild_overlays2.sh`，含全新 userdata）。
- **真机交付镜像 `partdisk/media/ohos_part_pc_ptl.img` 未改**（按任务要求）。

---

## 4. 注入（真机盘）

```sh
# 用法：inject.sh <disk-image> [hap]     ← 镜像参数必填，避免误改交付镜像
bash out/x86_64_virt/ohos-dbg/fix_browser_avc/inject.sh <你的镜像副本>
```
- 只动 **p2(system)**：抽 p2（offset 513 MiB，长 2048 MiB）→ `debugfs rm` + `write`
  （**先 rm 再 write**，因为 p2 空闲只有 ~24 MiB，而 HAP 2.5 MB 且旧 HAP 也要占位）→
  `e2fsck -f -y` → `dd` 回写 → **读回校验 sha256**
- 路径/包名/模块名/签名都不变 → **不需要**改 `install_list.json` /
  `install_list_capability.json`
- 验证（用 `cp --sparse` 的交付镜像副本）：注入成功、镜像内 HAP sha 一致；
  **p1 与 p3+ 区域字节级未变**；`sgdisk -v` 的告警与原镜像**完全相同**（是交付镜像本身
  裁剪导致的既有现象，与本次无关）
- 幂等性：**内容级幂等**（重复注入后镜像内 HAP sha 相同）；**字节级不幂等**
  （`e2fsck` 会重写 ext4 元数据，整盘 sha 会变）

---

## 5. 真机判据（产品 `pc_ptl`）

1. **离线核验 HAP**
   `hdc file recv /system/app/com.ohos.browser/Browser.hap` →
   sha256 应为 `1430bc9422095725f9a34f1cfed208d9d9ba3cc1b933ad7d6f2d4073c941a5f9`（2,595,967 B）
2. **打开 B 站视频 → 播放信息里应显示 H.264 / AVC**（不再是 HEVC/AV1），
   **视频能连续播放**（此前只有 mp4a 音轨、画面不动）
3. **直播**：播放信息应为 AVC，且能播（此前 FLV 完全播不了，现在请求被钉成 `codec=0&format=2`）
4. **日志**
   - `hilog | grep CodecGuard` → 出现 `intercept pass/rewrite`（网络层生效）
   - `hilog | grep -iE 'unsupported video decoder type|HEVC decoding is not supported|FFmpegVideoDecoder'`
     → **不应**再出现 HEVC 相关报错
5. **页面级自检（可选）**：任意页面执行
   `MediaSource.isTypeSupported('video/mp4; codecs="hev1.1.6.L93.B0"')` → `false`；
   `MediaSource.isTypeSupported('video/mp4; codecs="avc1.640028"')` → `true`
6. **UA 未被破坏**：`navigator.userAgent` 仍应含 `(PC; OpenHarmony 7.0)`、不含 `Mobile`

---

## 6. 回退

| 目标 | 做法 |
|---|---|
| **源码回退** | 在 `porting/browser_src` 里 `patch -R -p1 < fix_browser_avc/patch/browser_codec_guard.patch`，或直接用 `fix_browser_avc/orig/BrowsePageView.ets` 覆盖 + 删除 `WebMediaCodecGuard.ets`，然后重跑 `build_browser.sh` |
| **只回退 HAP（推荐）** | 用上一版 HAP（`fix_ua/Browser.hap`，sha `4177f282280ae78d92624648e45e1791330f958f02a466480f59394beb9dbe9e`）覆盖 p2 内 `/system/app/com.ohos.browser/Browser.hap`（`inject.sh <image> fix_ua/Browser.hap` 即可） |
| **真机盘整盘回退** | `partdisk/media/ohos_part_pc_ptl.pre_batch6.img.zst`（= `e848e34c…` 之前那版）等历史备份 |
| **QEMU** | `inject_qemu_system.sh` 用旧 HAP 覆盖 `system.img` → `e2fsck -f -y` → `scripts/rebuild_overlays2.sh` |

> 仓库 `applications/standard/browser` 本轮**未改动**，无需仓库级回退。

---

## 7. 遗留 / 风险

1. **点播取流参数改写对“WBI 签名请求”无效**（有意为之）：bilibili 的
   `/x/player/wbi/playurl` 用 `w_rid` 签名，改 `fnval` 会导致 -403。
   真正让点播落到 AVC 的是 **①HEVC 屏蔽（站点自己改选 AVC）** 和 **②DASH 响应里剔除 HEVC/AV1 轨**，
   两条都已验证生效。若要连请求参数一起改，需要在页面里重算 WBI 签名（要 `img_key/sub_key`），复杂且易碎，未做。
2. **HEVC 屏蔽是“引擎能力缺失”的补偿**，不是真支持：即便站点选中 HEVC 我们也解不了，
   现在只是让站点**别选**它。
3. **AV1 依旧不支持**（引擎原生如此：Chromium 114 无 AV1 解码 / dav1d 未编入），
   我们**没有**屏蔽 AV1（`isTypeSupported` 保持引擎原值 false），但 DASH 过滤里
   “有 AVC 时会删掉 AV1 轨”，这是为了连续播放。
4. **直播 fmp4 依赖站点支持**：`format=2` 能否播还取决于 B 站是否给该房间发 fmp4 直播流。
5. **注入脚本不做 partition 表修复**：交付镜像本身是裁剪过的（`sgdisk -v` 有既有告警），
   真机写盘请走 `partdisk/dd_and_verify.sh`（内含 `sgdisk -e`）。
6. **未在真机运行期验证**（QEMU 无法覆盖真实网络与真实 B 站流），真机判据见 §5。
7. **ArkTS 侧 `WebResourceResponse` 异步回填**依赖 ArkWeb ≥ API 12 的
   `setResponseIsReady(false)` 语义；本轮 QEMU 上该通路未被触发（页面层已先行改写），
   若真机遇到引擎侧请求，可用 hilog 的 `[CodecGuard] intercept rewrite` 观察。
8. 页面层注入脚本是**全站生效**的（所有站点、所有 frame），当前只在“媒体域 + 媒体 API 路径”
   上做改写，其余站点零影响；HEVC 屏蔽对所有站点生效（对其它站点是**正确**行为，因为本引擎
   本来就解不了 HEVC）。
