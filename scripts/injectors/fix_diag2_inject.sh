#!/bin/bash
# ============================================================================
# fix_diag2/inject.sh <image> [options]
# ============================================================================
#
# Injects the "one-shot evidence" diagnostic into a pc_ptl disk image
# (GPT layout, p2 = system, p3 = vendor) or into a raw ext4 system image.
#
# WHAT IS INJECTED
# ----------------
#  p2 (/system)
#    /system/bin/zz_dmesg_boot.sh        NEW  early full kernel ring buffer dump
#    /system/etc/init/zz_dmesg_boot.cfg NEW  its init service (start-mode=boot)
#    /system/bin/zz_hilog_persist.sh     NEW  BT hilog domains -> DEBUG + on disk
#    /system/etc/init/zz_hilog_persist.cfg NEW its init service
#    /system/bin/ohos-diag               NEW  enhanced collector
#                                            (bootlog/fixes/wifi/media sections
#                                             + a PASS/FAIL VERDICT)
#    /system/bin/wifi_perf_probe.sh      NEW  the segmented Wi-Fi speed probe
#    /system/etc/ohos-diag/fix_manifest.txt NEW  sha256 of every landed fix
#
#  NOTHING ELSE IS TOUCHED.  The delivered image
#  (partdisk/media/ohos_part_pc_ptl.img) is NOT modified by this script - the
#  user merges the changes serially.
#
# OPTIONS
#   --manifest <file>   use a different fix manifest
#   --no-diag           do not replace /system/bin/ohos-diag
#   --no-dmesg          do not install the zz_dmesg_boot service
#   --no-hilog          do not install the zz_hilog_persist service
#   --no-wifiprobe      do not install wifi_perf_probe.sh
#   --regen-manifest    regenerate the manifest from the *target* image
#                       (WARNING: this makes the check circular - only use it
#                        when you deliberately want a self-describing manifest)
#
# The script is idempotent (rm + write of identical content) and verifies
# every file it wrote by comparing the sha256 of the in-image copy.
# ============================================================================
set -u

BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
TASK=$BASE/fix_diag2
W=$TASK/work
ROOT=/home/katax/Public/OHOS

# ---------------------------------------------------------------- sources
DIAG=$ROOT/base/startup/ohos_diag/ohos-diag
DMESG_SH=$ROOT/base/startup/ohos_diag/zz_dmesg_boot.sh
DMESG_CFG=$ROOT/base/startup/ohos_diag/etc/zz_dmesg_boot.cfg
HILOG_SH=$ROOT/base/startup/ohos_diag/zz_hilog_persist.sh
HILOG_CFG=$ROOT/base/startup/ohos_diag/etc/zz_hilog_persist.cfg
WIFIPROBE_SH=$BASE/fix_net_perf/scripts/wifi_perf_probe.sh
MANIFEST=$TASK/fix_manifest.ref.txt

IMG=""
DO_DIAG=1; DO_DMESG=1; DO_HILOG=1; DO_WIFI=1; REGEN=0
while [ $# -gt 0 ]; do
    a=$1; shift
    case "$a" in
        --manifest) MANIFEST=$1; shift ;;
        --no-diag) DO_DIAG=0 ;;
        --no-dmesg) DO_DMESG=0 ;;
        --no-hilog) DO_HILOG=0 ;;
        --no-wifiprobe) DO_WIFI=0 ;;
        --regen-manifest) REGEN=1 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        -*) echo "unknown option: $a" >&2; exit 2 ;;
        *) IMG=$a ;;
    esac
done

[ -n "$IMG" ] || { echo "usage: $0 <image> [options]" >&2; exit 2; }
[ -f "$IMG" ] || { echo "ERROR: image not found: $IMG" >&2; exit 1; }

mkdir -p "$W"

# ------------------------------------------------------- geometry of the disk
# p1 ESP      sector 2048      512 MiB
# p2 system   sector 1050624  2048 MiB
# p3 vendor   sector 5244928  512 MiB
# p4 sys_prod sector 6293504  64 MiB
# p5 chip_prod sector 6424576 64 MiB
# p6 userdata sector 6555648 16 GiB
P2_SECT=1050624;  P2_CNT=4194304
P3_SECT=5244928;  P3_CNT=1048576

IS_DISK=0
if dd if="$IMG" bs=512 skip=1 count=1 2>/dev/null | grep -aq "EFI PART"; then
    IS_DISK=1
fi

if [ "$IS_DISK" = 1 ]; then
    echo "=== image    : $IMG (GPT disk)"
    P2_IMG="$W/inject_p2.img"; P3_IMG="$W/inject_p3.img"
    dd if="$IMG" of="$P2_IMG" bs=512 skip=$P2_SECT count=$P2_CNT status=none
    dd if="$IMG" of="$P3_IMG" bs=512 skip=$P3_SECT count=$P3_CNT status=none
else
    echo "=== image    : $IMG (raw ext4 system image)"
    P2_IMG="$IMG"; P3_IMG=""
fi

# ------------------------------------------------------------------ helpers
write_file() {
    # write_file <src> <path-in-image> [partition image]
    _src=$1; _dst=$2; _img=${3:-$P2_IMG}
    [ -f "$_src" ] || { echo "    SKIP (missing source: $_src)"; return 0; }
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
    debugfs -R "dump $_dst $_tmp" "$_img" >/dev/null 2>&1 || {
        echo "    MISSING $_dst"; return 1; }
    _a=$(sha256sum "$_tmp" | cut -d' ' -f1)
    _b=$(sha256sum "$_src" | cut -d' ' -f1)
    rm -f "$_tmp"
    if [ "$_a" = "$_b" ]; then echo "    OK   $_dst"; else
        echo "    DIFF $_dst (in-image $_a != source $_b)"; return 1; fi
}

RC=0

# ------------------------------------------------------- 1. the init services
echo "--- [1] zz_dmesg_boot: early full kernel ring buffer ---"
if [ "$DO_DMESG" = 1 ]; then
    write_file "$DMESG_SH"  /system/bin/zz_dmesg_boot.sh  || RC=1
    write_file "$DMESG_CFG" /system/etc/init/zz_dmesg_boot.cfg || RC=1
else
    echo "    (skipped)"
fi

echo "--- [2] zz_hilog_persist: bluetooth hilog domains -> DEBUG + on disk ---"
if [ "$DO_HILOG" = 1 ]; then
    write_file "$HILOG_SH"  /system/bin/zz_hilog_persist.sh  || RC=1
    write_file "$HILOG_CFG" /system/etc/init/zz_hilog_persist.cfg || RC=1
else
    echo "    (skipped)"
fi

echo "--- [3] the enhanced ohos-diag ---"
if [ "$DO_DIAG" = 1 ]; then
    write_file "$DIAG" /system/bin/ohos-diag || RC=1
else
    echo "    (skipped)"
fi

echo "--- [4] the segmented Wi-Fi speed probe ---"
if [ "$DO_WIFI" = 1 ]; then
    write_file "$WIFIPROBE_SH" /system/bin/wifi_perf_probe.sh || RC=1
else
    echo "    (skipped)"
fi

# ------------------------------------------------- 5. the fix manifest
echo "--- [5] the fix manifest ---"
if [ "$REGEN" = 1 ]; then
    echo "    regenerating from the TARGET image (self-describing, not a check!)"
    bash "$TASK/gen_manifest.sh" "$P2_IMG" "$P3_IMG" "$W/fix_manifest.gen.txt" >/dev/null 2>&1
    MANIFEST="$W/fix_manifest.gen.txt"
fi
if [ -f "$MANIFEST" ]; then
    debugfs -w -R "rm /system/etc/ohos-diag" "$P2_IMG" >/dev/null 2>&1 || true
    debugfs -w -R "mkdir /system/etc/ohos-diag" "$P2_IMG" >/dev/null 2>&1
    write_file "$MANIFEST" /system/etc/ohos-diag/fix_manifest.txt || RC=1
else
    echo "    ERROR: manifest not found: $MANIFEST"; RC=1
fi

# ------------------------------------------------------- fsck + write back
if [ "$IS_DISK" = 1 ]; then
    echo "--- e2fsck p2 ---"
    e2fsck -f -y "$P2_IMG" >"$W/e2fsck_p2.log" 2>&1 || echo "    e2fsck reported issues (see $W/e2fsck_p2.log)"
    tail -3 "$W/e2fsck_p2.log" | sed 's/^/    /'
    echo "--- writing p2 back ---"
    dd if="$P2_IMG" of="$IMG" bs=512 seek=$P2_SECT count=$P2_CNT conv=notrunc status=none
    echo "    image updated"
    echo "--- NOTE: the delivered image has a truncated GPT header."
    echo "    Fix it before booting with:  sgdisk -e \"$IMG\""
fi

# ------------------------------------------------------------- verification
echo "--- verify ---"
if [ "$DO_DMESG" = 1 ]; then
    verify_file /system/bin/zz_dmesg_boot.sh  "$DMESG_SH"  || RC=1
    verify_file /system/etc/init/zz_dmesg_boot.cfg "$DMESG_CFG" || RC=1
fi
if [ "$DO_HILOG" = 1 ]; then
    verify_file /system/bin/zz_hilog_persist.sh  "$HILOG_SH"  || RC=1
    verify_file /system/etc/init/zz_hilog_persist.cfg "$HILOG_CFG" || RC=1
fi
if [ "$DO_DIAG" = 1 ]; then
    verify_file /system/bin/ohos-diag "$DIAG" || RC=1
fi
if [ "$DO_WIFI" = 1 ]; then
    verify_file /system/bin/wifi_perf_probe.sh "$WIFIPROBE_SH" || RC=1
fi
verify_file /system/etc/ohos-diag/fix_manifest.txt "$MANIFEST" || RC=1

echo "--- sha256 AFTER: $(sha256sum "$IMG" | cut -d' ' -f1)"
if [ "$RC" = 0 ]; then
    echo "=== inject OK ==="
else
    echo "=== inject DONE WITH ERRORS (see above) ==="
fi
exit $RC
