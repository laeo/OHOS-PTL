# terminal — OpenHarmony PC 终端（ArkUI 前端 + 真 PTY 守护）

面向 OpenHarmony PC 镜像（产品 `pc_ptl`，x86_64，2in1）的终端应用。
由两部分组成：

| 目录 | 内容 | 产物 |
|---|---|---|
| `hap/` | ArkTS（Stage 模型）前端工程，bundle `com.ohos.terminal` | `Terminal.hap` |
| `daemon/` | C 守护进程 `ohosptyd`（安装为 `/system/bin/ohosshd`）与 `sudoh`（安装为 `/system/bin/sudo`） | 静态 ELF |
| `init/ohosshd.cfg` | init 服务配置（默认 `disabled: 1`，按需 `start ohosshd`） | `/system/etc/init/ohosshd.cfg` |
| `tools/` | hvigor 工具链环境与构建/签名脚本 | — |

## 架构

ArkUI 侧**不使用 ArkWeb**（该镜像的 x86_64 ArkWeb 引擎的 `RosenWeb` surface 拿不到
buffer，表现为纯白页）。前端是自写的 VT100/xterm 子集解析器 + Canvas 网格渲染
（`hap/entry/src/main/ets/model/terminal.ets`），键盘输入通过 `TextInput` 逐键喂给守护。

后端 `ohosptyd` 是特权 broker：由 init 以 `u:r:su:s0` 拉起，监听 `127.0.0.1:7788`，
为每个连接 **真 PTY**（`posix_openpt` + `setsid` + `TIOCSCTTY` + `dup2`）并在
**session 级 chroot 沙箱**里 exec 交互式登录 shell：

```
unshare(CLONE_NEWNS | CLONE_NEWUTS) + 私有挂载传播
  tmpfs  /tmp /run /dev/shm
  bind   /dev /proc /sys
  bind ro /system /vendor /chip_prod /sys_prod      ← 让 param/bm/aa/hidumper 仍可用
  bind rw <HMDFS 用户共享> -> /mnt/share/{Download,Documents,...}
  chroot /data/alpine ; setgid/setuid(1000) ; exec /bin/zsh
```

要点与理由：

- 会话用户态是 **Alpine 自带的 musl + libc**，`apk / git / curl / zsh` 全部原生可用
  （早期「Alpine overlay 盖在 OHOS 根上」的方案会漏进 OHOS 精简 musl 与被剥掉 setuid 的
  `LD_LIBRARY_PATH`，已废弃）。
- `/data` **不整体 bind**，Alpine 的 apk key / ssh key / 配置对 OHOS 应用不可见；
  非 root 唯一可达的 OHOS 数据是 `/mnt/share`。
- 会话对挂载命名空间的全部改动随连接关闭一起消失（关掉终端标签页即umount 整个沙箱）。
- `/usr/local/ohos-bin` 里的 OHOS CLI 启动器放在 **PATH 尾部**：Alpine 自己的程序优先，
  `apk add nodejs / python3 / git / vim …` 无需维护白名单即自动生效。启动器会判别
  ELF 与 shebang 脚本两类目标（OHOS 的 `/system/bin/node` 是脚本，不是 ELF）。
- `sudoh` 是无密码 setuid-root sudo。`/data` 以 `nosuid` 挂载，所以它必须放在未标 nosuid 的
  只读系统分区上，内核才会认 setuid 位。

## 构建

### 1. 守护进程与 init 配置（走标准 `./build.sh`）

```sh
./build.sh --product-name pc_ptl --ccache --jobs 8 --keep-ninja-going \
  --gn-args linux_kernel_version='"linux-7.2"' \
  --build-target applications/standard/terminal:pc_terminal
```

安装目标：

```
/system/bin/ohosshd      (ohosptyd，静态)
/system/bin/sudo         (sudoh，静态，04755)
/system/etc/init/ohosshd.cfg
```

### 2. ArkTS HAP（hvigor 独立构建）

HAP 由 DevEco CLI 的 `hvigorw` 构建，**不由 `./build.sh` 驱动**（OpenHarmony 顶层
builder 无法为这类应用模块驱动 hvigor）。

```sh
cd applications/standard/terminal
bash tools/build_hap.sh      # → hap/entry/build/default/outputs/default/entry-default-unsigned.hap
bash tools/sign_hap.sh       # → terminal-signed.hap（系统应用 profile 签名）
```

需要的工具链：DevEco CLI `hvigorw` 6.26.4、node v18.20.1、JBR 17、ohpm 26.x、
`prebuilts/ohos-sdk/linux/26.0.0`。路径全部可用环境变量覆盖
（`NODE_HOME` / `JAVA_HOME` / `DEVECO_CLI_HOME` / `DEVECO_SDK_HOME`），见 `tools/env.sh`。
签名材料（keystore / profile / 证书链）**不入库**，放在 `signing/`（已被 `.gitignore` 排除）。

### 3. 把 HAP 装进镜像

HAP 放在 `/system/app/Terminal/Terminal.hap`，并在
`vendor/ohemu/virt/preinstall-config/install_list.json` 增加条目：

```json
{ "app_dir": "/system/app/Terminal", "removable": true }
```

> 注意：`/system/app` 下必须是**已签名**的 HAP；未签名 HAP 会让预装代码签名校验
> （`EnforceCodeSignForAppWithPluginId`）失败。

## 依赖

- OpenHarmony 7.0（API 26）、kernel 7.2、x86_64
- 会话用户态：设备上的 Alpine rootfs（`/data/alpine`）
- 无 ArkWeb、无 Web 依赖

## 许可

Apache-2.0，见 `LICENSE`。源码内文件带 `SPDX-License-Identifier: Apache-2.0` 头。
### 关于链接方式

`daemon/BUILD.gn` 用 OHOS 工具链编成 **musl 动态库**链接的 PIE 可执行文件
（本树 musl 只提供 `libc.so`，无法 `-static` 链接）。守护进程本身跑在 OHOS 根文件系统里，
只有会话子进程才 `chroot` 到 Alpine —— 那条路径由 `chroot()` 之后的内核 `execve`
解释 Alpine 自己的 ELF interpreter，与守护进程的链接方式无关。

历史产物 `out/x86_64_virt/ohos-dbg/fix_term5/daemon/ohosptyd` 是用宿主
`gcc -static`（glibc 静态）编的，**行为等价**，但不是树内可复现的构建；如需与旧产物
逐字节一致，请继续用 `gcc -static -O2 -o ohosptyd ohosptyd.c`。
