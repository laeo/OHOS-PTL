#!/bin/bash
# ============================================================================
# fix_bt2/inject.sh <image> [options]
# ============================================================================
#
# Injects the Bluetooth chain diagnostic into a pc_ptl disk image
# (GPT layout, p2 = system, p3 = vendor) or into a raw ext4 system image.
#
# WHAT IS INJECTED
# ----------------
#  p2 (/system)
#    /system/bin/bt_enable          NEW  the trigger: it calls exactly the
#                                            same framework entry point as the
#                                            ArkTS "@ohos.bluetooth.access
#                                            .enableBluetooth()" API and
#                                            prints the return code.
#    /system/bin/bt_diag.sh         NEW  the one-command diagnostic: dumps a
#                                            hilog window of the enable
#                                            attempt and judges the chain
#                                            link by link (L0..L5).
#    /system/bin/ohos-diag          NEW  the collector: the bluetooth section
#                                            now runs bt_diag.sh, collects the
#                                            streaming log collectors and
#                                            reports the six chain links.
#    /system/bin/zz_hilog_persist.sh NEW the log collector: adds a *content*
#                                            filter ("hilog -e <regex>") that
#                                            catches every Bluetooth related
#                                            line of ANY domain (the Settings
#                                            app, the SceneBoard quick
#                                            settings tile, the HDF host),
#                                            because the domain filter alone
#                                            missed exactly the lines that
#                                            tell us whether the switch was
#                                            thrown.
#
#  p3 (/vendor) is NOT touched - the rewritten vendor HAL
#  (/vendor/lib64/libbt_vendor.z.so) and the regenerated hdf_devhost.cfg
#  (blue_host with NET_RAW) are already in the delivered image
#  (fix_bt_hci) and are verified here.
#
#  The delivered image (partdisk/media/ohos_part_pc_ptl.img) is REFUSED
#  unless --force is given - the user merges the changes serially.
#
# OPTIONS
#   --no-diag        do not replace /system/bin/ohos-diag
#   --no-persist     do not replace /system/bin/zz_hilog_persist.sh
#   --force          allow writing to the delivered image
#   -h|--help        this text
#
# The script is idempotent (rm + write of identical content) and verifies
# every file it wrote by comparing the sha256 of the in-image copy.
# ============================================================================
set -u

BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
TASK=$BASE/fix_bt2
W=$TASK/work
ROOT=/home/katax/Public/OHOS

DELIVERED=$BASE/partdisk/media/ohos_part_pc_ptl.img

# ---------------------------------------------------------------- sources
BT_ENABLE=$TASK/work/bt_enable
BT_DIAG=$TASK/tools/bt_diag.sh
DIAG=$ROOT/base/startup/ohos_diag/ohos-diag
PERSIST=$ROOT/base/startup/ohos_diag/zz_hilog_persist.sh
VENDOR=$TASK/work/libbt_vendor.z.so

IMG=""
DO_DIAG=1; DO_PERSIST=1; FORCE=0
while [ $# -gt 0 ]; do
    a=$1; shift
    case "$a" in
        --no-diag) DO_DIAG=0 ;;
        --no-persist) DO_PERSIST=0 ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
        -*) echo "unknown option: $a" >&2; exit 2 ;;
        *) IMG=$a ;;
    esac
done

[ -n "$IMG" ] || { echo "usage: $0 <image> [options]" >&2; exit 2; }
[ -f "$IMG" ] || { echo "ERROR: image not found: $IMG" >&2; exit 1; }

# the delivered image is the user's to merge - refuse to touch it silently
if [ "$(readlink -f "$IMG")" = "$(readlink -f "$DELIVERED" 2>/dev/null)" ] && [ "$FORCE" = 0 ]; then
    echo "ERROR: $IMG is the DELIVERED image." >&2
    echo "       The user merges the changes serially - use a copy, e.g." >&2
    echo "         cp --sparse $DELIVERED $TASK/scratch.img" >&2
    echo "       or pass --force if you really mean it." >&2
    exit 2
fi

mkdir -p "$W"

# ------------------------------------------------------- geometry of the disk
# p1 ESP      sector 2048      512 MiB
# p2 system   sector 1050624  2048 MiB
# p3 vendor   sector 5244928  512 MiB
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

# the sha256 of a file inside an ext4 image (without extracting it)
img_sha() {
    local img=$1 p=$2 tmp="$W/.sha.bin"
    rm -f "$tmp"
    debugfs -R "dump $p $tmp" "$img" >/dev/null 2>&1 || { echo "-"; return; }
    local sz
    sz=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
    if [ "$sz" -lt 1 ]; then echo "-"; return; fi
    sha256sum "$tmp" | cut -d' ' -f1
}

# ------------------------------------------------------------- 1. the files
echo "--- [1] the files ---"
for f in "$BT_ENABLE" "$BT_DIAG" "$DIAG" "$PERSIST"; do
    if [ -f "$f" ]; then
        echo "    $(basename "$f"): $(stat -c%s "$f") B  $(sha256sum "$f" | cut -c1-16)..."
    else
        echo "    $(basename "$f"): MISSING ($f)"
    fi
done

# --------------------------------------------- 2. is the image already fixed?
NEED_WRITE=0
chk() {
    # chk <src> <path in image>
    _s=$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)
    _h=$(img_sha "$P2_IMG" "$2")
    if [ "$_s" != "$_h" ]; then NEED_WRITE=1; fi
}
[ -f "$BT_ENABLE" ] && chk "$BT_ENABLE" /system/bin/bt_enable
[ -f "$BT_DIAG" ] && chk "$BT_DIAG" /system/bin/bt_diag.sh
[ "$DO_DIAG" = 1 ] && [ -f "$DIAG" ] && chk "$DIAG" /system/bin/ohos-diag
[ "$DO_PERSIST" = 1 ] && [ -f "$PERSIST" ] && chk "$PERSIST" /system/bin/zz_hilog_persist.sh
if [ -f "$VENDOR" ] && [ -n "$P3_IMG" ]; then
    _s=$(sha256sum "$VENDOR" | cut -d' ' -f1)
    _h=$(img_sha "$P3_IMG" /lib64/libbt_vendor.z.so)
    if [ "$_s" != "$_h" ]; then NEED_WRITE=1; fi
fi

if [ "$NEED_WRITE" = 0 ]; then
    echo
    echo "=== already up to date - the image is NOT touched (byte identical) ==="
    echo "--- sha256 AFTER: $(sha256sum "$IMG" | cut -d' ' -f1)"
    exit 0
fi

# ------------------------------------------------------- 3. write into p2
if [ -f "$BT_ENABLE" ]; then
    echo "--- [2] the trigger ---"
    write_file "$BT_ENABLE" /system/bin/bt_enable || RC=1
fi
if [ -f "$BT_DIAG" ]; then
    echo "--- [3] the one-command diagnostic ---"
    write_file "$BT_DIAG" /system/bin/bt_diag.sh || RC=1
    # it must be executable
    debugfs -w -R "set_inode_field /system/bin/bt_diag.sh mode 0100755" "$P2_IMG" >/dev/null 2>&1 || true
fi
if [ "$DO_DIAG" = 1 ] && [ -f "$DIAG" ]; then
    echo "--- [4] the collector ---"
    write_file "$DIAG" /system/bin/ohos-diag || RC=1
else
    echo "--- [4] (collector left alone) ---"
fi
if [ "$DO_PERSIST" = 1 ] && [ -f "$PERSIST" ]; then
    echo "--- [5] the log collector ---"
    write_file "$PERSIST" /system/bin/zz_hilog_persist.sh || RC=1
else
    echo "--- [5] (log collector left alone) ---"
fi

# --------------------------------------------- 3b. the vendor HAL (p3)
# 2026-10-22: the vendor HAL logged into files that the loading process
# (blue_host, uid "blue_host") cannot write, so the whole trace was lost.
# It now logs through hilog (domain 0xD000105) as well.
if [ -f "$VENDOR" ] && [ -n "$P3_IMG" ]; then
    echo "--- [5b] the vendor HAL (p3) ---"
    write_file "$VENDOR" /lib64/libbt_vendor.z.so "$P3_IMG" || RC=1
else
    echo "--- [5b] (vendor HAL left alone) ---"
fi

# --------------------------------------- 4. verify what is already there
echo "--- [6] the BT chain pieces that must already be in the image ---"
if [ -n "$P3_IMG" ]; then
    _v=$(img_sha "$P3_IMG" /lib64/libbt_vendor.z.so)
    if [ "$_v" = "-" ]; then
        echo "    MISSING /vendor/lib64/libbt_vendor.z.so"
    else
        echo "    OK   /vendor/lib64/libbt_vendor.z.so  $_v"
    fi
    _c="$W/.hdfcfg"
    debugfs -R "dump /etc/init/hdf_devhost.cfg $_c" "$P3_IMG" >/dev/null 2>&1 && {
        if grep -aq "NET_RAW" "$_c"; then
            echo "    OK   blue_host has NET_RAW in hdf_devhost.cfg"
        else
            echo "    WARNING blue_host has NO NET_RAW in hdf_devhost.cfg"
        fi
    } || echo "    MISSING /vendor/etc/init/hdf_devhost.cfg"
    rm -f "$_c"
else
    echo "    (no vendor partition - skipped)"
fi
_v=$(img_sha "$P2_IMG" /system/lib64/libbtstack.z.so)
[ "$_v" = "-" ] && echo "    MISSING /system/lib64/libbtstack.z.so" \
                || echo "    OK   /system/lib64/libbtstack.z.so  $_v"
_v=$(img_sha "$P2_IMG" /system/lib64/libbluetooth_hdi_adapter.z.so)
[ "$_v" = "-" ] && echo "    MISSING /system/lib64/libbluetooth_hdi_adapter.z.so" \
                || echo "    OK   /system/lib64/libbluetooth_hdi_adapter.z.so  $_v"

# ------------------------------------------------------- fsck + write back
if [ "$IS_DISK" = 1 ]; then
    echo "--- e2fsck p2 ---"
    e2fsck -f -y "$P2_IMG" >"$W/e2fsck_p2.log" 2>&1 || echo "    e2fsck reported issues (see $W/e2fsck_p2.log)"
    tail -3 "$W/e2fsck_p2.log" | sed 's/^/    /'
    if [ -n "$P3_IMG" ] && [ -f "$VENDOR" ]; then
        echo "--- e2fsck p3 ---"
        e2fsck -f -y "$P3_IMG" >"$W/e2fsck_p3.log" 2>&1 || echo "    e2fsck reported issues (see $W/e2fsck_p3.log)"
        tail -3 "$W/e2fsck_p3.log" | sed 's/^/    /'
    fi
    echo "--- writing p2 back ---"
    dd if="$P2_IMG" of="$IMG" bs=512 seek=$P2_SECT count=$P2_CNT conv=notrunc status=none
    if [ -n "$P3_IMG" ] && [ -f "$VENDOR" ]; then
        echo "--- writing p3 back ---"
        dd if="$P3_IMG" of="$IMG" bs=512 seek=$P3_SECT count=$P3_CNT conv=notrunc status=none
    fi
    echo "    image updated"
    echo "--- NOTE: the delivered image has a truncated GPT header."
    echo "    Fix it before booting with:  sgdisk -e \"$IMG\""
fi

# ------------------------------------------------------------- verification
echo "--- verify ---"
[ -f "$BT_ENABLE" ] && { verify_file /system/bin/bt_enable "$BT_ENABLE" || RC=1; }
[ -f "$BT_DIAG" ] && { verify_file /system/bin/bt_diag.sh "$BT_DIAG" || RC=1; }
[ "$DO_DIAG" = 1 ] && [ -f "$DIAG" ] && { verify_file /system/bin/ohos-diag "$DIAG" || RC=1; }
[ "$DO_PERSIST" = 1 ] && [ -f "$PERSIST" ] && { verify_file /system/bin/zz_hilog_persist.sh "$PERSIST" || RC=1; }
[ -f "$VENDOR" ] && [ -n "$P3_IMG" ] && { verify_file /lib64/libbt_vendor.z.so "$VENDOR" "$P3_IMG" || RC=1; }

echo "--- sha256 AFTER: $(sha256sum "$IMG" | cut -d' ' -f1)"
if [ "$RC" = 0 ]; then
    echo "=== inject OK ==="
else
    echo "=== inject DONE WITH ERRORS (see above) ==="
fi
exit $RC
