# fix_sof_topo —— pc_ptl 真机「完全没声音」的定位与修复

> 产品 `pc_ptl`（HONOR XWC-P，Intel Panther Lake，SOF IPC4 + Realtek ALC256，x86_64 2in1）
> 诊断包：`out/x86_64_virt/ohos-dbg/diagwork/d4/`（2026-10-22 真机采集）
> 本轮产物：本目录（`inject.sh` / `scratch.img` / `boot.sh` / `files/` / `tools/` / `work/`）
> 交付镜像 **未改动**（`partdisk/media/ohos_part_pc_ptl.img` sha256 `c2bc9d6868bc858efe18959e45f30e6b699f1bbf6b15634f690f8209c2d5eedb`）

> 本文件由两轮工作合并而成：① 第一轮（拓扑/音量/OHOS 通路的事实梳理 + 诊断脚本 + inject.sh），
> ② 第二轮（本文件标 **[本轮]** 的部分：补充 3 个判据、新增 DAI 混音器守护进程、
> 修正一处内核语义错误、QEMU 端到端复验）。

---

## 0. TL;DR（结论先行）

| # | 结论 | 证据 |
|---|---|---|
| A | **任务假设「需要换 `sof-ptl-*.tplg` 拓扑」不成立**。本机的模拟 codec 是 **ALC256，且挂在 HDA 链上**（不是 cSSP/SDW），因此 **HDA 系列拓扑**（`sof-hda-generic-4ch.tplg`）才是正确的；当前内核已经加载了它 | 真机 dmesg `Topology file: intel/sof-ipc4-tplg/sof-hda-generic-4ch.tplg`；**同一台机器的 Ubuntu 也加载同一份拓扑**且 PipeWire 的 `Speaker` sink 处于 `RUNNING` |
| B | 拓扑**不是**由 ACPI 或匹配表决定的，而是 **ACPI machine 表 + 运行时 fixup**（详见 §2.2），可用 `sof_tplg_filename=` 模块参数覆盖 | `soc-acpi-intel-hda-match.c:16`、`sof/intel/hda.c:1556-1607`、`pci-ptl.c:48`、`fw-file-profile.c:186,255` |
| C | **没有 "Speaker PCM" 是正常的**：SOF 拓扑里的 DAI 叫 `HDA Analog`（PCM 0），"Speaker/Headphone" 是 **ALC256 codec 的 mixer 控件**，不是 PCM | `/proc/asound/pcm`：`00-00 HDA Analog`；`amixer`：`Speaker`、`Headphone` |
| D | 音量链路**没有明显问题**：ALC256 speaker = line-out 0x1b，`Speaker Playback Volume`=87 (mute=0)、`Master Playback Volume`=56 (mute=0) | 真机 `amixer -c0 cget` |
| E | **OHOS 侧 HDI 已经是 ALSA 模式且已成功打开 PCM**：`audio_host` 持有 `/dev/snd/pcmC0D0p`；`speaker-test` 报 `Resource busy`（=被 HDI 独占，正常） | 真机 `ls -l /proc/*/fd` |
| F | 真正没声的**剩余嫌疑只有两处**，且**互斥**：(1) SOF DAI 混音器（numid 31/32 "Pre/Post Mixer Analog Playback Volume"）=0 → 数字静音；(2) OHOS 框架侧（新版 HPAE 引擎）根本没把数据写进 PCM | 本轮新增自动判定项 + 一个**破坏性实测**（§5、§6） |
| G | 顺带修掉一个**诊断阻塞点**：真机 `hidumper` 一直 `request error`（镜像里的 `libhidumperservice.z.so` 是 24-Sep 的旧库，缺 "root 可 dump" 补丁）。已重编并注入 → `hidumper -s AudioPolicyService` 可用 | 树内补丁 `dump_manager_service.cpp:205-228`；QEMU 实测 `audio/hidumper-audiopolicy` **PASS** |
| H | **[本轮]** **交付镜像里的音量修复已经生效**，音量不是"没生效"，而是"框架没调用它"：镜像 p3 的 `libaudio_render_adapter.z.so`（15-Oct 重编）**已含** "按能力探测音量控件 + numid=0 按名字解析" 的补丁 | 从交付镜像 p3 里 `debugfs dump` 出来 `strings` 可见 `Render volume control probed` / `unmute with no saved volume`；树内补丁见 `drivers/peripheral/audio/supportlibs/alsa_adapter/src/vendor_render.c` |
| I | **[本轮]** 修正一处内核语义错误（上一版文档写反了）：`snd_ctl_find_id()` 是 **numid 优先于 name**（`sound/core/control.c:855`：`if (id->numid != 0) return snd_ctl_find_numid(...)`）。所以老代码里硬编码的 `numid=1` 在本机会打到 **`Headphone Playback Volume`**，而不是 `Master Playback Volume` | `kernel/linux/linux-7.2/sound/core/control.c:847-872` |
| J | **[本轮]** SOF 的 DAI-link 增益控件会在**建流时被重新初始化**，一次性（开机）写入的混音器值可能被打回 0（=数字静音）→ 新增常驻守护进程 `zz_audioguard.sh` 每 5 s 复查并按需拉满 | `device/pc/ptl/.../zz_audioguard.sh`（本轮新增） |

---

## 1. 该机型的 codec / SSP / 拓扑事实

### 1.1 声卡与 codec（真机 dmesg，`diagwork/d4/C_audio.txt` + `B_dmesg_boot_t0.log`）

```
[196.463477] sof-audio-pci-intel-ptl 0000:00:1f.3: hda codecs found, mask 5
[196.463483] sof-audio-pci-intel-ptl 0000:00:1f.3: using HDA machine driver skl_hda_dsp_generic now
[196.463494] sof-audio-pci-intel-ptl 0000:00:1f.3: DMICs detected in NHLT tables: 4
[196.472942] sof-audio-pci-intel-ptl 0000:00:1f.3: Topology file:     intel/sof-ipc4-tplg/sof-hda-generic-4ch.tplg
[196.816883] sof-audio-pci-intel-ptl 0000:00:1f.3: loading topology: intel/sof-ipc4-tplg/sof-hda-generic-4ch.tplg
[196.829080] snd_hda_codec_alc269 ehdaudio0D0: autoconfig for ALC256: line_outs=1 (0x1b/0x0/0x0/0x0/0x0) type:speaker
[196.829086] snd_hda_codec_alc269 ehdaudio0D0:    speaker_outs=0 (0x0/0x0/0x0/0x0/0x0)
[196.829090] snd_hda_codec_alc269 ehdaudio0D0:    hp_outs=1 (0x21/0x0/0x0/0x0/0x0)
[196.829092] snd_hda_codec_alc269 ehdaudio0D0:    mono: mono_out=0x0
```

事实：
* DSP = Intel PTL，IPC4，固件 `intel/sof-ipc4/ptl/sof-ptl.ri`（ADSPFW 2.14.1.1），库 `intel/sof-ipc4-lib/ptl`。
* **模拟 codec = Realtek ALC256**，位于 **HDA 控制器**（`ehdaudio0D0`，PCI 00:1f.3）上，由 `snd_hda_codec_alc269` 驱动。
  → `hda codecs found, mask 5`（bit0=HDMI、bit2=ALC256）→ 内核选择 **HDA machine driver**，而不是 SDW/cSSP machine。
* **扬声器 = codec 的 line-out 0x1b**（`type:speaker`），没有独立的 speaker pin（`speaker_outs=0`），
  即 line-out 直接喂外部功放；耳机 = 0x21。**没有需要额外使能的 GPIO/regulator**
  （同机 Ubuntu 有声即为证）。
* DMIC 数量 = 4（NHLT）→ 决定拓扑名后缀 `-4ch`。
* NHLT 只报 **BT 挂在 SSP2**（`ssp_mask 0x4`），**没有任何 SSP 功放链路** → 本机扬声器不挂在 cSSP codec 上。

### 1.2 拓扑选择机制（**不是 ACPI，也不是匹配表里的拓扑名**）

调用链（内核 `linux-7.2`）：

| 步骤 | 位置 | 内容 |
|---|---|---|
| ① ACPI machine 表 | `kernel/linux/linux-7.2/sound/soc/intel/common/soc-acpi-intel-hda-match.c:12-18` | `.drv_name = "skl_hda_dsp_generic"`、`.sof_tplg_filename = "sof-hda-generic"`（注释：*"the tplg suffix is added at run time"*） |
| ② 选 machine | `sound/soc/sof/intel/hda.c:1085-1096` | 打印 `using HDA machine driver %s now`；有 HDA codec 时即用 `skl_hda_dsp_generic` |
| ③ 运行时 fixup | `sound/soc/sof/intel/hda.c:1556-1607` | 基名 `sof-hda-generic` + `-<dmic_num>ch`（`check_dmic_num()`，本机 4）→ **`sof-hda-generic-4ch`**；再按 NHLT 追加 `-ssp<N>` / `-ssp<N>-bt`（本机无 SSP codec，故不加） |
| ④ 目录 | `sound/soc/sof/intel/pci-ptl.c:48-50` | `.default_tplg_path = { [SOF_IPC_TYPE_4] = "intel/sof-ipc4-tplg" }` |
| ⑤ 拼路径/打印 | `sound/soc/sof/fw-file-profile.c:186-189`、`:255` | `Topology file: %s/%s` |
| ⑥ 可选覆盖 | `sound/soc/sof/core.c:36-40` | 模块参数 **`sof_tplg_path=` / `sof_tplg_filename=`**（命令行 `sof_tplg_filename=xxx.tplg`）；ACPI `_DSD` 里的 `sof-name` 在 Intel 路径上**没有**被使用 |

> cSSP/SDW 机器走的是另一条分支：`sound/soc/sof/intel/hda.c:1400-1430` 里给 SDW machine 塞的是
> `sof-<platform>-dummy.tplg`（"避免 tplg 文件检查"），并使用 **function topologies**。

### 1.3 为什么 `sof-ptl-*.tplg` 不适用

`device/pc/ptl/firmware/intel/sof-ipc4-tplg/` 里有 189 个拓扑，其中 38 个 `sof-ptl-*`，但它们全部是
**cSSP/SDW codec 机器**的拓扑：

```
sof-ptl-cs42l43-agg-l3-cs35l56-l2-4ch.tplg   sof-ptl-es8336-ssp1.tplg
sof-ptl-rt711.tplg   sof-ptl-rt711-2ch.tplg   sof-ptl-rt712-l2-rt1320-l1.tplg
sof-ptl-hdmi-ssp02.tplg   sof-ptl-dmic-4ch-id*.tplg  ...
```

本机 codec 是 **ALC256（HDA 链）**，所以正确的族是 **`sof-hda-generic*`**（同目录 24 个），
并且当前加载的 `sof-hda-generic-4ch.tplg` 正是内核按 §1.2 规则算出来的那个。
**换 `sof-ptl-*.tplg` 会得到一张没有模拟输出、没有 DMIC 的卡。**

### 1.4 **决定性对照：同一台机器的 Ubuntu 用的是同一份拓扑，而且有声音**

宿主机就是这台真机（Ubuntu 26.04 / 同一颗 PTL / 同一块 ALC256）：

```
$ journalctl -k -b | grep sof
sof-audio-pci-intel-ptl 0000:00:1f.3: using HDA machine driver skl_hda_dsp_generic now
sof-audio-pci-intel-ptl 0000:00:1f.3: Topology file:     intel/sof-ipc4-tplg/sof-hda-generic-4ch.tplg
sof-audio-pci-intel-ptl 0000:00:1f.3: loading topology: intel/sof-ipc4-tplg/sof-hda-generic-4ch.tplg

$ pactl list short sinks
58  alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__HDMI3__sink  SUSPENDED
59  ...HiFi__HDMI2__sink  SUSPENDED
60  ...HiFi__HDMI1__sink  SUSPENDED
61  alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Speaker__sink  RUNNING   <== 模拟输出在跑
```

宿主的 mixer（**同一张卡**，`amixer -c0 controls` 全表）：

```
numid=1  'Headphone Playback Volume'   numid=2  'Headphone Playback Switch'
numid=3  'Speaker Playback Volume'      numid=4  'Speaker Playback Switch'
numid=5  'Auto-Mute Mode'               numid=6  'Master Playback Volume'
numid=7  'Master Playback Switch'       numid=8  'Headphone Jack'
numid=9  'Speaker Phantom Jack'         numid=31 'Pre Mixer Analog Playback Volume'
numid=32 'Post Mixer Analog Playback Volume'      numid=46 'Pre Mixer Deepbuffer HDA Analog Volume'
numid=11..26 'IEC958 *'（HDMI1/2/3）   numid=33..36 'Post Mixer Analog Playback {IIR Eq,FIR Eq,DRC bytes,DRC switch}'
numid=37..45 'Analog/Dmic0 Capture *'
```

宿主的取值（**这就是"正常"的基准值**）：

```
$ amixer -c0 cget name='Master Playback Volume'            -> numid=6, values=87, mute=0
$ amixer -c0 cget name='Speaker Playback Volume'           -> numid=3, values=87,87, mute=0
$ amixer -c0 cget name='Pre Mixer Analog Playback Volume'  -> numid=31, values=45,45 (0..45, 45=max)
$ amixer -c0 cget name='Post Mixer Analog Playback Volume' -> numid=32, values=45,45
$ amixer -c0 cget name='Auto-Mute Mode'                    -> values=0 (Disabled)
$ cat /proc/asound/card0/pcm0p/sub0/status                 -> state: RUNNING, hw_ptr 527360496 (在动)
```

**结论：SOF 侧（固件 + 拓扑 + codec + mixer）在这台机器上是好的**，Ubuntu 用同一份拓扑出声。
→ 故障在 **OHOS 用户态**（框架 / HDI 数据流 / SOF DAI 混音器状态）。

---

## 2. 音量链路核对

| 环节 | 真机实测 | 判定 |
|---|---|---|
| codec | ALC256 @ `ehdaudio0D0`，speaker = line-out 0x1b | OK |
| `Master Playback Volume`（HDI 用的控件，numid=6） | `values=56, mute=0` | OK（-23dB，非 0） |
| `Speaker Playback Volume`（numid=3） | `values=87,87, mute=0` | OK（100%） |
| `Headphone Playback Volume`（numid=1） | `values=87,87, mute=0` | OK |
| `Auto-Mute Mode`（ALC256 自动静音，numid=5） | 存在（真机未采集数值） | **未确认** → 本轮开机脚本强制置 `Disabled` |
| **SOF DAI 混音器**（`Pre/Post Mixer Analog Playback Volume`，numid 31/32） | **真机诊断包里没有这一项** | **未知 → 头号嫌疑**（见 §3） |
| 功放使能 | 无独立 speaker pin（`speaker_outs=0`），line-out 0x1b 直出功放；无额外 GPIO/regulator 需要（Ubuntu 同机有声即证） | OK |

> **[本轮] 控件解析的一个重要细节**：内核 `snd_ctl_find_id()`（`sound/core/control.c:855`）是
> **numid 优先于 name**：
> ```c
> if (id->numid != 0)
>         return snd_ctl_find_numid(card, id->numid);
> ```
> 所以：
> * 老代码（`numid=1` + name="Master Playback Volume"）在本机**会打到 `Headphone Playback Volume`**，
>   扬声器音量永远不会被框架改；
> * 修好的代码（`numid=0` + name="Master Playback Volume"）才会正确落到 numid 6。
>   交付镜像 p3 里的 `libaudio_render_adapter.z.so`（15-Oct）**已经是修好的版本**
>   （证据：`work/libaudio_render_adapter.z.so`，从交付镜像 p3 `debugfs dump` 出来，
>   md5 `9b5145db1dbd6f0ad48e018df4ba48bd`，`strings` 里能看到 `Render volume control probed`
>   与 `unmute with no saved volume`），所以"音量没生效"这条不成立：
>   真机上 Master=56 是 **codec 的上电默认值（0x38）**，说明框架至今没有调用过 SetVolume。
>
> 注意：`amixer` 的 *simple control* 名字（`Speaker`）与 *control-level* 名字（`Speaker Playback Volume`）
> 是两套命名；HDI 用的是后者。`amixer -c0 get Speaker` 报 "Unable to find simple control" **不代表控件不存在**。

---

## 3. OHOS 侧通路核对

### 3.1 框架 → HDI

* 框架用的是**新版 HPAE 引擎**，不是 PulseAudio：
  `foundation/multimedia/audio_framework/config.gni:40` → `audio_framework_feature_new_engine_flag = true`；
  `frameworks/native/audioadapter/src/pro_audio_service_adapter_impl.cpp:99` → `IHpaeManager::GetHpaeManager().OpenAudioPort()`。
  → 策略里那句 `paProp lib="libmodule-hdi-sink.z.so"` 是**历史字段**；HPAE 只把它当字符串比较
  （`services/audio_engine/manager/src/hpae_manager.cpp:563-601`、`hpae_renderer_manager.cpp:283`），
  **不会 dlopen 这个 .so**，所以"缺 PA 模块"**不是**问题。
* 策略配置在位：`/vendor/etc/audio/audio_policy_config.xml`（`primary` adapter / `primary_output` pipe /
  `Speaker_Out` / `Built_in_mic`），来源 `vendor/ohemu/virt/hals/audio/config/x86_64/audio_policy_config.xml`。
  QEMU 实测 `hidumper -s AudioPolicyService` 输出 `device name:SPEAKER Highest priority output` → **策略侧选中的是扬声器，没问题**。

### 3.2 HDI → ALSA

* pc_ptl 继承了 `vendor/ohemu/virt/virt_common_x86_64.json:130`
  → `drivers_peripheral_audio_feature_alsa_lib = true`
  → HDI 走 **ALSA 模式**：`drivers/peripheral/audio/hdi_service/supportlibs/BUILD.gn:75-101,163-189`
  （`alsa_soundcard.c` + `alsa_snd_render.c` + `vendor_render.c`；`is_emulator=true`（x86_64）所以用树内那份
  `supportlibs/alsa_adapter/src/vendor_render.c`）。
* 选卡：`alsa_soundcard.c:335-348`（`DevGetInfoByAdapter`，按 **cardId** 匹配）+
  `alsa_soundcard.c:645-700`（`SndMatchSelAdapter` → `hw:%d,%d`）
  + `vendor/ohemu/virt/hals/audio/alsa_adapter.json` → **cardId 0 / "sof-hda-dsp"**。
  ⇒ 打开的是 **PCM 0 = `HDA Analog`（playback）**，与 Ubuntu 的 `Speaker` sink 同一个 PCM。
* 路径选择：`primary_impl/src/audio_adapter.c:170-177,247` → `cardServiceName = "hdf_audio_codec_primary_dev" + portId`
  = `hdf_audio_codec_primary_dev0`，与 `alsa_paths.json` 的 key 一致；
  `hal/pathselect/src/audio_pathselect.c:407-475`（非 P7885 分支）**只记录**不施加混音器开关，所以
  `alsa_paths.json` 里的 RK 风格 `"Playback Path": 3` 不会误伤本机
  （树内也没有任何代码写 "Pre/Post Mixer ..." 这些名字，`grep` 全树无命中）。
* 真实机证据：`audio_host` 打开 `/dev/snd/pcmC0D0p` + 3 个 `controlC0`
  （`diagwork/d4/C_audio.txt` "who holds /dev/snd"）；
  `speaker-test -D default` → `Playback open error: -16,Resource busy`（=被 HDI 独占，符合预期）。

### 3.3 hidumper（诊断阻塞点，已修）

真机 `hidumper -s AudioPolicyService` → `request error`（`diagwork/d4/C_hidumper.txt` 只有 14 字节）。
镜像里的 `libhidumperservice.z.so` 是 24-Sep 的旧库，**不含**树内补丁
`base/hiviewdfx/hidumper/services/native/src/dump_manager_service.cpp:205-228`
（"Allow root caller to dump"）。本轮重编（38 s）并注入 → 修复。

### 3.4 结论

> **"没有 Speaker PCM" 不是问题**（PCM0 `HDA Analog` 就是它）；**拓扑不是问题**；**音量控件不是问题**。
> 剩下两条互斥的可能：
> **(1) SOF DAI 混音器 numid 31/32 = 0**（数字静音：PCM 在 RUNNING、codec 未静音，但 DSP 里被置 0）；
> **(2) OHOS 框架侧没有真正把音频数据写进 PCM**（新版 HPAE 引擎路径）。
> 本轮用**一个破坏性命令**把两者分开（§6）。

---

## 4. 本轮改动

### 4.1 树内（`/home/katax/Public/OHOS`）

| 文件 | 改动 |
|---|---|
| `base/startup/ohos_diag/ohos-diag` | ① `sec_audio()` 新增 **4 个**可自动判定项：`audio/master-ctrl-unmuted`（Master 值>0 且 mute=0）、`audio/speaker-output-pcm-present`（扬声器输出 PCM 存在）、`audio/pcm-data-flowing`（**hw_ptr 是否在动** = 框架有没有喂 PCM）、`audio/sof-dai-mixer-nonzero`（Deepbuffer 混音器）；② 混音器判据增加 `max=` 显示；③ 修掉 `oneline "$X"` 的误用（`oneline` 读 stdin，不是参数）→ 4 处改成 `printf '%s' "$X" \| oneline`，否则详情列是空的；④ `VSPEC` 表 +5 行 |
| `base/startup/ohos_diag/zz_audioup.sh` | 开机一次性播放通路体检：**max 从控件自身解析**（不再写死 45）、把 DAI 混音器**强制拉到 max**（不只在 =0 时）、打印**完整 mixer map**（`amixer -c0 controls`）便于回报 |
| `base/startup/ohos_diag/zz_audioguard.sh`（**新**） | **常驻守护**：每 5 s 复查 `Pre/Post Mixer Analog Playback Volume` + `Pre Mixer Deepbuffer HDA Analog Volume`，掉到 max 以下就拉回；顺带把 `Auto-Mute Mode` 保持 `Disabled`。**只在值不对时才写**，无日志刷屏。理由：SOF 在建流时会重新初始化 DAI-link 控件，开机一次性写入可能被覆盖 |
| `base/startup/ohos_diag/etc/zz_audio.cfg` | 增加 `zz_audioguard` 服务（`once:0` 常驻），`post-init` 作业里一起启动 |
| `base/startup/ohos_diag/BUILD.gn` | 注册 `audioguard_script` |
| （第一轮）`base/hiviewdfx/hidumper/.../dump_manager_service.cpp` | "root 可 dump" 补丁（重编 `libhidumperservice.z.so` 并注入） |

### 4.2 本轮产物（`out/x86_64_virt/ohos-dbg/fix_sof_topo/`）

```
inject.sh          幂等注入（p2=/system）；默认拒绝改交付镜像（--force 才放行）
                   —— 幂等判据是"载荷内容"（步骤 5 逐文件回读比对 + 末尾 payload manifest），
                      ext4 镜像本身不会逐字节相同（e2fsck/分配器状态会变）
src/zz_audiotest   v2：新增 "tonehw" 子命令（停 audio_host → hw:0,0 放音 → 拉起，含重试）
files/             注入载荷（ohos-diag / zz_audioup.sh / zz_audioguard.sh / zz_audio.cfg /
                   zz_audiotest / libhidumperservice.z.so）
tools/ser.py       串口小助手（连 unix socket、记日志、按命令文件注入命令）—— guest 的 hdcd
                   在 TCP 模式下不监听，只能走串口
boot.sh            QEMU 验证用启动脚本（独立 VNC:27 / hdc:5558 / 私有 qemu 二进制名，避免与并发会话互杀）
scratch.img        交付镜像的稀疏副本 + `truncate -s 41015872K` + `sgdisk -e`（修 GPT 备份头）
work/              注入日志 / e2fsck / QEMU 串口日志 / 判定表（qemu_verdict_audio.txt）
build_hidumper.log libhidumperservice 重编日志（38 s，target=base/hiviewdfx/hidumper/services:hidumperservice）
```

---

## 5. 可自动判定的项（真机一条命令）

```sh
hdc shell "ohos-diag audio"        # 非破坏性：14 个音频判据
hdc shell "ohos-diag audiotest"    # 破坏性：内核通路 vs 框架 通路（见下）
hdc shell "hidumper -s AudioPolicyService"   # 框架选中的输出设备（本轮修复后可用）
```

| 键 | 期望 | 含义 |
|---|---|---|
| `audio/sof-topology-in-dmesg` | PASS | 开机 dmesg 有 `Topology file:` 行（拓扑到底用的哪个） |
| `audio/sof-topology-file-present` | PASS | 该拓扑文件确实在 `/system/lib/firmware/intel/sof-ipc4-tplg/` 里 |
| `audio/speaker-on-hda-codec` | PASS | dmesg 有 `autoconfig for ALCxxx: ... type:speaker`（扬声器在 HDA codec 上 ⇒ HDA 拓扑正确） |
| `audio/speaker-ctrl-unmuted` | PASS | `Speaker Playback Volume` 存在、`mute=0`、值 > 0 |
| `audio/master-ctrl-unmuted` | **PASS（本轮新增）** | `Master Playback Volume` 存在、值 > 0、`mute=0` |
| `audio/speaker-output-pcm-present` | **PASS（本轮新增）** | 播放 PCM 存在（SOF 卡上它叫 `HDA Analog`；**没有**名为 `Speaker` 的 PCM） |
| `audio/sof-pre-mixer-nonzero` | PASS | `Pre Mixer Analog Playback Volume` > 0（**0 = SOF 数字静音**） |
| `audio/sof-post-mixer-nonzero` | PASS | `Post Mixer Analog Playback Volume` > 0 |
| `audio/sof-dai-mixer-nonzero` | **PASS（本轮新增）** | `Pre Mixer Deepbuffer HDA Analog Volume` > 0 |
| `audio/pcm0p-state` | PASS | `/proc/asound/card0/pcm0p/sub0/status` 可读（`state:` / `owner_pid:`） |
| `audio/pcm-data-flowing` | **PASS（本轮新增）** | **播放中 `hw_ptr` 在递增** = 框架真的在喂 PCM；RUNNING 却不递增 ⇒ 框架没喂 |
| `audio/hdi-owns-pcm` | PASS | `audio_host` 打开 `pcmC0D0p` |
| `audio/hidumper-audiopolicy` | PASS | `hidumper -s AudioPolicyService` 出结果（不再 `request error`） |
| `audio/kernel-tone-hw0` | PASS | **破坏性**：`hw:0,0` 上 `speaker-test` 真的在放（内核/ALSA/SOF/ALC256 通路 OK） |
| `audio/pcm-running-during-tone` | PASS | **破坏性**：放音期间 `pcm0p` 处于 `RUNNING` |
| `audio/hdi-restarted-after-test` | PASS | **破坏性**：测试后 `audio_host` 恢复 |

**怎么用这几个判据定位**：

| `kernel-tone-hw0` | `pcm-data-flowing` | `pcm0p-state` | 结论 |
|---|---|---|---|
| PASS | PASS（hw_ptr 在动） | RUNNING | 内核通路 OK 且框架在喂数据 → **问题在 codec/功放/模拟输出端** |
| PASS | **FAIL**（RUNNING 但 hw_ptr 不动） | RUNNING | **框架开了 PCM 但没写数据** → 框架侧（HPAE / hdiadapter_new） |
| PASS | WARN（PREPARED, hw_ptr=0） | PREPARED | 框架**根本没起流** → 框架侧路由/策略 |
| FAIL（无声） | — | — | **SOF DAI 混音器/codec 侧** → 看 `sof-pre/post-mixer-nonzero`、`speaker-ctrl-unmuted`；本轮的 `zz_audioup`/`zz_audioguard` 已开机自动把它们拉满 |

> `audio/pcm-data-flowing` 需要**正在播放**时才有意义（脚本会等 2 s 比较 `hw_ptr`）；没在播放时它给 WARN。

---

## 6. QEMU 验证（本轮自证）

用 `fix_sof_topo/scratch.img`（交付镜像稀疏副本 + 本轮注入）引导 QEMU
（`boot.sh`，ich9-intel-hda + hda-duplex，QEMU 里**没有** SOF/ALC256，所以与真机不可比的项应当
FAIL/SKIP 而不是崩溃）。本轮证据：`work/qemu_verdict_audio.txt`（从 guest 里
`tar -xzOf .../diag-*.tar.gz _verdict.tsv` 取出的判定表）。

```
FAIL|audio/sofhdadsp-card-present|no sofhdadsp in /proc/asound/cards     (QEMU 无 SOF，符合预期)
PASS|audio/asound-cards|/proc/asound/cards (97 B)
PASS|audio/pcm-devices|1 line(s) in /proc/asound/pcm
PASS|audio/master-playback-volume|amixer control present
PASS|audio/master-ctrl-unmuted|Master Playback Volume=47 mute=0           <== 新判据，works
PASS|audio/speaker-output-pcm-present|playback PCM: 00-00: Generic Analog  <== 新判据，works
PASS|audio/aplay-default-playback|device busy: held exclusively by audio_host
PASS|audio/device-exclusive-owner|audio_host running (pid 822)
PASS|audio/boot-dmesg-has-sof|matched x15 (sof)
PASS|audio/zz-sof-reprobe-ran|6 ZZSOF: lines from: /sys_prod/dmesg_boot_t15.log
FAIL|audio/sof-topology-in-dmesg|no 'Topology file:' line ...             (QEMU 无 SOF)
SKIP|audio/sof-topology-file-present|topology name unknown
WARN|audio/speaker-on-hda-codec|no 'autoconfig for ALCxxx' line ...        (QEMU 无 ALC)
FAIL|audio/speaker-ctrl-unmuted|no 'Speaker Playback Volume' control on card 0 (QEMU HDA-Intel 无此控件)
SKIP|audio/sof-pre-mixer-nonzero|control 'Pre Mixer Analog Playback Volume' not present
SKIP|audio/sof-post-mixer-nonzero|control 'Post Mixer Analog Playback Volume' not present
SKIP|audio/sof-dai-mixer-nonzero|control 'Pre Mixer Deepbuffer HDA Analog Volume' not present
PASS|audio/pcm0p-state|state: PREPARED owner_pid : 2333
WARN|audio/pcm-data-flowing|PCM not running (state=PREPARED), hw_ptr 0->0  <== 新判据，语义正确
PASS|audio/hdi-owns-pcm|pcmC0D0p opened by:
PASS|audio/hidumper-audiopolicy|  - device name:SPEAKER Highest priority outpu  <== hidumper 修好了！
```

开机脚本在本轮注入后确实在跑（guest 串口日志）：

```
[   55.938599] ZZAUDIOG: guard started (re-asserts the SOF DAI mixers + Auto-Mute every 5 s)
[   61.040583] ZZAUD: raised 'Master Playback Volume' from 0 to 64%
```

> QEMU 里 `ich9-intel-hda` 与真机 SOF 路径不同，只能证明**脚本/判据/注入链路**正确，
> 不能证明真机出声；真机结论必须看 §8 的判据。

---

## 7. 真机操作步骤

```sh
# 1) 生成一份自己的镜像（不要改交付镜像）
cd /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/fix_sof_topo
cp --sparse /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/partdisk/media/ohos_part_pc_ptl.img my.img
truncate -s 41015872K my.img && sgdisk -e my.img
bash inject.sh my.img

# 2) 刷盘（用既有的 dd_and_verify.sh / partdisk 流程），插盘启动

# 3) 一条命令拿判定
hdc shell "ohos-diag audio"        # 14 个音频判据
hdc shell "ohos-diag audiotest"    # 决定性：内核通路 vs 框架
hdc shell "hidumper -s AudioPolicyService" | head -40
```

**若 `ohos-diag audiotest` 里 `audio/kernel-tone-hw0` = FAIL**：
说明连硬件直通都无声 → 看 `audio/sof-pre-mixer-nonzero` / `audio/sof-post-mixer-nonzero` /
`audio/speaker-ctrl-unmuted`；本轮的 `zz_audioup` + `zz_audioguard` 已开机自动把它们拉满，
若仍 FAIL，说明 SOF DSP 侧被静音（需查 `sof` 的 IPC4 pipeline/`hw_params`）。

**若 `audio/kernel-tone-hw0` = PASS 而系统仍然没声**：
说明问题在 OHOS 框架侧（新 HPAE 引擎）→ 下一轮抓
`hilog | grep -iE 'HPAE|hdiadapter|AudioRenderer|IHpaeManager'` 与 `hidumper -s AudioPolicyService`
的输出设备，并看 `audio/pcm-data-flowing`（hw_ptr 动不动）。

---

## 8. 回退

| 对象 | 回退方法 |
|---|---|
| 镜像 | 本轮**没有**改交付镜像；`fix_sof_topo/scratch.img` 只是验证副本，删掉即可 |
| 树内 `ohos-diag` | 该目录不是 manifest 仓，直接回退文件即可（删掉新增的判据块与 `VSPEC` 行） |
| 树内 `zz_audioup.sh` / `zz_audioguard.sh` / `etc/zz_audio.cfg` / `BUILD.gn` | 删除 `zz_audioguard.sh`，把 `zz_audio.cfg` 的 `zz_audioguard` 服务去掉，再去掉 BUILD.gn 里的 `:audioguard_script` |
| 已注入的镜像 | `bash inject.sh <img>` 是幂等的；把 `/system/bin/ohos-diag`、`/system/bin/zz_audioup.sh`、`/system/bin/zz_audioguard.sh`、`/system/etc/init/zz_audio.cfg`、`/system/bin/zz_audiotest`、`/system/lib64/libhidumperservice.z.so` 换回旧文件（备份见 `fix_alsa_bt_desktop` 的 `.zst`）即可；`libhidumperservice.z.so` 回退后 hidumper 重新变成 `request error`（不影响功能，只是诊断） |

---

## 9. 遗留 / 未完成

1. **真机没跑过本轮镜像**：本轮只有 QEMU 侧验证（脚本/判据/注入正确）。真机判定见 §7。
2. **`ohos-diag audiotest` 是破坏性的**：会停 `audio_host`（init 会自动拉起，实测 ~2 s 内恢复）。
   若机器上正在放音会被打断。
3. **真机上 SOF DAI 混音器（numid 31/32/46）的实际数值仍未知**（诊断包没采集）——这正是新增判据要回答的，
   `zz_audioup`/`zz_audioguard` 会顺手把它们拉到 max 并把最终值写进 `ZZAUD:` / `ZZAUDIOG:` 日志。
4. **`alsa_paths.json` 仍是 RK 风格**（`"Playback Path": 3`）：本产品非 P7885 分支只记录不施加，
   当前无害；若以后要做"耳机/扬声器 pin 自动切换"，需要按 ALC256 控件重写并让 vendor 层真正消费。
5. **框架侧（HPAE）未深挖**：本轮只证明"内核通路可独立验证"，没有定位到"框架为什么不写数据"。
   下一轮用 `audio/pcm-data-flowing` + `hilog | grep -iE 'HPAE|hdiadapter'` 定位。
6. **hidumper 只补了 root 放行**：非 root 调用者仍按 APL 过滤（`dump_manager_service.cpp:205-228`）。
7. **`alsa_soundcard.c` 里其它调用点仍用 `numid` 定位控件**（`SetElementInfo()`），本轮只修了 vendor_render.c
   的音量控件；如果以后有别的代码写 "Playback Path"（numid=1），它会打到 `Headphone Playback Volume`。
