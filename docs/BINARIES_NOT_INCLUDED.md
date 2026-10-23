# 本仓未包含的二进制（以及从哪里取）

本仓是**纯源码**仓。下面这些是交付镜像里真实存在、但按「不含二进制/不含私钥」原则被排除的东西。
如果要从源码重建一模一样的镜像，需要把它们补回来。

权威来源：本地归档 `out/x86_64_virt/ohos-dbg/ARCHIVE_2026-10-22.tar.zst`
→ `06_artifacts/delivered/{p2,p3}/`（**直接从交付镜像抽出来的**，不是构建产物）。
交付镜像本身：`out/x86_64_virt/ohos-dbg/partdisk/media/ohos_part_pc_ptl.img`
（sha256 `f1040921bede65a86985fb3b3dc886dbed68cccde21105bea15f6fe5af83ae15`）。

| 类别 | 具体文件 | 为什么被排除 | 从哪里取 |
|---|---|---|---|
| PC 桌面 HAP | `system/app/SceneBoard/SceneBoard.hap`（`be809690…`，95 MB） | 二进制 | `06_artifacts/delivered/p2/system/app/SceneBoard/` |
| 浏览器 HAP | `system/app/com.ohos.browser/Browser.hap`（`1430bc94…`） | 二进制 | 同上 |
| AIRA HAP | `system/app/org.aira.browser/Aira.hap`（`db9ce1bb…`） | 二进制 | 同上 |
| 终端 HAP | `system/app/Terminal/Terminal.hap`（`4a420cd7…`） | 二进制 | 同上 |
| Rime 输入法 HAP | `system/app/com.example.kikakeyboard/kikaInput.hap` | 二进制 | 同上 |
| 终端/Rime 资源 | `NotoSansMono-*.ttf`、`*.png` 图标、`liblibrime_napi.so` | 二进制 | 树内原路径；或归档 `02_tree_new_files` 只含文本，需从工作区另拷 |
| Intel 固件 | `device/pc/ptl/firmware/{xe,i915,intel}/**`、`regulatory.db{,.p7s}` | 二进制（~900 MB） | 树内原路径 `device/pc/ptl/firmware/`；源自 Ubuntu `/lib/firmware` |
| 硬解栈 | `vendor/lib64/{libvpl.so.2,libmfx-gen.so.1.2,libva*.so*,libigdgmm.so.12}`、`vendor/lib64/dri/iHD_drv_video.so`（~69 MB） | 二进制 | `06_artifacts/delivered/p3/vendor/lib64/`（**符号链接在镜像里，抽取后为 0 字节，需重建软链**） |
| Mesa 25 五库 | `libEGL.so.1.0.0`、`libGLESv1_CM.so.1.1.0`、`libGLESv2.so.2.0.0`、`libgbm.so.1.0.0`、`libgallium-25.0.1.so` | 二进制 | `06_artifacts/delivered/p2/system/lib64/`；源码改动见 `sources/third_party/mesa3d-ohos/` |
| 镜像 | `ohos_part_pc_ptl.img`、`*.qcow2` | 5 GB+ | `partdisk/media/`（交付镜像 + 2 个 `.zst` 备份） |
| Secure Boot 私钥 | `partdisk/sb_keys/`（MOK 私钥、PK/KEK） | **绝不可公开** | 只在本地；丢了就无法再签新的 GRUB/内核 |

## 附：HAP 与源码的对应关系

- SceneBoard：源码改动在 `patches/components/sceneboard/`，构建产物必须用
  `window_scene_board@OpenHarmony-7.0-Release` 的 `product/pc`（module `pc_sceneboard`）重编；
  树内 `applications/standard/hap/sceneboard/SceneBoard.hap` 是 **09-24 的旧版**，别直接拿来用。
- 浏览器：`patches/components/browser/`（`fix_ua` + `fix_browser_avc` 两个补丁叠加）。
- AIRA：`patches/components/aira/`（HDS 降级 + HEVC 屏蔽）。
- 终端/Rime：源码在 `sources/applications/standard/{terminal,rime_ime}/`，用 hvigor 重编。
