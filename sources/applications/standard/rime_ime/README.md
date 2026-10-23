# rime_ime — Rime 输入法（OpenHarmony PC 镜像）

面向 OpenHarmony PC 镜像（产品 `pc_ptl`，x86_64，2in1）的 Rime 输入法：
N-API 原生桥 + ArkTS 输入法扩展 + Rime 方案配置。

| 目录 | 内容 |
|---|---|
| `hap/` | ArkTS 工程，bundle `com.ohos.rimeime`，模块 `entry` |
| `etc/rime/` | `default.yaml` + `rime_ice_ohos.schema.yaml`（安装到 `/system/etc/rime`） |
| `tools/` | hvigor 工具链环境与构建脚本 |

## 结构

- `hap/entry/src/main/ets/ime/RimeImeService.ets` — `InputMethodExtensionAbility` 入口。
- `hap/entry/src/main/ets/model/ImeController.ets` — **键位处理契约**（见下）。
- `hap/entry/src/main/ets/model/RimeBridge.ets` — N-API 薄封装。
- `hap/entry/src/main/ets/model/HardKeyUtils.ets` — 物理键码 → Rime 键值。
- `hap/entry/src/main/ets/model/Log.ets` — hilog **+ 文件**双写。
- `hap/entry/src/main/ets/pages/Candidate.ets` — 候选浮窗。
- `hap/entry/src/main/ets/pages/RimeSettings.ets` / `settings/RimeSettingsAbility.ets` — 设置页。
- `hap/entry/libs/x86_64/liblibrime_napi.so` — librime 原生桥。

### 键位契约（不要回退）

| 契约 | 行为 |
|---|---|
| `Shift/Ctrl/Alt + 其它键` 一律透传 | 不喂 Rime、不消费 |
| 修饰键本身永不消费 | Ctrl/Alt/Shift down 与 up 都直接 `return false` |
| Shift 仅在「干净点按」时切中英 | 按下到抬起之间按过别的键就不切 |
| 数字 `0–9` 非组词态透传 | 仅 `composing && 1–9` 时选候选 |
| `Ctrl+Shift+4` / `Ctrl+Shift+9` | 简繁切换 / 切换方案 |
| CapsLock 只读 | 监听但不消费 |

### 两个已知陷阱

1. **退格**必须传 `'\\b'`（两字符），不是 `'\b'`。N-API 侧 `MapKeycode` 匹配的是 `"\\b"`；
   传单字符 0x08 会被 Rime 忽略。
2. **`isReady()` 不能在 ArkTS 侧缓存**。librime 在后台线程部署词库，setup 成功后立刻问
   `isReady()` 仍可能是 false；必须每次问原生。
3. **全拼/双拼方案不能共用同一 `dictionary:`**。librime 每次部署只编译一份
   `<dict>.prism.bin`，双拼方案会赢下编译，导致全拼方案之后每个音节都按双拼映射解析
   （表现为 `nihao → 你哈哦`）。本镜像只保留全拼方案；若要双拼必须给独立 dict 名
   （词库 16 MB，`/system` 分区放不下）。

## 构建

### 配置（走标准 `./build.sh`）

```sh
./build.sh --product-name pc_ptl --ccache --jobs 8 --keep-ninja-going \
  --gn-args linux_kernel_version='"linux-7.2"' \
  --build-target applications/standard/rime_ime:pc_rime_ime
```

安装目标：`/system/etc/rime/{default.yaml, rime_ice_ohos.schema.yaml}`。

### HAP（hvigor 独立构建）

```sh
cd applications/standard/rime_ime
bash tools/build_hap.sh      # → hap/entry/build/default/outputs/default/entry-default-unsigned.hap
```

- **未签名 HAP 可直接预装**（`install_list_capability.json` 无需改），这是与其它系统应用
  不同的地方，务必不要改成签名 HAP 白走 `EnforceCodeSignForAppWithPluginId`。
- 工具链与路径覆盖方式同 `applications/standard/terminal/tools/env.sh`。
- `hilog` 域 `0xA0300` 属保留域，非系统应用的 `hilog.info` 会被静默丢弃，所以
  `Log.ets` 双写到 `<filesDir>/rime_ime.log`。

## 许可

Apache-2.0，见 `LICENSE`。注意 `hap/entry/libs/x86_64/liblibrime_napi.so` 是
**预编译二进制**，其上游 librime 为 GPL-3.0 / LGPL-2.1 双重许可；再分发前请确认
`librime_napi` 的链接方式（动态链接 LGPL 或提供源码）满足相应条款。