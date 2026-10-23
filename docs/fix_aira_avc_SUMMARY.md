# fix_aira_avc —— AIRA 浏览器（org.aira.browser）加"屏蔽 HEVC + 取流参数改写"保护

> 目标：x86_64 真机（`pc_ptl`，2in1）上用 **AIRA 浏览器**看 B 站，播放器显示**解码器是 HEVC** →
> 引擎解不了 → 极卡、缓冲慢、只播一两帧。
> 上一轮只给**系统浏览器 `com.ohos.browser`** 加了保护（`fix_browser_avc/`），AIRA 没有。
>
> **结论先行**
> 1. **AIRA 完全可改**：源码在 `out/x86_64_virt/ohos-dbg/fix_aira_guide/aira_src`（公开仓 `gitcode` 克隆的
>    **ArkTS 源码树**，不是二进制），且已有可用的 hvigor 构建管线（§28.2 就是用它重编的）。
>    不需要"换思路/系统层拦截"。
> 2. 改法与系统浏览器一致（**三层**）：页面层 JS 屏蔽 `hev1|hvc1|h265` + 改写取流参数 +
>    过滤 DASH 响应；网络层 `onInterceptRequest` 兜底；WBI 签名请求（带 `w_rid`）**不改**。
>    **共 1 个新文件 + 2 个文件小改**，全在**副本**里（仓库不动）。
> 3. 新 HAP `Aira-v3.7.2-x86-codecguard-signed.hap`
>    sha256 **`db9ce1bb3885e423fa863a678ba7077056048e09f67d2610c3203b37c2f74077`**（41,550,570 B），
>    **同一把签名/同一 profile**（与镜像里原有 AIRA HAP 一致）→ 预装授权条目**不用改**。
> 4. **交付镜像 `partdisk/media/ohos_part_pc_ptl.img` 本轮未改**（按要求）；注入脚本
>    `fix_aira_avc/inject.sh <image>`（幂等、拒绝对交付镜像动手）已在 `fix_aira_avc/scratch.img` 上验证。
> 5. `ohos-diag` 媒体段新增 **2 条自动判据**
>    （`media/aira-hevc-guard`、`media/browser-hevc-guard`），QEMU 实测 **PASS**。
> 6. **"解码器显示"来自页面侧**（B 站播放器自己的"播放信息"），不是 AIRA 自带的 UI
>    → 屏蔽 HEVC + 剔除 DASH 里的 HEVC 轨，会直接让页面改选 AVC，**播放信息里会显示 H.264/AVC**（详见 §5）。

---

## 0. 产物一览

| 项 | 值 |
|---|---|
| **源码副本** | `out/x86_64_virt/ohos-dbg/fix_aira_guide/aira_src/`（`gitcode.com/openharmony/window_scene_board` 风格的 AiraBrowser 源码树；**仓库不动**） |
| **新增文件** | `AiraBrowser/entry/src/main/ets/services/web/WebMediaCodecGuardScriptService.ets`（422 行） |
| **修改文件** | `core/web/BrowserHostedWebDocumentStartScriptCoordinator.ets`（+11/-1）、`app/pages/BrowserShellPage.ets`（+8/-1） |
| **补丁** | `fix_aira_avc/patch/aira_codec_guard.patch`（513 行，`git apply` 可回退） |
| **新 HAP** | `fix_aira_avc/Aira-v3.7.2-x86-codecguard-signed.hap`，sha `db9ce1bb…f74077`，41,550,570 B |
| **旧 HAP（回退用）** | `fix_input_aira/Aira-v3.7.2-x86-selfhost-fix-signed.hap`，sha `04a5b97a…5b48c`（§28.2 的 HDS 兜底版，**不含**本轮守卫） |
| **构建** | `fix_aira_avc/build_aira.sh`（hvigor `assembleHap`，日志 `work/build_aira.log`，`BUILD SUCCESSFUL`）<br>`fix_aira_avc/sign_aira.sh`（去 `libs/*.so` + OpenHarmony 测试链重签） |
| **JS 语法兜底** | `fix_aira_avc/check_guard_js.py`（从 HAP 的 `ets/modules.abc` 抽出注入脚本跑 `node --check` + 关键规则齐全性检查） |
| **JS 行为单测** | `fix_aira_avc/scripts/test_guard_js.js`（node 里模拟浏览器环境，16 条断言） |
| **注入脚本** | `fix_aira_avc/inject.sh <image> [hap] [--with-diag]`（幂等 + 镜像内 sha256 自校验 + 拒绝对交付镜像动手） |
| **QEMU 探针** | `fix_aira_avc/scripts/probe_server.py`（宿主 HTTP 探针页 + 请求日志）、`scripts/boot.sh`、`scripts/gsh.py`、`scripts/ser.py` |
| **ohos-diag** | `base/startup/ohos_diag/ohos-diag`（媒体段 +2 条判据；sha `9c49311d…46de6`） |
| **验证镜像** | `fix_aira_avc/scratch.img`（交付镜像稀疏副本 + GPT 扩到 20 GiB；**交付镜像未动**） |
| **证据** | `fix_aira_avc/evidence/`（`VERDICT_media.txt`、`ohos-diag-media.tar.gz`、桌面/窗口截图、`probe_requests.log`） |
| **交付镜像** | **未改**（`partdisk/media/ohos_part_pc_ptl.img` 保持原样） |

---

## 1. AIRA 源码位置与可改性结论

| 问题 | 结论 |
|---|---|
| 源码在哪 | `out/x86_64_virt/ohos-dbg/fix_aira_guide/aira_src/`（上一轮为修 AIRA「自建」页闪退时克隆并改过；`git log` = `401189c`） |
| 是二进制吗 | **不是**。是完整的 ArkTS 工程：`AiraBrowser/{entry,AppScope,hvigor}/`、`build-profile.json5`（`compileSdkVersion 26.0.0`）、`oh-package.json5` |
| 能重编吗 | **能**。已有 hvigor 管线：`build_aira.sh` → `hvigorw assembleHap --mode module -p module=entry@default -p product=default -p buildMode=release`（node 18.20.1 + JBR 17 + DevEco CLI 6.26.4）→ `BUILD SUCCESSFUL` |
| 用的什么 Web 容器 | **ArkUI `Web` 组件**（`Web({src, controller})` + `WebviewController`），主页/标签页由 `core/web/HostedWebNode.ets:2408` 的 `Web({...})` 承载 |
| 支持 `runJavaScriptOnDocumentStart` 吗 | **支持，且已在用**：`HostedWebNode.ets:2450` 附近 `runJavaScriptOnDocumentStart(buildHostedWebDocumentStartScripts(config))`；脚本由 `core/web/BrowserHostedWebDocumentStartScriptCoordinator.ets` 统一产出（已有 adblock / bfcache / mixed-content / user-script 等 6+ 条） |
| 支持 `onInterceptRequest` 吗 | **支持，已在用**：`BrowserShellPage.ets:12837` `onInterceptRequest: (tabId, event) => this.handleInterceptRequest(tabId, event)`（里面有流媒体旁路、文档查看器等分支） |
| 需要"换思路"吗 | **不需要**。AIRA 自己的文档起始注入管线就是最合适的落点，比系统层拦截更干净（不动 ArkWeb、不动其它应用） |

> 结论：**走"改 AIRA 源码"路线**，与系统浏览器那份保护保持一致的实现，仓库其它部分不动。

---

## 2. 改法（file:line）

### 2.1 新增：`AiraBrowser/entry/src/main/ets/services/web/WebMediaCodecGuardScriptService.ets`（422 行）

| 位置 | 内容 |
|---|---|
| `:33` | `MEDIA_CODEC_GUARD_VERSION = 'aira-codec-guard-v1'`（页面脚本 + 沙箱标记共用） |
| `:42` | `MEDIA_HOST_KEYS` = bilibili.com / bilibili.cn / bilivideo.com / bilivideo.cn / hdslb.com |
| `:51` | `HEVC_KEYS` = `hev1` / `hvc1` / `h265` / `hevc`（**只挡这 4 个**，不碰 avc1 / av01 / vp09） |
| `:57` `isHevcCodecText()` | 判断字符串是否含 HEVC 标识 |
| `:137` `rewriteMediaApiUrl()` | **ArkTS 侧**取流参数改写：点播 `/playurl` → `fnval=16` + 补 `prefer_codec_type=1`；直播 `getRoomPlayInfo` → `codec=0` + `format=2`；**带 `w_rid` 的 WBI 签名请求一律跳过** |
| `:194` `buildMediaCodecGuardScript()` | **页面层注入脚本**（主路径）：<br>① 屏蔽 HEVC：`MediaSource/ManagedMediaSource/SourceBuffer.isTypeSupported` → false；`HTMLMediaElement/HTMLVideoElement/HTMLAudioElement.canPlayType` → `""`；`navigator.mediaCapabilities.decodingInfo` → `supported:false`<br>② 改写取流：`fetch`（含 `Request` 输入）与 `XMLHttpRequest.open` → 改 URL 后再发；改写失败**回退原 URL**<br>③ 过滤 DASH 响应：`data.dash.video` / `data.support_formats` 里删掉 HEVC（codecid 12 / codecs 含 hev1·hvc1），有 AVC 时再删 AV1（codecid 13）→ **只留 AVC**；fetch 走 `Response` 重建，XHR 走 `responseText` / `response` getter 过滤<br>④ 暴露 `window.__airaCodecGuard` / `window.__airaCodecGuardStats` / `window.__airaCodecGuardProbe(t)` 供自检 |
| `:305` `handleMediaCodecGuardInterceptRequest()` | **网络层兜底**：只对"媒体域 + 媒体 API 路径"的请求动手；需要改写时用原生 `http.createHttp()` 拉改写后的 URL 并把响应回填给 WebView（`setResponseIsReady(false)` → 异步取流 → `setResponseData/setResponseHeader` → `setResponseIsReady(true)`），失败回 `502` |
| `:359` `WebMediaCodecGuardScriptService.buildDocumentStartScriptItem()` | 产出 `ScriptItem`（`scriptRules: ['*']`），并做**版本漂移自检**（脚本里必须带 `aira-codec-guard-v1`） |
| `:383` `markMediaCodecGuardApplied()` | 运行期标记：守卫真正挂到某个 Web 组件时，往应用沙箱 `<filesDir>/media_codec_guard.json` 写 `{guard, appliedAt}`，**供 `ohos-diag` 自动判定** |

### 2.2 修改：`core/web/BrowserHostedWebDocumentStartScriptCoordinator.ets`

| 位置 | 内容 |
|---|---|
| `:13` | `import { WebMediaCodecGuardScriptService, markMediaCodecGuardApplied } from '../../services/web/WebMediaCodecGuardScriptService';` |
| `:62-63` | 新增 `mediaCodecGuardScriptService` 成员 |
| `:91` | 文档脚本缓存 key 由 `browser-document-start-v3` 升到 **`-v4`**（避免命中旧缓存） |
| `:123` | `markMediaCodecGuardApplied();`（真正构造脚本时写运行期标记） |
| `:129-132` | 把守卫脚本挂进 `browserScripts` 数组：`labelInjectedScript(this.mediaCodecGuardScriptService.buildDocumentStartScriptItem(), 'media-codec-guard')` |

### 2.3 修改：`app/pages/BrowserShellPage.ets`

| 位置 | 内容 |
|---|---|
| `:116` | `import { handleMediaCodecGuardInterceptRequest } from '../../services/web/WebMediaCodecGuardScriptService';` |
| `:12100-12105` | `handleInterceptRequest()` 里加兜底分支：`const codecGuardResponse = handleMediaCodecGuardInterceptRequest(event); if (codecGuardResponse !== null) return codecGuardResponse;` |

> **为什么页面层是主路径**：ArkWeb 的 `onInterceptRequest` 回调只给**只读**的 `WebResourceRequest`
> （`getRequestUrl()` 无 setter），**无法直接改写请求 URL**。页面层 JS 改写后引擎看到的就是目标 URL，
> `onInterceptRequest` 只会 "pass"；只有引擎侧发起（不经页面 JS）的请求才走原生拉取兜底。
> 这一点在上一轮 `fix_browser_avc` 已经坐实，本轮 AIRA 沿用同一结论。

---

## 3. 构建与产物

```sh
# 1) 构建（增量约 15 s）
bash out/x86_64_virt/ohos-dbg/fix_aira_avc/build_aira.sh
#    → work/build_aira.log: BUILD SUCCESSFUL
#    → AiraBrowser/entry/build/default/outputs/default/entry-default-unsigned.hap

# 2) 去原生库 + 重签（预装代码签名校验会拒绝带 .so 的 HAP，见 §24）
bash out/x86_64_virt/ohos-dbg/fix_aira_avc/sign_aira.sh
#    → fix_aira_avc/Aira-v3.7.2-x86-codecguard-signed.hap
#    → check_guard_js.py: SYNTAX OK + 9 条关键规则齐全
```

* 新 HAP sha256：**`db9ce1bb3885e423fa863a678ba7077056048e09f67d2610c3203b37c2f74077`**（41,550,670 B）
* 签名：OpenHarmony 测试链（`fix_aira_native/signing`），**profile 与镜像里原有 AIRA HAP 一致**
  → `install_list_capability.json` 里 `org.aira.browser` 的授权条目**不用改**。
* **回归保护**：新 HAP 里仍带 §28.2 的 HDS 兜底垫片
  （`OpenHarmonyHdsMaterialShim` / `OpenHarmonyLoginComponentShim` 均在 `modules.abc` 中），
  即"自建"页闪退修复**没有被本轮改坏**。
* **JS 语法兜底是必须的**：注入脚本是 ArkTS 里的**字符串常量**，ArkTS 编译器**不检查里面的 JS 语法**
  （上一轮系统浏览器就因为多一个 `)` 导致整段脚本静默失效）。因此 `sign_aira.sh` 末尾强制
  `check_guard_js.py`（从 `modules.abc` 里把脚本抠出来 `node --check`），不过就失败。

### 单测（node，无真机）

```sh
node out/x86_64_virt/ohos-dbg/fix_aira_avc/scripts/test_guard_js.js \
     out/x86_64_virt/ohos-dbg/fix_aira_avc/work/aira_guard_check.js
```
结果 **16/16 PASS**（`evidence/` 未存，直接看脚本输出）：HEVC 全被屏蔽、AVC 不被误伤、
点播 `fnval=4048→16` + `prefer_codec_type=1`、直播 `codec=0,1,2→0` + `format=2`、
WBI 签名请求**保持原样**、XHR 路径也改写。

---

## 4. 注入（真机盘）

```sh
# 用法：inject.sh <disk-image> [hap] [--with-diag]
bash out/x86_64_virt/ohos-dbg/fix_aira_avc/inject.sh <你的镜像副本>
# 要把带新判据的 ohos-diag 一起装上：
bash out/x86_64_virt/ohos-dbg/fix_aira_avc/inject.sh <你的镜像副本> --with-diag
```

* 只动 **p2(system)**：抽 p2（offset 513 MiB，长 2048 MiB）→ `debugfs rm` + `write`
  （**先 rm 再 write**，p2 空闲只有 ~24 MiB）→ `e2fsck -f -y` → `dd` 回写 → **读回校验 sha256**。
* 落地内容：
  * `/system/app/org.aira.browser/Aira.hap`（新 HAP，路径/包名/模块名不变 → **不用**改 install_list）
  * `/system/etc/aira_codec_guard.conf`（静态标记：guard_version + HAP sha256，`ohos-diag` 用它判定）
  * （可选）`/system/bin/ohos-diag`（带新判据的诊断脚本）
* **幂等**：内容级幂等（重复注入后镜像内文件 sha 相同）；**字节级不幂等**
  （`e2fsck` 会重写 ext4 元数据，整盘 sha 会变 —— 与 `fix_browser_avc`/`fix_input_aira` 同一性质）。
* **默认拒绝对交付镜像动手**：把 `partdisk/media/ohos_part_pc_ptl.img` 当参数传进去会直接退出（exit 3）。

---

## 5. "播放器显示解码器是 HEVC" 这个值从哪来（任务问题 4）

**结论：来自页面侧（B 站播放器自己的"播放信息/统计信息"面板），不是 AIRA 或 ArkWeb 上报的。**

依据：
1. AIRA 源码里**没有**任何"解码器/codec"UI：`grep -i codec` 只命中书签同步/离线清单的编解码器，
   媒体相关服务（`services/media/MediaVideoDomProbeService.ets`、`services/video/WebVideoPresentationService.ets`）
   只做**画中画/倍速/画面接管**，不显示编解码器。
2. B 站 Web 播放器的"播放信息"里那行**编码**字段，是页面脚本从 **DASH 清单里选中的那条轨**
   （`codecid`：7=AVC / 12=HEVC / 13=AV1）渲染出来的 —— 也就是**站点选了什么轨，就显示什么**。
3. 站点选轨的依据就是页面的 `MediaSource.isTypeSupported('video/mp4; codecs="hev1..."')`：
   浏览器说支持 → 站点优先给 HEVC；说不支持 → 站点退回 AVC。

⇒ **本轮守卫正好作用在这一层**：
`isTypeSupported/canPlayType/decodingInfo` 对 hev1/hvc1/h265 一律报"不支持"，
并且把 DASH 响应里的 HEVC 轨**直接删掉** → 页面既"看不见"HEVC，也"拿不到"HEVC 轨
→ 必然改选 AVC → **B 站播放信息里应显示 H.264 / AVC**。
（ArkWeb 引擎侧的行为与此无关：引擎确实没有 HEVC 解码器，§32 已用 `libffmpeg.so` 导出符号表坐实。）

---

## 6. QEMU 验证（实况）

镜像：`fix_aira_avc/scratch.img`（交付镜像 `cp --sparse` + `truncate 20G` + `sgdisk -e`），
QEMU：`scripts/boot.sh`（pc_ptl partdisk，egl-headless + virgl，VNC :28，hdc hostfwd 5559，
串口 socket `work/ser_airaavc2.sock`）。**交付镜像未动**。

### 6.1 已验证通过

| 项 | 结果 | 证据 |
|---|---|---|
| 新 HAP 注入镜像（幂等 + sha 自校验） | **OK**（`Aira.hap` sha `db9ce1bb…`、标记文件、ohos-diag 三个文件全部读回一致） | `work/inject_e2fsck.log`、脚本输出 |
| 镜像可引导 | **OK**（全新 userdata，AIRA 预装成功） | 串口 `ZZBOOT_OK` |
| **AIRA 能安装并启动**（新 HAP 不崩、不影响启动） | **OK**（`aa start -a EntryAbility -b org.aira.browser` → "start ability successfully"，进程存活） | `evidence/screen_aira*.png` |
| `nwebspawn`（ArkWeb 引擎进程）在跑 | **OK** | `ps -A` |
| 守卫脚本从 HAP 里抠出来 `node --check` | **SYNTAX OK** | `check_guard_js.py` |
| 守卫脚本行为单测 | **16/16 PASS** | `scripts/test_guard_js.js` |
| **`ohos-diag media` 新判据** | `media/aira-hevc-guard` = **PASS**（"Aira HEVC guard installed (aira-codec-guard-v1, hap sha db9ce1bb3885)"）<br>`media/browser-hevc-guard` = **PASS** | `evidence/VERDICT_media.txt`、`evidence/ohos-diag-media.tar.gz` |

### 6.2 未能完成的一项（如实记录）

**"在 AIRA 的 ArkWeb 里真正打开探针页，看 HEVC 被挡 / AVC 保留 / 请求参数被改写"这一步没做成**，
原因是 QEMU 环境本身的两个限制，**与本轮改动无关**：

1. **AIRA 首次启动的"功能介绍页"（FeatureIntro）在 QEMU 里点不动**：
   该页的黑色区域是 ArkWeb 渲染（QEMU 无外网 → 页面加载失败 → 纯黑），
   右上角"跳过"与"向右滑动开始使用"都无法用注入的触摸事件命中
   （触摸注入本身是好的：桌面图标、计算器窗口标题栏按钮都能点中）。
   绕过办法（写 `preferences/aira_feature_intro`）也无效：AIRA 的 ArkData preferences
   **存在 `<bundle>/preferences/<name>`（无扩展名、应用级 context）**，且页面状态还受
   `StartupWelcomeIntro` / sync-experience 等多处状态影响。
2. **AIRA 在 QEMU 上冷启动极慢（≈40 s）**：首次 `aa start` 会被 SceneBoard 的
   `handleForegroundTimeout`（AMS `LIFECYCLE_TIMEOUT` → SCB `requestSceneSessionDestruction`）杀掉，
   第二次启动才活得下来（本轮即如此：第一次被杀、第二次存活）。
   这与 §22 记的"ArkWeb 在 x86_64 QEMU 上不可用"是同一类问题。
3. 因此 `window.__airaCodecGuard` / `__airaCodecGuardStats` 的**页面侧读数**没能在 QEMU 取到；
   `scripts/probe_server.py` 已就绪（宿主 `http://127.0.0.1:8899/probe.html`，
   guest 侧用 `http://10.0.2.2:8899/probe.html`），**在真机上可直接用**（判据见 §7）。

### 6.3 为跑通 QEMU 做的两处**调试镜像专用**改动（与功能无关，别带进交付镜像）

* `scripts/patch_console_apl.sh`：给镜像里 `/system/etc/init/console.cfg` 补
  `ohos.permission.START_ABILITIES_FROM_BACKGROUND`。
  原因：console 是 native token，AMS 走 `ResolveUnknownCallerBackgroundCall` 分支，
  没有可解析的父 hap token → 要求调用方 token 持该权限，否则 `aa start` 一律报
  `ABMS13790` → 错误码 10103601"bundleName does not exist"（**其实是权限问题，与 bundle 无关**，
  camera 等系统应用同样失败）。
* `scripts/boot.sh` 里用 `qemu-pcptl` 符号链接起 QEMU，避免被别的会话的
  `pkill -f 'qemu-system-x86_64 -[m]achine'` 互杀。

---

## 7. 真机判据（产品 `pc_ptl`）

1. **离线核验 HAP**
   ```sh
   hdc file recv /system/app/org.aira.browser/Aira.hap .
   sha256sum Aira.hap     # 应为 db9ce1bb3885e423fa863a678ba7077056048e09f67d2610c3203b37c2f74077
   hdc shell "cat /system/etc/aira_codec_guard.conf"   # guard_version=aira-codec-guard-v1
   ```
2. **打开 B 站视频 → 播放信息里应显示 H.264 / AVC**（不再是 HEVC/AV1），**视频能连续播放**
   （此前只有 mp4a 音轨、画面不动）。
3. **直播**：播放信息应为 AVC，且能播（此前 FLV 完全播不了；现在请求被钉成 `codec=0&format=2`）。
4. **日志**
   * `hilog | grep -i AiraCodecGuard` → 出现 `runtime marker written ... version=aira-codec-guard-v1`
     （说明守卫确实挂到了 Web 组件上）
   * `hilog | grep -iE 'unsupported video decoder type|HEVC decoding is not supported|FFmpegVideoDecoder'`
     → **不应**再出现 HEVC 相关报错
5. **页面级自检（可选，最直接）**：在 AIRA 里打开
   `http://10.0.2.2:8899/probe.html`（把 `fix_aira_avc/scripts/probe_server.py 8899` 跑在 PC 上，
   设备用 PC 的 IP），页面会打印
   `guardInstalled=true`、`isTypeSupported(hev1)=false`、`isTypeSupported(avc1)=true`、
   点播请求被改成 `fnval=16&prefer_codec_type=1`、直播请求被改成 `codec=0&format=2`、
   DASH 响应只剩 `video=[7]`。
6. **`ohos-diag` 自动判定**
   ```sh
   hdc shell "ohos-diag media"
   hdc shell "tar -xzOf /sys_prod/ohos-diag/diag-<ts>.tar.gz VERDICT.txt" | grep -i hevc-guard
   ```
   期望：`media/aira-hevc-guard` = **PASS**（自带浏览器那份 `media/browser-hevc-guard` 也应是 PASS）。

---

## 8. 回退

| 目标 | 做法 |
|---|---|
| **只回退 HAP（推荐）** | `inject.sh <image> fix_input_aira/Aira-v3.7.2-x86-selfhost-fix-signed.hap`（覆盖 p2 内 `/system/app/org.aira.browser/Aira.hap`），旧 HAP sha `04a5b97a…5b48c` |
| **源码回退** | 在 `fix_aira_guide/aira_src` 里 `git apply -R patch/aira_codec_guard.patch`（或 `git checkout --` 那两个文件 + 删除 `WebMediaCodecGuardScriptService.ets`），再 `build_aira.sh` + `sign_aira.sh` |
| **去掉 ohos-diag 新判据** | `git checkout -- base/startup/ohos_diag/ohos-diag`（该目录不是 manifest 仓，本地文件） |
| **整盘回退** | `partdisk/media/ohos_part_pc_ptl.pre_batch6.img.zst` 等历史备份（§29 起的一串 `.zst`） |
| **守卫标记文件** | 删 `/system/etc/aira_codec_guard.conf` 即可让 `ohos-diag` 判据回到 WARN |

> 仓库 `applications/standard/browser`（系统浏览器那份保护）**本轮未动**，
> AIRA 源码也在**副本**里 → 仓库级无需回退。

---

## 9. 遗留 / 风险

1. **QEMU 未做页面级端到端**（§6.2）：真机才能看到"HEVC 被挡 / AVC 保留 / 参数被改写"的页面读数。
2. **点播取流参数改写对 WBI 签名请求无效**（有意为之）：B 站 `/x/player/wbi/playurl` 用 `w_rid` 签名，
   改 `fnval` 会 -403。真正让点播落到 AVC 的是 **①HEVC 屏蔽（站点自己改选 AVC）** 和
   **②DASH 响应剔除 HEVC/AV1 轨**，两条都已实现并在 node 单测里验证。
3. **HEVC 屏蔽是"引擎能力缺失"的补偿**，不是真支持：站点若硬塞 HEVC 我们依旧解不了。
4. **AV1 依旧不支持**（引擎原生如此）：`isTypeSupported` 保持引擎原值 false，
   但 DASH 过滤里"有 AVC 时会删掉 AV1 轨"，为的是能连续播放。
5. **直播 fmp4 依赖站点支持**：`format=2` 能否播取决于 B 站是否给该房间发 fmp4 流。
6. **AIRA 在 x86_64 QEMU 上冷启动 ~40 s** 会触发 SceneBoard 前台超时被杀（与本轮改动无关，
   真机不受影响）；若要在 QEMU 里长期用 AIRA，建议先手动点一次图标让进程热起来。
7. **`markMediaCodecGuardApplied()` 写的是应用沙箱 `filesDir`**，应用被清数据后会消失；
   镜像里的 `/system/etc/aira_codec_guard.conf` 才是稳定标记（`ohos-diag` 两个判据都覆盖了）。
8. **`ohos-diag` 改动在 `base/startup/ohos_diag/`（非 manifest 仓的本地目录）**，不进版本库；
   随镜像走的话需要用 `inject.sh --with-diag` 或重新构建 `pc_ptl`。
