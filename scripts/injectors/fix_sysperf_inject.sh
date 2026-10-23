#!/bin/bash
# fix_sysperf/inject.sh
#
#   inject.sh <image> [--no-rs] [--no-mesa] [--no-diag]
#
# 把"系统级性能取证"的三件东西注入 pc_ptl 磁盘镜像（p2 = system 分区）：
#
#   1. /system/lib64/libEGL.so.1.0.0
#        Mesa 26.2.3 (iris+virgl+softpipe) 的 EGL 库，**只改了 platform_ohos.c**：
#        - 驱动选择过程现在会打 "MESA-OHOS:" 前缀的日志（hilog / stderr / 文件）
#          -> 能确认真机上到底是 iris 还是掉到了 swrast（软件渲染）
#        - swrast 兜底不再静默：会明确打印 "SOFTWARE RENDERING"，
#          并可用 MESA_OHOS_NO_SWRAST_FALLBACK=1 彻底禁用（失败即失败）
#        - 可用 MESA_OHOS_DRIVER=<name> 强制指定 gallium 驱动
#        libgallium / libGLESv1_CM / libGLESv2 / libgbm 字节级未变（sha 一致），
#        所以这里只换 libEGL。
#
#   2. /system/bin/ohos-diag
#        新增 "perf" 段（F_perf.txt）：GL_RENDERER、RS hitchs/screen/fps、
#        CPU 频率与 governor / intel_pstate、loadavg / free / top / 每进程 CPU%、
#        DRM/xe 内核态、MESA-OHOS 日志、RS 每帧日志噪声计数。
#
#   3. /system/lib64/librender_service.z.so
#        RS 两处"每 surface 每帧"的 RS_LOGE 降级为 RS_LOGD：
#          - rs_surface_watermark.cpp   "water mark count is zero"
#          - rs_base_render_util.cpp    "GetSurfaceBufferOpaque:0"
#        （真机上这两条在动画期间能刷到几百行/秒，全是 ERROR 级）
#
# 幂等：每次都是 rm + write 同一份文件，结果一致。
# 不改 GPT、不改镜像大小。
set -eu

BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
TASK=$BASE/fix_sysperf
W=$TASK/work

MESA_EGL=$BASE/mesa_build26/stage-iris/libEGL.so.1.0.0
DIAG=/home/katax/Public/OHOS/base/startup/ohos_diag/ohos-diag
RSLIB=/home/katax/Public/OHOS/out/ptl/graphic/graphic_2d/librender_service.z.so
# hidumper 在这台机器上一直是 "request error"：console / zzdiag 服务的 native token
# 默认 apl=system_basic，而 ohos.permission.DUMP 需要 system_core。
# 给这两个服务加上 apl + permission 后 hidumper 才可用（见 SUMMARY §4）。
CONSOLE_CFG=/home/katax/Public/OHOS/base/startup/init/services/etc/console.cfg
DIAG_CFG=/home/katax/Public/OHOS/base/startup/ohos_diag/etc/zz_diag.cfg

IMG=""
DO_RS=1
DO_MESA=1
DO_DIAG=1
DO_CFG=1
for a in "$@"; do
    case "$a" in
        --no-rs) DO_RS=0 ;;
        --no-mesa) DO_MESA=0 ;;
        --no-diag) DO_DIAG=0 ;;
        --no-cfg) DO_CFG=0 ;;
        -*) echo "unknown option: $a"; exit 2 ;;
        *) IMG=$a ;;
    esac
done
[ -n "$IMG" ] || { echo "usage: inject.sh <image> [--no-rs] [--no-mesa] [--no-diag]"; exit 2; }
[ -f "$IMG" ] || { echo "ERROR: image not found: $IMG"; exit 1; }

mkdir -p "$W"

# --- 判定是"整盘 GPT 镜像"还是"裸 ext4 (system.img)" ------------------------
IS_DISK=0
if dd if="$IMG" bs=512 skip=1 count=1 2>/dev/null | grep -aq "EFI PART"; then
    IS_DISK=1
fi

if [ "$IS_DISK" = 1 ]; then
    P2_OFF_MB=513     # p2 (system) 起始偏移 = 扇区 1050624 * 512 / 1MiB
    P2_LEN_MB=2048    # p2 大小
    TARGET="$W/inject_p2.img"
    echo "=== image    : $IMG (GPT 磁盘，注入 p2/system)"
    echo "--- extracting p2 ..."
    dd if="$IMG" of="$TARGET" bs=1M skip=$P2_OFF_MB count=$P2_LEN_MB status=none
else
    TARGET="$W/inject_p2.img"
    echo "=== image    : $IMG (裸 ext4，直接注入)"
    cp --sparse=always "$IMG" "$TARGET"
fi

echo "--- sha256 of image BEFORE: $(sha256sum "$IMG" | cut -d' ' -f1)"

# --- 组装 debugfs 命令 ------------------------------------------------------
CMD="$W/inject_cmds.dbgfs"
: > "$CMD"

# add_file <源文件> <镜像内路径>
# 先把镜像里的现有内容 dump 出来比 sha256：一致就**跳过**（真正做到字节级幂等，
# 第二次运行不会碰 ext4 的 inode/时间戳 -> 镜像 sha 不变）。
add_file() {
    _src=$1; _dst=$2
    [ -f "$_src" ] || { echo "ERROR: missing source: $_src"; exit 1; }
    _want=$(sha256sum "$_src" | cut -d' ' -f1)
    if debugfs -R "dump $_dst $W/.cur.bin" "$TARGET" >/dev/null 2>&1 && [ -f "$W/.cur.bin" ]; then
        _have=$(sha256sum "$W/.cur.bin" | cut -d' ' -f1)
        rm -f "$W/.cur.bin"
        if [ "$_have" = "$_want" ]; then
            echo "  = $_dst  (already up to date, skipped)"
            return
        fi
        echo "  ~ $_dst  (updating: $(echo "$_have" | cut -c1-16) -> $(echo "$_want" | cut -c1-16))"
    else
        rm -f "$W/.cur.bin"
        echo "  + $_dst  (new file, $(stat -c%s "$_src") B)"
    fi
    echo "rm $_dst"  >> "$CMD"
    echo "write $_src $_dst" >> "$CMD"
}

if [ "$DO_MESA" = 1 ]; then
    echo "--- injecting Mesa EGL (MESA-OHOS diagnostics) ---"
    add_file "$MESA_EGL" /system/lib64/libEGL.so.1.0.0
fi
if [ "$DO_DIAG" = 1 ]; then
    echo "--- injecting ohos-diag (perf section) ---"
    add_file "$DIAG" /system/bin/ohos-diag
fi
if [ "$DO_RS" = 1 ]; then
    echo "--- injecting librender_service.z.so (RS per-frame log fix) ---"
    add_file "$RSLIB" /system/lib64/librender_service.z.so
fi
if [ "$DO_CFG" = 1 ]; then
    echo "--- injecting init cfgs (apl=system_core + ohos.permission.DUMP) ---"
    add_file "$CONSOLE_CFG" /system/etc/init/console.cfg
    add_file "$DIAG_CFG" /system/etc/init/zz_diag.cfg
fi

echo "--- debugfs write ..."
if [ -s "$CMD" ]; then
    debugfs -w -f "$CMD" "$TARGET" 2>&1 | sed 's/^/    /' | grep -vE "^    (rm|write) " | head -20
else
    echo "    (nothing to do - image already up to date)"
fi

echo "--- e2fsck ..."
e2fsck -f -y "$TARGET" > "$W/inject_e2fsck.log" 2>&1 || true
tail -3 "$W/inject_e2fsck.log" | sed 's/^/    /'

# --- 写回 -------------------------------------------------------------------
if [ -s "$CMD" ]; then
    if [ "$IS_DISK" = 1 ]; then
        echo "--- writing p2 back into the disk image ..."
        dd if="$TARGET" of="$IMG" bs=1M seek=$P2_OFF_MB count=$P2_LEN_MB conv=notrunc,fsync status=none
    else
        echo "--- writing the ext4 image back ..."
        cp --sparse=always "$TARGET" "$IMG"
    fi
else
    echo "--- image unchanged, nothing to write back ---"
fi

# --- 校验：把镜像里的文件 dump 出来比对 sha256 -------------------------------
echo "--- verifying ..."
RC=0
verify() {   # $1 = 镜像内路径  $2 = 源文件
    debugfs -R "dump $1 $W/.verify.bin" "$TARGET" >/dev/null 2>&1 || { echo "    MISSING $1"; RC=1; return; }
    _a=$(sha256sum "$W/.verify.bin" | cut -d' ' -f1)
    _b=$(sha256sum "$2" | cut -d' ' -f1)
    if [ "$_a" = "$_b" ]; then
        echo "    OK   $1  sha=$(echo "$_a" | cut -c1-16)"
    else
        echo "    FAIL $1  img=$(echo "$_a" | cut -c1-16) src=$(echo "$_b" | cut -c1-16)"
        RC=1
    fi
    rm -f "$W/.verify.bin"
}
[ "$DO_MESA" = 1 ] && verify /system/lib64/libEGL.so.1.0.0 "$MESA_EGL"
[ "$DO_DIAG" = 1 ] && verify /system/bin/ohos-diag "$DIAG"
[ "$DO_RS" = 1 ]   && verify /system/lib64/librender_service.z.so "$RSLIB"
[ "$DO_CFG" = 1 ]  && { verify /system/etc/init/console.cfg "$CONSOLE_CFG"; verify /system/etc/init/zz_diag.cfg "$DIAG_CFG"; }

rm -f "$W/.verify.bin"
echo "--- sha256 of image AFTER : $(sha256sum "$IMG" | cut -d' ' -f1)"
if [ "$RC" = 0 ]; then
    echo "=== OK: fix_sysperf artifacts injected into $IMG"
else
    echo "=== ERROR: verification failed"
    exit 1
fi
