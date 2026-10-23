# pc_ptl 真机固件清单（device/pc/ptl/firmware）

> 目标硬件：Intel Panther Lake（XONA X7-358H），x86_64。宿主 = 同款 Ubuntu。
> 固件来源：宿主 `/lib/firmware`（本机固件多为 **`.zst`**；此处统一放**解压后**文件）。
> 安装：`BUILD.gn` 用 `install_images=["system","ramdisk"]` 装到 `lib/firmware/<same-subdir>`。
> 完整取证/注入/回退见 `out/x86_64_virt/ohos-dbg/ptl_fw/FIRMWARE_MANIFEST.md`
> 与 `out/x86_64_virt/ohos-dbg/fix_sof_fw/SUMMARY.md`。

## 目录内容

```
i915/xe3lpd_dmc.bin                       (Xe DMC)
xe/{ptl_guc_70.bin,ptl_huc.bin,ptl_gsc_1.bin}
iwlwifi-sc-a0-gf-a0-100.ucode             (WiFi)
regulatory.db{,.p7s}
intel/ibt-00a0-0041-{iml.sfi,pci.sfi,pci.ddc}   (BT)
intel/ish/ish_ptl.bin                     (ISH 传感器)
intel/vpu/vpu_50xx_v1.bin                 (NPU)
intel/sof-ipc4/ptl/{sof-ptl.ri, sof-ptl-openmodules.ri}         (SOF IPC4 base + openmodules)
intel/sof-ipc4-lib/**                     (宿主实际内容；仅 lnl/，PTL 无此目录)
intel/sof-ipc4-tplg/*.tplg                (宿主 IPC4 全量拓扑，189 个)
```

## SOF 音频（IPC4）要点

- 本机 SOF 版本：**2.14.1.1**；加载
  `intel/sof-ipc4/ptl/sof-ptl.ri`（intel-signed）+ split-release 库
  `intel/sof-ipc4/ptl/sof-ptl-openmodules.ri`；拓扑
  `intel/sof-ipc4-tplg/sof-hda-generic-4ch.tplg`。
- `sof-ptl-openmodules.ri` 是**必需**：拓扑引用的模块 UUID
  `39656EB2-3B71-4049-8D3F-F92CD5C43C09` 只在该库里；缺它会退化成
  `intel/sof-ipc4-lib/ptl/<uuid>.bin` 的查找并报 `-2`。
- `sof-ipc4-lib/ptl` 不存在（宿主也没有），不是本问题的原因。

## 关键 sha256

| 文件 | sha256 |
|---|---|
| `intel/sof-ipc4/ptl/sof-ptl.ri` | `f485462d17e1b5c5a8d3e2fb8e692a3adb24ce2121805608d3587123be5d1124` |
| `intel/sof-ipc4/ptl/sof-ptl-openmodules.ri` | `43acfa2c4e731e75b4ab3dd2338fa78d90484f6dfbd49d1414902e7eb63fac5b` |
| `intel/sof-ipc4-tplg/sof-hda-generic-4ch.tplg` | `6b3d276a296116f0dc58a167eed38d5eb997b7602bb9b55ae195b5497e2cc942` |

## 校验

```sh
cd device/pc/ptl/firmware
sha256sum $(find intel/sof-ipc4 intel/sof-ipc4-lib intel/sof-ipc4-tplg -type f | sort)
```
