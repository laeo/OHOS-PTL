#!/bin/bash
# fix_perf2/inject.sh
#
#   inject.sh <image> [--no-rs] [--no-display] [--no-diag] [--no-cfg] [--no-perf]
#
# Injects the "system-wide sluggishness" fixes into a pc_ptl disk image
# (GPT layout, p2 = system, p3 = vendor, p1 = ESP).
#
# What is injected
# ----------------
#  1. /system/etc/init/console.cfg
#     /system/etc/init/zz_diag.cfg
#         -> ohos.permission.DUMP is now ALSO listed in "permission_acls".
#            Reason: accesstoken_info_manager.cpp:1419 drops a native token
#            permission when native.apl < permission.availableLevel and the
#            permission is not in the native ACLs.  DUMP is system_core, the
#            console token is system_core, so "permission" alone is enough
#            here -- but "permission_acls" is the mechanism that also works
#            for a lower APL, and it is what hdcd.cfg itself uses.
#            => hidumper -s RenderService -a gles|screen|hitchs stops
#               printing "request error".
#
#  2. /system/etc/init/zz_perf.cfg + /system/bin/zz_perf.sh
#        -> new boot service that puts every cpufreq policy into the
#           "performance" policy (EPP=performance, no_turbo=0,
#           min/max_perf_pct=100).  In intel_pstate ACTIVE mode the cpufreq
#           core only offers the two pseudo governors "performance" and
#           "powersave" (cpufreq.c:847), so "performance" is the only
#           way to make the HWP engine ramp up immediately.
#
#  3. /system/lib64/librender_service.z.so
#        -> rebuilt: RS now logs GL_VENDOR / GL_RENDERER / GL_VERSION /
#           EGL_VENDOR / EGL_VERSION once at startup ("GLBackend: ...").
#           Makes the GL backend visible in hilog without needing hidumper
#           (which needs the DUMP permission).
#
#  4. /vendor/lib64/display_composer_vendor.z.so
#    /vendor/lib64/display_buffer_vendor.z.so
#        -> rebuilt display HDI:
#             * the DRM framebuffer of a client buffer is cached and reused
#               instead of being destroyed and recreated on every frame
#               (drmPrimeFDToHandle + drmModeAddFB2 / drmModeRmFB +
#               GEM_CLOSE for a 23.6 MB @3072x1920 buffer, every frame);
#             * the per-frame/per-layer "is not supported" messages of the
#               unimplemented display-buffer / composer entry points are
#               demoted from ERROR to DEBUG (they were ~500 error lines
#               per second).
#
#  5. /system/bin/ohos-diag
#        -> the "perf" section now also measures the display commit rate
#           and the per-frame cost of the display pipeline.
#
# Idempotent: every file is written with the same content, so running the
# script twice yields the same image.
set -eu

BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
TASK=$BASE/fix_perf2
W=$TASK/work
ROOT=/home/katax/Public/OHOS

# --- sources ---------------------------------------------------------------
RS_LIB=$ROOT/out/ptl/graphic/graphic_2d/librender_service.z.so
DISP_COMP=$ROOT/out/ptl/device_x86_64_virt/qemu_virt_full_x86_64/libdisplay_composer_vendor.z.so
DISP_BUF=$ROOT/out/ptl/device_x86_64_virt/qemu_virt_full_x86_64/libdisplay_buffer_vdi_impl.z.so
DIAG=$ROOT/base/startup/ohos_diag/ohos-diag
CONSOLE_CFG=$ROOT/base/startup/init/services/etc/console.cfg
DIAG_CFG=$ROOT/base/startup/ohos_diag/etc/zz_diag.cfg
PERF_CFG=$ROOT/base/startup/ohos_diag/etc/zz_perf.cfg
PERF_SH=$ROOT/base/startup/ohos_diag/zz_perf.sh
VERIFY_SH=$TASK/scripts/verify.sh

IMG=""
DO_RS=1
DO_DISPLAY=1
DO_DIAG=1
DO_CFG=1
DO_PERF=1
for a in "$@"; do
    case "$a" in
        --no-rs) DO_RS=0 ;;
        --no-display) DO_DISPLAY=0 ;;
        --no-diag) DO_DIAG=0 ;;
        --no-cfg) DO_CFG=0 ;;
        --no-perf) DO_PERF=0 ;;
        -*) echo "unknown option: $a" >&2; exit 2 ;;
        *) IMG=$a ;;
    esac
done
[ -n "$IMG" ] || { echo "usage: inject.sh <image> [opts]" >&2; exit 2; }
[ -f "$IMG" ] || { echo "ERROR: image not found: $IMG" >&2; exit 1; }

mkdir -p "$W"

# --- geometry of the pc_ptl disk image -------------------------------------
# p1 ESP  sector 2048      512 MiB
# p2 system sector 1050624  2048 MiB
# p3 vendor sector 5244928 1024 MiB
P1_SECT=2048;      P1_CNT=1048576
P2_SECT=1050624;   P2_CNT=4194304
P3_SECT=5244928;   P3_CNT=2097152

IS_DISK=0
if dd if="$IMG" bs=512 skip=1 count=1 2>/dev/null | grep -aq "EFI PART"; then
    IS_DISK=1
fi

if [ "$IS_DISK" = 1 ]; then
    echo "=== image    : $IMG (GPT disk)"
    P2_IMG="$W/p2.img"; P3_IMG="$W/p3.img"
    [ -f "$P2_IMG" ] || dd if="$IMG" of="$P2_IMG" bs=512 skip=$P2_SECT count=$P2_CNT status=none
    [ -f "$P3_IMG" ] || dd if="$IMG" of="$P3_IMG" bs=512 skip=$P3_SECT count=$P3_CNT status=none
else
    echo "=== image    : $IMG (raw ext4 system image)"
    P2_IMG="$IMG"; P3_IMG=""
fi

# --- helpers ---------------------------------------------------------------
# write_file <src> <path-in-image> [image]
write_file() {
    _src=$1; _dst=$2; _img=${3:-$P2_IMG}
    [ -f "$_src" ] || { echo "    SKIP (missing source: $_src)"; return 0; }
    # debugfs must run in write mode for both the remove and the write, and
    # they have to be separate invocations: a single -R command can only do
    # one operation.
    debugfs -w -R "rm $_dst" "$_img" >/dev/null 2>&1 || true
    if ! debugfs -w -R "write $_src $_dst" "$_img" >/dev/null 2>&1; then
        echo "    ERROR writing $_dst"; return 1
    fi
    echo "    wrote $_dst ($(stat -c%s "$_src") bytes)"
}

verify_file() {
    _dst=$1; _src=$2; _img=${3:-$P2_IMG}
    _tmp="$W/.verify.bin"
    rm -f "$_tmp"
    debugfs -R "dump $_dst $_tmp" "$_img" >/dev/null 2>&1 || { echo "    MISSING $_dst"; return 1; }
    _a=$(sha256sum "$_tmp" | cut -d' ' -f1)
    _b=$(sha256sum "$_src" | cut -d' ' -f1)
    rm -f "$_tmp"
    if [ "$_a" = "$_b" ]; then echo "    OK   $_dst"; else echo "    DIFF $_dst"; return 1; fi
}

# --- 1. init service configs (hidumper permission) -------------------------
echo "--- [1] init cfgs (hidumper DUMP permission) ---"
if [ "$DO_CFG" = 1 ]; then
    write_file "$CONSOLE_CFG" /system/etc/init/console.cfg
    write_file "$DIAG_CFG"   /system/etc/init/zz_diag.cfg
else
    echo "    (skipped)"
fi

# --- 2. zz_perf boot service (cpufreq performance policy) -------------------
echo "--- [2] zz_perf service ---"
if [ "$DO_PERF" = 1 ]; then
    write_file "$PERF_CFG" /system/etc/init/zz_perf.cfg
    write_file "$PERF_SH"  /system/bin/zz_perf.sh
    write_file "$VERIFY_SH" /system/bin/zz_perf2_verify.sh
else
    echo "    (skipped)"
fi

# --- 3. render service (GL backend log) ------------------------------------
echo "--- [3] render service library ---"
if [ "$DO_RS" = 1 ]; then
    write_file "$RS_LIB" /system/lib64/librender_service.z.so
else
    echo "    (skipped)"
fi

# --- 4. display HDI (framebuffer reuse + log demotion) ---------------------
echo "--- [4] display HDI ---"
if [ "$DO_DISPLAY" = 1 ] && [ -n "$P3_IMG" ]; then
    write_file "$DISP_COMP" /lib64/libdisplay_composer_vendor.z.so "$P3_IMG"
    write_file "$DISP_BUF"  /lib64/libdisplay_buffer_vdi_impl.z.so "$P3_IMG"
elif [ "$DO_DISPLAY" = 1 ]; then
    echo "    (no vendor partition in this image, skipped)"
else
    echo "    (skipped)"
fi

# --- 5. ohos-diag ----------------------------------------------------------
echo "--- [5] ohos-diag ---"
if [ "$DO_DIAG" = 1 ]; then
    write_file "$DIAG" /system/bin/ohos-diag
else
    echo "    (skipped)"
fi

# --- fsck + write back -----------------------------------------------------
if [ "$IS_DISK" = 1 ]; then
    echo "--- e2fsck p2 ---"
    e2fsck -f -y "$P2_IMG" >"$W/e2fsck_p2.log" 2>&1 || { echo "    e2fsck reported issues (see $W/e2fsck_p2.log)"; }
    echo "--- e2fsck p3 ---"
    e2fsck -f -y "$P3_IMG" >"$W/e2fsck_p3.log" 2>&1 || { echo "    e2fsck reported issues (see $W/e2fsck_p3.log)"; }
    echo "--- write back ---"
    dd if="$P2_IMG" of="$IMG" bs=512 seek=$P2_SECT count=$P2_CNT conv=notrunc status=none
    dd if="$P3_IMG" of="$IMG" bs=512 seek=$P3_SECT count=$P3_CNT conv=notrunc status=none
    echo "    image updated"
fi

# --- verification ----------------------------------------------------------
echo "--- verify ---"
RC=0
[ "$DO_CFG" = 1 ] && { verify_file /system/etc/init/console.cfg "$CONSOLE_CFG" || RC=1; }
[ "$DO_PERF" = 1 ] && { verify_file /system/etc/init/zz_perf.cfg "$PERF_CFG" || RC=1
                        verify_file /system/bin/zz_perf.sh "$PERF_SH" || RC=1
                        verify_file /system/bin/zz_perf2_verify.sh "$VERIFY_SH" || RC=1; }
[ "$DO_RS" = 1 ] && { verify_file /system/lib64/librender_service.z.so "$RS_LIB" || RC=1; }
[ "$DO_DISPLAY" = 1 ] && [ -n "$P3_IMG" ] && {
    verify_file /lib64/libdisplay_composer_vendor.z.so "$DISP_COMP" "$P3_IMG" || RC=1
    verify_file /lib64/libdisplay_buffer_vdi_impl.z.so "$DISP_BUF" "$P3_IMG" || RC=1; }
[ "$DO_DIAG" = 1 ] && { verify_file /system/bin/ohos-diag "$DIAG" || RC=1; }

if [ "$RC" = 0 ]; then
    echo "=== inject OK ==="
else
    echo "=== inject DONE WITH ERRORS (see above) ==="
fi
exit $RC
