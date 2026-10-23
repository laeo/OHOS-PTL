# device/pc/ptl/hwdec_probe —— Intel oneVPL 硬件视频解码探针（pc_ptl / Intel PTL）

本目录是 **oneVPL 硬解链路的"探针 + init 服务"** 部分：

| 文件 | 说明 |
|---|---|
| `hwdec_probe.c` | 最小探针：读 Annex-B 码流 → oneVPL 解码 → 打印帧数/耗时/格式/是否硬件 |
| `hwdec_probe.sh` | init 服务入口（开机跑一次探针，日志落 `/sys_prod/hwdec_probe.log`） |
| `init.hwdec_probe.cfg` | init 服务定义（`hwdec_probe`，root，`once`） |

配套的 **运行时库**（oneVPL dispatcher / GPU runtime / libva / libdrm / Intel media driver）
与 **H.264 样本** 不在本目录，而是由
`out/x86_64_virt/ohos-dbg/fix_hwdec_probe/inject.sh` 直接注入磁盘镜像
（p2=`/system/...`，p3=`/vendor/lib64/...`）。

## 运行时链路

```
hwdec_probe (本目录)
  └─ libvpl.so.2            oneVPL dispatcher (Apache-2.0)      /vendor/lib64
       └─ libmfx-gen.so.1.2  oneVPL GPU runtime (MIT)            /vendor/lib64
            └─ libva.so.2 / libva-drm.so.2 / libdrm.so.2        /vendor/lib64
                 └─ libdri/iHD_drv_video.so  Intel media driver (MIT)
                      └─ libigdgmm.so.12   gmmlib（直接做 DRM ioctl，含 xe exec queue）
                           └─ kernel xe  (DRM_IOCTL_XE_EXEC / XE_ENGINE_CLASS_VIDEO_DECODE)
```

## 构建（探针本体）

```sh
cd /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/fix_hwdec_probe
bash build_probe.sh          # -> build/hwdec_probe  (OHOS musl x86_64, 解释器 /lib/ld-musl-x86_64.so.1)
```

## 注入（整机）

```sh
bash out/x86_64_virt/ohos-dbg/fix_hwdec_probe/inject.sh <pc_ptl 磁盘镜像>
```

`inject.sh` 会：

1. p2(system)：写入 `/system/bin/hwdec_probe`、`/system/bin/hwdec_probe.sh`、
   `/system/etc/hwdec/sample.h264`(+`sample_min.h264`)；
2. p3(vendor)：写入 oneVPL/libva/libdrm/iHD 运行时与 `/vendor/etc/init.hwdec_probe.cfg`，
   并 patch `/vendor/etc/init.pc_ptl.cfg`：
   * `import` 增加 `"/vendor/etc/init.hwdec_probe.cfg"`（**必须是绝对路径**：
     OHOS init 的 `import` 项会先当参数名解析，再当路径解析，相对路径无效）；
   * `boot` job 末尾追加 `"start hwdec_probe"`（放在 `/dev/dri/*` 的 chmod 之后，
     保证探针启动时 renderD128 权限已放开）。
3. 两个分区各跑一次 `e2fsck -f -y`，逐文件 sha256 自校验，最后 `dd` 回写。

## 真机判据

* `cat /sys_prod/hwdec_probe.log`（若该分区只读则看 `/data/local/tmp/hwdec_probe.log`）
  出现 `HWDEC: RESULT=OK decoded_frames=N` 与 `HWDEC: SUMMARY frames=... fps=... cpu_ratio=...%`
* `hilog -T HWDEC` 能看到同样的 `HWDEC:` 行（注意 hilog 级别过滤会丢掉 `LOG_DEBUG`）
* 失败时探针**始终退出 0**，并在日志里写明原因（`reason=...`），不会 panic。

详细移植过程、QEMU 证据与遗留见
`out/x86_64_virt/ohos-dbg/fix_hwdec_probe/SUMMARY.md`。
