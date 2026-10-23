# ohos_diag — 一键诊断包采集器

面向 OpenHarmony PC 镜像（产品 `pc_ptl`）的诊断工具：
一条命令打包系统状态；开机自动跑一次；关机/重启前再跑一次。

| 文件 | 安装到 | 作用 |
|---|---|---|
| `ohos-diag` | `/system/bin/ohos-diag` | 主程序（A..E 分区，可按名字只跑某几段） |
| `zz_diag_boot.sh` | `/system/bin/zz_diag_boot.sh` | init `post-init` 拉起，等 ~240 s 后自动跑一次全量 |
| `zz_diag_shutdown.sh` | `/system/bin/zz_diag_shutdown.sh` | 由 `reboot` job 在 `syncexec` 下调用 |
| `etc/zz_diag.cfg` | `/system/etc/init/zz_diag.cfg` | init 配置 |

## 用法

```sh
ohos-diag                    # 全量 (A..E) -> <OUTDIR>/diag-<ts>.tar.gz
ohos-diag quick              # 快速子集（关机/重启前用）
ohos-diag desktop audio      # 只跑指定段
```

输出目录优先级（**第一个可写的胜出**）：

| 路径 | 生命周期 |
|---|---|
| `/ohoslog` | p6 真实 userdata，断电后仍在（仅 GRUB `DATA=tmpfs` 启动模式下存在） |
| `/sys_prod` | p4 独立 ext4（rw，约 60 MiB 空），**唯一能同时扛住断电与 OHOS 关机**（关机清 `/data`） |
| `/data` | 普通重启保留，关机丢失 |
| `/data/local/tmp` | 易失，仅兜底 |

## 设计约束

- **每一段都单独容错且有硬超时**：挂死的 U 盘 / 卡死的服务不能让工具本身挂住。
- `zz_diag_boot.sh` 里的任何一步都**不得阻塞开机**：先等 `/ohoslog` 真正挂上，再 sleep 到
  ~240 s uptime（让 desktop / audio / bt / ime 栈起完）。
- 调试/测试时可用 `ZZDIAG_DELAY` 环境变量，或往 `/data/local/tmp/zzdiag_delay` /
  `/ohoslog/zzdiag_delay` 写一个数字来改延迟。

## 构建

```sh
./build.sh --product-name pc_ptl --ccache --jobs 8 --keep-ninja-going \
  --gn-args linux_kernel_version='"linux-7.2"' \
  --build-target base/startup/ohos_diag:pc_ohos_diag
```

纯 POSIX shell + init 配置，无编译依赖。

> 权限说明：`zz_diag.cfg` 里的服务以 `u:r:console:s0` 运行。如果产品开启了
> SELinux enforcing，需要为 `/system/bin/ohos-diag` 与两个 `zz_diag_*.sh` 补策略；
> 当前 `pc_ptl` 的 `selinux_adapter_enforce=false`，故无需处理。

## 许可

Apache-2.0，见 `LICENSE`。脚本内文件带 `SPDX-License-Identifier: Apache-2.0` 头。
> `ohos_prebuilt_etc` 的产物在 **镜像打包阶段**（`--build-target images`）才落到
> `system.img`；只构建组件 target 时只会生成 `out/<product>/obj/**` 下的 stamp 与
> `*_install_info.json`。本次验证即如此，属预期。
