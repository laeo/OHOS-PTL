# OHOS 7.0 on Intel PTL (HONOR XWC-P) — 源码改动集

目标机：Intel Panther Lake（`8086:0b080`，Intel Arc B390，3072×1920 eDP，ALC256 + SOF，Wi-Fi/BT 为 Intel）
系统：OpenHarmony 7.0 Release，内核 linux-7.2，产品 `pc_ptl`，**Secure Boot 全程开启**（MOK）。

本仓只含**源码级改动**（补丁 + 新增源码 + 脚本 + 文档）。不含 HAP/`.so`/固件/镜像/私钥；
被排除的二进制清单与取用位置见 **`docs/BINARIES_NOT_INCLUDED.md`**。

## 目录

```
patches/tree-ohos/      25 个 OHOS 仓的 git diff（按仓一个 .patch）+ REPO_HEADS.txt
patches/components/     需在对应上游仓应用的补丁
  sceneboard/           window_scene_board (product/pc) 桌面布局 page/area 修复
  aira/                 AIRA 浏览器：HDS 缺失降级 + HEVC 屏蔽/取流改写
  browser/              系统浏览器：去强制 Mobile UA + HEVC guard
  media-driver/         Intel media-driver 26.x 的 clang/C++ 标准修复（oneVPL 硬解栈）
patches/ohos-diag/      ohos-diag（一键诊断）增量
patches/experiments/    调研期补丁（历史保留，非必需）
sources/                新增源码，路径与 OHOS 树一致（device/pc、vendor/pc、terminal、
                        rime_ime、base/startup/ohos_diag、third_party/aira、内核 defconfig、
                        Mesa OHOS 平台层）
scripts/                45 个镜像注入脚本 + partdisk（分区/安全启动/写盘）+ 工具 + 调试脚本
docs/                   总说明 ARCHIVE_MANIFEST.md、交接文档 AGENTS.md、关键修复报告、
                        二进制清单 BINARIES_NOT_INCLUDED.md
```

## 适用基线

见 `patches/tree-ohos/REPO_HEADS.txt`（每个仓的 commit）。补丁用 `git apply` 应用，
均已在原始工作区做过 `git apply --check -R` 反向校验。

## 应用

```sh
# 1) 在已 repo sync 的 OHOS 树根目录
bash scripts/apply-tree-patches.sh /path/to/OHOS

# 2) 新目录（device/pc、vendor/pc、terminal、rime_ime、ohos_diag、third_party/aira）
cp -a sources/* /path/to/OHOS/

# 3) 组件仓补丁（需先 clone 对应仓）
#    window_scene_board  -b OpenHarmony-7.0-Release
#    aira / browser      - 见 docs 中对应 SUMMARY

# 4) 若要从零重建镜像：先补 docs/BINARIES_NOT_INCLUDED.md 里的二进制
# 5) sources/ 里的 env.sh 含本机绝对路径（/home/katax/...），换机器时请改成自己的
```

## 需要的主要修复（摘要）

- 安全启动：自建 GRUB 2.14 恢复 legacy `shim_lock` 回退（Ubuntu 补丁删掉了它）+ `.bss`/`.sbat` 修复
- 桌面：SceneBoard PC 产品版；桌面项 `page`/`area` 归一（真机 3072×1920 桌面空白的根因）
- 图形：RS async 事务 pid=0 丢事务、`GetUniRenderEnabled` 过早缓存、毛玻璃 `ResetClip`
- 显示 HDI：DRM FB 按 buffer 缓存复用（去掉每帧 23.6 MB 重建）
- 输入：MMI 关键事件不丢 + 读 socket 与回调解耦；指针窗口延迟重建
- 音频：SOF 设备延迟重探（`zz_sof_reprobe`）、DAI 混音器守护、固件路径 `intel/sof-ipc4/...`
- 蓝牙：HDI 库名 `.z.so`、`CAP_NET_RAW`、H4 类型字节还原、`bt_enable`/`bt_diag.sh`
- 视频：引擎无 HEVC → 页面层屏蔽 + 取流参数改写；oneVPL/VA-API 硬解栈移植（探针通过）
- 内核：`NAMESPACES/PID_NS/NET_NS`（ArkWeb 渲染子进程）、SOF、IWLWIFI、USB 网卡
- 诊断：`ohos-diag` 一条命令 11 段 + `VERDICT.txt`
- 其他：KikaInput 宽屏键盘限宽、histogram 插件缺失时不再反复 dlopen（见 patch 列表）

## 不包含

- 二进制：HAP、`.so`、Intel 固件、`hdf_hcs.hcb`、镜像
- 敏感：`sb_keys/`（Secure Boot 私钥）—— 仅存于本地归档，**不要提交**

许可证/来源：OHOS 各仓遵循其原许可证；AIRA/Rime 等第三方代码遵循各自许可。
