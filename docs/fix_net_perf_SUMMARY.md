# fix_net_perf —— Wi-Fi 吞吐（问题 1）与 B 站直播卡顿（问题 2）分析与修正

> 产品：`pc_ptl`（真机 HONOR XWC-P / Intel Panther Lake / iwlwifi）
> 产物目录：`out/x86_64_virt/ohos-dbg/fix_net_perf/`
> **未改** `out/x86_64_virt/ohos-dbg/partdisk/media/ohos_part_pc_ptl.img`（交付镜像未动）；
> 验证在 `fix_net_perf/scratch.img`（`cp --sparse` 副本）与 QEMU 测试台完成。
> 未写 `/tmp`，未动 `/dev/sda*`，构建全部后台 + 日志落 `out/`。

---

## 0. TL;DR

| # | 结论 | 状态 |
|---|------|------|
| 1 | **通用 nl80211 路径从不给内核设置 regulatory domain** → 内核一直用内建 "world" 域（5 GHz 只有 20 MHz、52~144 频段带 DFS → 60 s 雷达 CAC、发射功率受限）。**这是链路层吞吐被压制的确定根因。** | **已修 + QEMU 验证通过**（开机后 `regulatory domain: CN`） |
| 2 | **iwlwifi 的省电模式从未被关闭**（驱动默认 `power_save=1` balanced → 报文合并/长监听间隔，直接伤小包低时延传输） | **已修**（HAL 里 `NL80211_CMD_SET_POWER_SAVE=off`） |
| 3 | "apk 慢 / npm 快" 的**每连接开销**（DNS / TCP / TLS）无法在本机复现（真机不可直连）→ 提供了**可判别的测量脚本** `scripts/wifi_perf_probe.sh`（拆出 dns/connect/tls/ttfb/speed 四段）+ 新工具 `wifiprobe` | 脚本就绪，待真机跑 |
| 4 | **更正**：Mesa 的"每帧全屏回读 + CPU 行翻转"**只在 virgl(QEMU) 路径生效**；真机走 iris，`ohos_needs_host_sync()` 直接返回 false → **它不是真机直播卡顿的原因**。 | 已核实（代码 + 镜像内 libEGL 字符串） |
| 5 | 实测 virgl 每帧成本：**map 6.9 ms（等 GPU + host→guest 回传 4 MiB）+ 行翻转 ~1.95 ms ≈ 8.9 ms/帧**（≈54 次 swap/s 上限）。 | 已实测 |
| 6 | 行翻转**算法不是瓶颈**：byte 逐字节 1939 µs vs SSE2 原地交换 1961 µs（差异被"4 MiB guest dma-buf 的页错误+带宽"淹没）。→ 真正瓶颈是 virgl 的回传本身，只能靠"给 guest 一个 host-visible(hostmem blob) 扫描缓冲"解决（改显示 HDI，超出本次范围，且**真机用不到**）。 | 已实测（诚实结论：优化收益 ≈ 0） |
| 7 | 真机直播卡顿的真正嫌疑：**社区 Chromium 114 x86_64 引擎自带 `libffmpeg.so`、无 libva → H.264 纯软解**，CPU 被打满 → 只播出一两帧。 | 已定位（引擎 HAP 静态分析）+ 判据脚本 `scripts/arkweb_live_probe.sh` |

---

## 1. 问题 1：Wi-Fi 吞吐低

### 1.1 根因 A：regulatory domain 从未被设置（**确定根因，已修**）

#### 证据链（代码级）

1. **框架侧**：STA 收到国家码时只调用 wpa_supplicant：
   `foundation/communication/wifi/wifi/services/wifi_standard/wifi_framework/wifi_manage/wifi_sta/sta_state_machine.cpp:722`
   ```cpp
   WifiErrorNo result = WifiSupplicantHalInterface::GetInstance().WpaSetCountryCode(wifiCountryCode);
   ```
   wpa_supplicant 的 `country=` **只用于 AP**（`third_party/wpa_supplicant/.../ap.c:533`），
   **不会**给内核设置 regdomain（全树 grep：无 `NL80211_CMD_SET_REG` / `iw reg set`）。

2. **HAL 侧**：通用 nl80211 chip HAL 的国家码走的是 **vendor 命令**：
   `drivers/peripheral/wlan/chip/wifi_hal/wifi_hal.cpp` → `SetCountryCodeCommand::Create()`
   发送 `NL80211_CMD_VENDOR` + `WIFI_SUBCMD_SET_COUNTRY_CODE`。
   **只有 hdfwifi 内核驱动认识这个 vendor 命令**；iwlwifi/ath/mac80211_hwsim 直接忽略。
   客户端 `drivers/peripheral/wlan/client/src/netlink/netlink_cmd_adapter.c:1372 WifiSetCountryCode()`
   同样只发 vendor 命令。

3. **内核侧**：`net/wireless/reg.c` 的内建 "world" 域最保守：
   ```c
   REG_RULE(5180-10, 5240+10, 80, 6, 20, NO_IR|AUTO_BW),   /* 5 GHz 只有 20 MHz */
   REG_RULE(5260-10, 5320+10, 80, 6, 20, NO_IR|AUTO_BW|DFS), /* 52~64 需雷达 CAC */
   REG_RULE(5500-10, 5720+10,160, 6, 20, NO_IR|AUTO_BW|DFS), /* 100~144 同上 */
   ```
   → 5 GHz 被压到 **20 MHz**、DFS 频段要 **60 s CAC**、发射功率受限。

4. **regulatory.db 也没到位**：内核在 `late_initcall(regulatory_init_db)` 里
   `request_firmware_nowait("regulatory.db")`，而此时 `/system` 还没挂载
   （cmdline 的 `firmware_class.path=/system/lib/firmware` 也指向未挂载的分区），
   → 数据库加载失败，**即使设了国家码也查不到规则**。
   而 pc_ptl 镜像里**根本没有** `regulatory.db`
   （`device/pc/ptl/firmware/regulatory.db` 只在源码树里，`BUILD.gn` 有安装规则，
   但交付镜像的 `/system/lib/firmware` 里查无此文件）。

#### 实测（QEMU，`mac80211_hwsim`）

```
$ /system/bin/wifiprobe
regulatory domain: 00  (WORLD - 5GHz limited to 20MHz, DFS needs CAC)
power_save: off
```

#### 修法

| 改动 | 文件 | 说明 |
|------|------|------|
| 通用 `NL80211_CMD_REQ_SET_REG`（alpha2） | `drivers/peripheral/wlan/chip/wifi_hal/wifi_hal.cpp`（新增 `SetRegDomainCommand`） | 与 `iw reg set` 等价；内核策略允许 alpha2 长度 2~3 字节（`NLA_POLICY_RANGE(NLA_BINARY,2,3)`） |
| `NL80211_CMD_RELOAD_REGDB` | 同上（新增 `ReloadRegDbCommand`） | 让内核在 `/system` 挂载后**重新**加载 `regulatory.db` |
| `NL80211_CMD_SET_POWER_SAVE=off` | 同上（新增 `SetPowerSaveCommand`） | 关掉 iwlwifi 的 balanced 省电 |
| 后台重试线程 | 同上（`WifiLinkTuningThread`，0/3/10/30/60 s） | chip HAL 由 hdf_devhost 拉起，可能早于 `/system` 挂载，故重试 |
| 客户端也走通用路径 | `drivers/peripheral/wlan/client/src/netlink/netlink_cmd_adapter.c`（新增 `SetRegDomain()`，`WifiSetCountryCode` 先调它） | device-config 路径也能生效 |
| 镜像：带 regulatory.db | `inject.sh` → `/system/lib/firmware/regulatory.db(.p7s)` | 内核查得到国家规则 |
| 镜像：**root** init 服务 | `inject.sh` → `/system/bin/zz_wifi_regdomain.sh` + `/system/etc/init/zz_wifi_regdomain.cfg` | **必须 root**：Wi-Fi 进程都没有 CAP_NET_ADMIN |

> **为什么必须 root**（真机/QEMU 实测的进程身份）：
> ```
> wifi_host            (HDF chip 服务，承载 vendor HAL)  Uid: 3026
> wifi_manager_service Uid: 1010
> ```
> `NL80211_CMD_REQ_SET_REG` / `RELOAD_REGDB` 都是 `GENL_ADMIN_PERM`，
> 非 root 会直接 **-EPERM**。所以改由 init（root）里的
> `zz_wifi_regdomain.sh` 调 `wifiprobe reg reload` + `wifiprobe reg set CN`。
> 国家码可用 `/system/etc/wifi_country_code` 覆盖（默认 `CN`）。

#### 验证（QEMU，开机后自动执行）

```
$ /system/bin/wifiprobe reg reload
regulatory.db reload: ok                       <- 内核从 /system/lib/firmware 成功加载 db
$ /system/bin/wifiprobe reg set CN
set regulatory domain CN: ok
$ /system/bin/wifiprobe reg
regulatory domain: CN                           <- **开机后即为 CN**（init 服务已应用）
$ /system/bin/wifiprobe ps
power_save: off
```
（对照：修复前 `regulatory domain: 00`；`ieee80211_regdom=CN` 内核命令行**无效**——
 late_initcall 时 db 还没加载，pending hint 不会在 db 到达后重放，实测仍为 00。）

### 1.2 根因 B：省电模式（已修）

`iwlwifi` 默认 `power_save=1`（balanced），会做报文合并、长监听间隔，对"每文件一次新连接"
的 `apk add` 这类小包低时延传输伤害很大。通用 HAL 里原来没有任何 `SET_POWER_SAVE`，
vendor 路径只有 `FillHwprivIoctlData`（`ioctl` 给 hdfwifi）。现已在 HAL 里用通用
`NL80211_CMD_SET_POWER_SAVE` 关掉（真机判据：`wifiprobe ps` → `power_save: off`）。

### 1.3 "apk 慢、npm 快" 的判别方法（真机跑）

**为什么 npm 不受影响**：Node 用 **c-ares** 自己发 UDP DNS、且默认开 Happy Eyeballs；
apk/curl 用 musl/glibc 的 `getaddrinfo`。两者 DNS 路径不同 →
**如果慢在 DNS，只有 apk 受影响**；如果慢在链路，两者都慢。

**测量脚本**（放进镜像或直接在终端里跑）：
`fix_net_perf/scripts/wifi_perf_probe.sh [url]`

它把一次下载拆成四段并分别计时：
```
dns_getent_sec / dns_icmp_rtt_sec         <- OHOS 解析路径（musl -> netsys DNS 代理）
curl_default = dns=..s connect=..s tls=..s ttfb=..s total=..s speed=..B/s code=..
curl_ipv4 / curl_ipv6                     <- 区分 IPv6 黑洞
curl_single_1..5                          <- 单连接重复 5 次（区分"每连接开销" vs "带宽上限"）
```
判读：
* `dns` 大（>0.3 s）而 `connect/tls` 小 → **DNS 慢**（OHOS netsys DNS 代理或 AAAA 黑洞）；
* `tls` 大 → **握手慢**（证书链/密钥交换，或 apk 每文件一次握手被放大）；
* `connect` 大 → **链路 RTT/省电**（本轮已修的 power save 正是这种症状）；
* `speed` 上限低（<10 MB/s）而 `ttfb` 正常 → **带宽被压制**（regulatory domain / 20 MHz，
  本轮已修）。

**真机一键跑法**：
```sh
hdc shell "sh /data/local/tmp/wifi_perf_probe.sh"
# 或在终端 App 的 Debian rootfs 里：
bash wifi_perf_probe.sh https://dl-cdn.alpinelinux.org/alpine/v3.19/main/x86_64/APKINDEX.tar.gz
```
配套的链路层工具 `wifiprobe`（已随 `inject.sh` 装到 `/system/bin/wifiprobe`）：
```
wifiprobe                 # regdomain + power save + station 统计
wifiprobe reg             # 只看 regulatory domain
wifiprobe station         # signal / tx_bitrate / tx_retries / tx_failed
wifiprobe reg reload      # 重载 regulatory.db
wifiprobe reg set CN      # 手动设置国家码
wifiprobe ps off          # 手动关省电
```

---

## 2. 问题 2：B 站直播极卡顿、只播出一两帧

### 2.1 **重要更正**：Mesa 的"全屏回读 + 行翻转"与真机无关

`out/x86_64_virt/ohos-dbg/mesa_build26/mesa3d-src/src/egl/drivers/dri2/platform_ohos.c`：
```c
static bool ohos_needs_host_sync(struct dri2_egl_display *dri2_dpy)
{
    ...
    return strcmp(dri2_dpy->driver_name, "virtio_gpu") == 0 ||
           strcmp(dri2_dpy->driver_name, "virgl") == 0;
}
```
→ 只有 **virgl（QEMU）** 会走 `dri2_map_image(TRANSFER_READ)` + 行翻转；
**iris（真机 Intel Xe）直接返回 false**，既不回传也不翻转。
交付镜像里的 `libEGL.so.1.0.0`（Mesa 26.2.3）已含该判断（`strings` 见 `virtio_gpu`/`virgl`/
`MESA_OHOS_SYNC_BACK`）。**所以真机直播卡顿不可能由这段代码引起。**

### 2.2 QEMU/virgl 路径的实测与优化

给 Mesa 加了**可开关的 profiling**（`/system/etc/mesa_prof` 或环境变量 `MESA_OHOS_PROFILE`）：

```
/system/etc/mesa_prof:
  flip=simd            # simd(默认) | byte(原始实现) | rowcopy | 0(不翻转)
  profile=/data/mesa_prof.txt
```

**实测（QEMU，virtio-gpu-gl-pci，1280x800，指针动画负载）**：

| flip 模式 | avg_map_us | avg_flip_us | avg_unmap_us |
|-----------|-----------|-------------|--------------|
| byte（原始逐字节） | 6902 | **1939** | 2.5 |
| rowcopy（临时行缓冲 memcpy） | 6957 | 2224 | 2.4 |
| simd（SSE2 原地交换，默认） | 6889 | **1961** | 2.4 |

结论（诚实）：
1. 每帧成本 ≈ **6.9 ms map（等 GPU + host→guest 回传 4 MiB）+ 1.95 ms 翻转 ≈ 8.9 ms** → 上限约 54 次 swap/s。
2. **翻转算法不是瓶颈**：byte(1939 µs) ≈ SIMD(1961 µs)。1.95 ms 花在"访问 4 MiB guest dma-buf"
   的页错误 + 内存带宽上，不是指令数上。
3. 因此**"把翻转交给 GPU / 改 memcpy"在本路径上收益≈0**；真正的瓶颈是 virgl 必须把
   宿主 GPU 渲染结果 **回传到 guest 内存**（OHOS 显示 HDI 扫描的是 guest 内存）。
   要根治需要让 guest 的扫描缓冲变成 **host-visible（virtio-gpu blob/hostmem）**，
   让 virgl 直接写进去 —— 属于显示 HDI（`device/qemu/common/virt_full/hardware/display`）
   的改造，且**只影响 QEMU，真机用不到**。本轮未做，留作后续项。

已落地的 Mesa 改动（保留，因为不劣且给后续实验留了开关）：
* SSE2 原地行交换（默认），`byte` 保留原始实现便于 A/B；
* `MESA_OHOS_FLIP=simd|byte|rowcopy|0`、`MESA_OHOS_SYNC_BACK=0|1`、`MESA_OHOS_PROFILE=<path>`；
* `/system/etc/mesa_prof` 配置文件（免去改 render_service 环境的麻烦）；
* 重新构建 Mesa 26.2.3（`mesa_build26/build_iris.sh`），产物 `mesa_build26/stage-iris/`。

### 2.3 真机直播卡顿的真正嫌疑：**软解**

社区 ArkWeb 引擎（`porting/vendor_opc/common/hap/ArkWebCore-x86_64.hap`，164.9 MB）内含：

```
libs/x86_64/libarkweb_engine.so   164924848
libs/x86_64/libffmpeg.so             2712088   <- 软解 H.264
（无 libva.so / 无 VA-API -> 没有硬解路径）
```

→ B 站直播的 H.264 **纯软件解码**，解码+缩放+合成全部抢 CPU；
真机虽然 RS 走 iris（硬件 GL，`hidumper -s RenderService -a gles` 可确认），
但 **视频解码** 这一步是 CPU 的，所以"只播出一两帧"完全符合"软解 + 渲染线程被抢占"。

**可用的真机判据**（脚本 `scripts/arkweb_live_probe.sh`，播放直播时跑）：
```
hidumper -s RenderService -a gles     -> GL_RENDERER: iris (...)   # 渲染是硬件
hidumper -s RenderService -a hitchs   -> >16.67ms 的帧数           # 合成是否掉帧
top / ps                               -> web_render / nwebspawn 的 %CPU   # 软解吃 CPU 的证据
```
判读：
* `web_render`（或 `nwebspawn`）CPU > 60% 且 hitchs 很大 → **软解是瓶颈**：
  降直播清晰度/码率（B 站客户端里选"流畅"），或换带硬解的引擎（需要 x86_64 的
  Chromium 社区版 + VA-API/ffmpeg VAAPI，体积大、且要重签，本轮未做）。
* `GL_RENDERER` 出现 `softpipe/swrast` → 渲染都在 CPU 上，必须先解决 Mesa/驱动选择。
* hitchs 全 0 且画面已流畅 → 只是码率/分辨率问题。

**ArkWeb 侧可做的降载（本轮只给了判据，未改引擎）**：直播 HLS 的预缓冲/分辨率由
Chromium 内部策略决定，社区引擎没有暴露开关；OHOS 侧能做的只有
`web_config.xml` 级别的开关与"不要开特效/模糊"（`persist.sys.graphic.blurEnabled=1`
保持开启，**不要**再设 0，AGENTS §16.7 有教训记录）。

---

## 3. 交付物

```
out/x86_64_virt/ohos-dbg/fix_net_perf/
├── SUMMARY.md                  本文件
├── inject.sh                   <task>/inject.sh <image> [--mesa]   幂等 + 自校验
├── inject_qemu.sh              QEMU 测试台注入（system.img + vendor.img + overlay 重建）
├── scratch.img                 cp --sparse 的交付镜像副本（已注入）
├── files/
│   ├── zz_wifi_regdomain.sh    root init 服务：重载 regdb + 设置国家码
│   └── zz_wifi_regdomain.cfg   init 服务定义
├── tools/
│   ├── wifiprobe.c             nl80211 诊断/调参工具（静态编译进镜像）
│   └── wifiprobe               (编译产物)
└── scripts/
    ├── wifi_perf_probe.sh      真机：DNS/TCP/TLS/带宽 四段分解 + 链路层状态
    ├── arkweb_live_probe.sh    真机：直播卡顿判据（GL renderer / hitchs / CPU / 解码）
    ├── measure_mesa_flip.sh    QEMU：virgl 每帧成本 A/B（byte vs simd）
    ├── verify_qemu.sh          QEMU：开机日志 + Mesa profile + hitchs 采集
    └── run_qemu_3d.sh          QEMU 3D(virgl) 启动脚本（-cpu host，避免时钟跑飞）
```

### 源码改动（仓库内）

| 文件 | 改动 |
|------|------|
| `drivers/peripheral/wlan/chip/wifi_hal/wifi_hal.cpp` | 新增 `SetRegDomainCommand` / `ReloadRegDbCommand` / `SetPowerSaveCommand` / `WifiApplyLinkTuning` / `WifiLinkTuningThread`；`WifiPreInitialize()` 调用 |
| `drivers/peripheral/wlan/client/src/netlink/netlink_cmd_adapter.c` | 新增 `SetRegDomain()`；`WifiSetCountryCode()` 先走通用 nl80211 路径 |
| `out/x86_64_virt/ohos-dbg/mesa_build26/mesa3d-src/src/egl/drivers/dri2/platform_ohos.c`（**仓库外的 Mesa 工作副本**） | SSE2 行交换 + profiling + 三个开关 |

> `out/x86_64_virt/ohos-dbg/mesa_build26/` 是 Mesa 的本地工作副本（仓库里的
> `third_party/mesa3d` 是 25.0.1 且 iris 需 `INTEL_FORCE_PROBE`；26.2.3 默认支持 PTL，
> 见 AGENTS/fix_mesa）。**仓库源码未被改动。**

### 产物 sha256

| 对象 | sha256 |
|------|--------|
| `libwifi_hal_default.z.so` | `00ba8f1b969952e301ca06e106fe0f53df9687ac84872f3824198466233c3aba` |
| `libwifi_driver_client.z.so` | `06ac500027ea0e43453df39023fb41f633fd2dbc272aff28ee8e1c362023cf24` |
| `wifiprobe` | `446a9dcd5bfe5cbee0d6d5ef657aef569c5ace9cff9d90b41b0f88499f53fb11` |
| `regulatory.db` | `2fb33ca0074db573e05ef7dd50bb45b63c0ff98b7e852e1105ebad536fae8e6b` |
| `zz_wifi_regdomain.sh` | `44b0b3cec801787fab1ba40a4e71517e9c2f635325bffc02682fa8a3676d608e` |
| `zz_wifi_regdomain.cfg` | `fbde1fc66888985df07ad75adb8de6a7d41d90a7390ba3750bf028bd3e162832` |
| `scratch.img`（注入后） | `8006fe8689178423860c2d9d348337870bd6c12787b53a3c6c89bdf9e10c2698` |

---

## 4. 回退

| 对象 | 回退方法 |
|------|----------|
| Wi-Fi HAL / client | `git checkout -- drivers/peripheral/wlan/chip/wifi_hal/wifi_hal.cpp drivers/peripheral/wlan/client/src/netlink/netlink_cmd_adapter.c` → 重编 `wifi_hal_default`/`wifi_driver_client` → 注入 → e2fsck → 重建 overlay |
| 镜像内的注入物 | `inject.sh` 的逆操作：把 `partdisk/media/ohos_part_pc_ptl.pre_*.img.zst` 备份解回；或从 `scratch.img` 的注入前副本恢复 |
| Mesa | `mesa_build26/inject_iris.dbgfs` 覆盖回旧 `stage-iris/`；或把 p2 的 `libEGL.so.1.0.0` 换回 vendor 21.2.1 |
| QEMU 测试台 | `inject_qemu.sh` 的备份 `work/vendor_mesa_bak/`；overlay 需重建（`dbg/*.qcow2`） |
| init 服务 | 删除 `/system/etc/init/zz_wifi_regdomain.cfg` 与 `/system/bin/zz_wifi_regdomain.sh` |

---

## 5. 遗留 / 下一步

1. **真机必须跑一次 `wifi_perf_probe.sh`**，才能把"apk 慢"从"链路被压制"进一步细分到
   DNS / TLS / 每连接开销（QEMU 无法直连真机 Wi-Fi）。
2. **regulatory.db 的版本**：现在用的是树里 `device/pc/ptl/firmware/regulatory.db`
   （6.4 KB，二进制 RGDB/fwdb 格式，含 CN/US/… 共 200+ 国家）。
   **两个内核的格式版本一致**，所以同一个文件在 QEMU(linux-6.18) 和真机(linux-7.2) 上都能用：
   ```
   linux-6.18/net/wireless/reg.c:650  #define FWDB_MAGIC 0x52474442
   linux-6.18/net/wireless/reg.c:651  #define FWDB_VERSION 20
   linux-7.2/net/wireless/reg.c:638    #define FWDB_MAGIC 0x52474442
   linux-7.2/net/wireless/reg.c:639    #define FWDB_VERSION 20
   ```
   若上游更新，换新文件即可（`valid_regdb()` 会校验 magic/version，不匹配会被拒绝）。
3. **Mesa 侧真正的大头是 virgl 回传（6.9 ms/帧）**，只有把扫描缓冲换成
   hostmem blob 才能根治（显示 HDI 改造，QEMU-only）。
4. **真机直播**：若确认是软解，下一步是换带 VA-API 硬解的 x86_64 Chromium 引擎
   （社区 `chromium_arkweb` + `build_arkweb.sh -t w -A x86_64`，需要 ~100 GB 磁盘，
   见 AGENTS §19.4）或在 B 站客户端侧降码率。
5. `wifi_perf_probe.sh` 里的 `curl` 依赖终端 App 的 Debian rootfs；系统侧只有
   `ping`/`netstat`/`openssl`，若要在系统 shell 里跑需要另配 curl。
6. 本轮**没有**触碰音频（SOF 声卡是另一条独立立项，见 AGENTS §26）。
