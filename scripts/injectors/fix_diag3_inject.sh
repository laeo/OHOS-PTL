#!/bin/bash
# ============================================================================
# fix_diag3/inject.sh <image> [options]
# ============================================================================
#
# Injects the "one file to read" diagnostic into a pc_ptl disk image
# (GPT layout, p2 = system, p3 = vendor) or into a raw ext4 system image.
#
# WHAT IS INJECTED
# ----------------
#  p2 (/system)
#    /system/bin/ohos-diag                NEW  the collector with the new
#                                            "hwdec" section and the
#                                            VERDICT.txt overview table
#                                            (item | expected | measured |
#                                             PASS/FAIL/SKIP)
#    /system/etc/ohos-diag/fix_manifest.txt NEW  the sha256 of every landed
#                                            fix, now including the oneVPL /
#                                            VA-API / iHD hardware decode
#                                            stack of fix_hwdec_probe
#
#  NOTHING ELSE IS TOUCHED.  The delivered image
#  (partdisk/media/ohos_part_pc_ptl.img) is REFUSED unless --force is given -
#  the user merges the changes serially.
#
# OPTIONS
#   --manifest <file>   use a different fix manifest
#   --no-diag           do not replace /system/bin/ohos-diag
#   --no-manifest       do not touch the fix manifest
#   --force             allow writing to the delivered image
#   -h|--help           this text
#
# The script is idempotent (rm + write of identical content) and verifies
# every file it wrote by comparing the sha256 of the in-image copy.
# ============================================================================
set -u

BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
TASK=$BASE/fix_diag3
W=$TASK/work
ROOT=/home/katax/Public/OHOS

DELIVERED=$BASE/partdisk/media/ohos_part_pc_ptl.img

# ---------------------------------------------------------------- sources
DIAG=$ROOT/base/startup/ohos_diag/ohos-diag

IMG=""
DO_DIAG=1; DO_MANIFEST=1; FORCE=0; MANIFEST=""
while [ $# -gt 0 ]; do
    a=$1; shift
    case "$a" in
        --manifest) MANIFEST=$1; shift ;;
        --no-diag) DO_DIAG=0 ;;
        --no-manifest) DO_MANIFEST=0 ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
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

# the sha256 of a file inside an ext4 image (without extracting it)
img_sha() {
    # img_sha <partition image> <path in image>
    local img=$1 p=$2 tmp="$W/.sha.bin"
    rm -f "$tmp"
    debugfs -R "dump $p $tmp" "$img" >/dev/null 2>&1 || { echo "-"; return; }
    local sz
    sz=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
    if [ "$sz" -lt 1 ]; then echo "-"; return; fi
    sha256sum "$tmp" | cut -d' ' -f1
}

# ------------------------------------------------------- 1. the collector
echo "--- [1] the enhanced ohos-diag (hwdec section + VERDICT.txt table) ---"
WANT_DIAG_SHA=$(sha256sum "$DIAG" | cut -d' ' -f1)
HAVE_DIAG_SHA=$(img_sha "$P2_IMG" /system/bin/ohos-diag)
echo "    source sha256 : $WANT_DIAG_SHA"
echo "    in-image sha256: $HAVE_DIAG_SHA"

# ------------------------------------------------- 2. the fix manifest
echo "--- [2] the fix manifest (regenerated from the image + the working tree) ---"
if [ "$DO_MANIFEST" = 1 ]; then
    if [ -n "$MANIFEST" ]; then
        echo "    using $MANIFEST"
    else
        MANIFEST="$W/fix_manifest.gen.txt"
        bash "$TASK/gen_manifest.sh" "$P2_IMG" "$P3_IMG" "$MANIFEST" > "$W/gen_manifest.log" 2>&1 \
            && echo "    generated $MANIFEST ($(grep -vc '^#' "$MANIFEST") entries)" \
            || { echo "    ERROR: gen_manifest.sh failed (see $W/gen_manifest.log)"; RC=1; }
    fi
else
    MANIFEST=""
fi
HAVE_MAN_SHA="-"
[ -n "$MANIFEST" ] && HAVE_MAN_SHA=$(img_sha "$P2_IMG" /system/etc/ohos-diag/fix_manifest.txt)
WANT_MAN_SHA="-"
[ -n "$MANIFEST" ] && WANT_MAN_SHA=$(sha256sum "$MANIFEST" | cut -d' ' -f1)
echo "    manifest sha256: want $WANT_MAN_SHA / have $HAVE_MAN_SHA"

# ------------------------------------------------- 3. already up to date?
# e2fsck always rewrites the filesystem metadata, so writing the image back
# would change its bytes even when nothing changed.  When every file is
# already exactly what we want, leave the image completely untouched.
NEED_WRITE=0
if [ "$DO_DIAG" = 1 ] && [ "$HAVE_DIAG_SHA" != "$WANT_DIAG_SHA" ]; then
    NEED_WRITE=1
fi
if [ -n "$MANIFEST" ] && [ "$HAVE_MAN_SHA" != "$WANT_MAN_SHA" ]; then
    NEED_WRITE=1
fi

if [ "$NEED_WRITE" = 0 ]; then
    echo
    echo "=== already up to date - the image is NOT touched (byte identical) ==="
    echo "--- sha256 AFTER: $(sha256sum "$IMG" | cut -d' ' -f1)"
    exit 0
fi

if [ "$DO_DIAG" = 1 ]; then
    write_file "$DIAG" /system/bin/ohos-diag || RC=1
else
    echo "    (collector left alone)"
fi

if [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ]; then
    debugfs -w -R "rm /system/etc/ohos-diag" "$P2_IMG" >/dev/null 2>&1 || true
    debugfs -w -R "mkdir /system/etc/ohos-diag" "$P2_IMG" >/dev/null 2>&1
    write_file "$MANIFEST" /system/etc/ohos-diag/fix_manifest.txt || RC=1
else
    echo "    (manifest left alone)"
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
if [ "$DO_DIAG" = 1 ]; then
    verify_file /system/bin/ohos-diag "$DIAG" || RC=1
fi
if [ "$DO_MANIFEST" = 1 ] && [ -f "$MANIFEST" ]; then
    verify_file /system/etc/ohos-diag/fix_manifest.txt "$MANIFEST" || RC=1
fi

echo "--- sha256 AFTER: $(sha256sum "$IMG" | cut -d' ' -f1)"
if [ "$RC" = 0 ]; then
    echo "=== inject OK ==="
else
    echo "=== inject DONE WITH ERRORS (see above) ==="
fi
exit $RC
