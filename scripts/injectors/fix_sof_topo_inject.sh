#!/bin/bash
# inject.sh - fix_sof_topo payload for the pc_ptl real-machine image.
#
#   ./inject.sh <disk-image> [--force]
#
# What it injects (all into p2 = /system):
#   /system/bin/ohos-diag          new audio verdicts + the destructive
#                                  "audiotest" section (kernel vs framework split)
#   /system/bin/zz_audioup.sh      boot-time playback pass: un-mutes the codec,
#                                  raises a zeroed DAC volume and forces the
#                                  SOF DAI mixers (numid 31/32) to their max
#   /system/bin/zz_audioguard.sh   keeps the SOF DAI mixers at their max
#                                  (SOF re-inits them when a stream starts)
#   /system/etc/init/zz_audio.cfg  init job for the above
#   /system/bin/zz_audiotest       v2: adds the "tonehw" sub command
#   /system/lib64/libhidumperservice.z.so
#                                  rebuilt with the "root may dump" patch, so
#                                  `hidumper -s AudioPolicyService` works
#
# The delivered image (partdisk/media/ohos_part_pc_ptl.img) is REFUSED unless
# --force is given - the task explicitly asks for the delivered image to stay
# untouched.
#
# Idempotent in the sense that matters: the *payload* is content identical on
# every run (step 5 reads every file back out of the image and compares it
# byte for byte with the staged copy, and the payload manifest printed at the
# end is stable).  The ext4 image itself is NOT byte identical between runs
# because e2fsck/allocator state changes - do not compare raw partition
# hashes to decide whether the injection worked.
set -euo pipefail

BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
F=$BASE/fix_sof_topo
W=$F/work
TREE=/home/katax/Public/OHOS
DELIVERED=$BASE/partdisk/media/ohos_part_pc_ptl.img

IMG=""
FORCE=0
for a in "$@"; do
    case "$a" in
        --force) FORCE=1 ;;
        *) IMG="$a" ;;
    esac
done
[ -n "$IMG" ] || { echo "usage: $0 <disk-image> [--force]"; exit 2; }
[ -f "$IMG" ] || { echo "no such image: $IMG"; exit 2; }
if [ "$(readlink -f "$IMG")" = "$(readlink -f "$DELIVERED")" ] && [ "$FORCE" -ne 1 ]; then
    echo "REFUSING to touch the delivered image: $IMG"
    echo "copy it first (cp --sparse) and pass the copy, or use --force."
    exit 3
fi

# p2 = /system (2 GiB), p3 = /vendor (512 MiB)
P2_SECT=1050624; P2_CNT=4194304
P3_SECT=5244928; P3_CNT=1048576

mkdir -p "$W" "$F/files"

# ---------------------------------------------------------------- payload ---
cp "$TREE/base/startup/ohos_diag/ohos-diag"        "$F/files/ohos-diag"
cp "$TREE/base/startup/ohos_diag/zz_audioup.sh"    "$F/files/zz_audioup.sh"
cp "$TREE/base/startup/ohos_diag/zz_audioguard.sh" "$F/files/zz_audioguard.sh"
cp "$TREE/base/startup/ohos_diag/etc/zz_audio.cfg" "$F/files/zz_audio.cfg"
cp "$F/src/zz_audiotest"                            "$F/files/zz_audiotest" 2>/dev/null || true
[ -f "$F/files/zz_audiotest" ] || cp "$BASE/fix_alsa_bt_desktop/files/zz_audiotest" "$F/files/zz_audiotest"

rm -rf "$F/stage"; mkdir -p "$F/stage/p2/system/bin" "$F/stage/p2/system/etc/init" "$F/stage/p2/system/lib64"
cp "$F/files/ohos-diag"        "$F/stage/p2/system/bin/ohos-diag"
cp "$F/files/zz_audioup.sh"    "$F/stage/p2/system/bin/zz_audioup.sh"
cp "$F/files/zz_audioguard.sh" "$F/stage/p2/system/bin/zz_audioguard.sh"
cp "$F/files/zz_audio.cfg"     "$F/stage/p2/system/etc/init/zz_audio.cfg"
cp "$F/files/zz_audiotest"     "$F/stage/p2/system/bin/zz_audiotest"
chmod 755 "$F/stage/p2/system/bin/ohos-diag" "$F/stage/p2/system/bin/zz_audioup.sh" \
           "$F/stage/p2/system/bin/zz_audioguard.sh" "$F/stage/p2/system/bin/zz_audiotest"
chmod 644 "$F/stage/p2/system/etc/init/zz_audio.cfg"

# the rebuilt hidumper service (root-may-dump patch)
if [ -f "$F/files/libhidumperservice.z.so" ]; then
    cp "$F/files/libhidumperservice.z.so" "$F/stage/p2/system/lib64/libhidumperservice.z.so"
    chmod 644 "$F/stage/p2/system/lib64/libhidumperservice.z.so"
else
    echo "NOTE: $F/files/libhidumperservice.z.so missing - hidumper stays broken"
fi

# ------------------------------------------------------------------ apply ---
echo "[1/6] extract p2"
dd if="$IMG" of="$W/p2.img" bs=512 skip=$P2_SECT count=$P2_CNT status=none

echo "[2/6] write payload into p2"
python3 "$BASE/fix_alsa_bt_desktop/work/mk_dbgfs.py" --img "$W/p2.img" \
        --root "$F/stage/p2" --tag "" --log "$W/inject_p2.dbgfs"

echo "[3/6] e2fsck p2"
e2fsck -f -y "$W/p2.img" > "$W/e2fsck_p2.log" 2>&1 || true
tail -3 "$W/e2fsck_p2.log"

echo "[4/6] write p2 back"
dd if="$W/p2.img" of="$IMG" bs=512 seek=$P2_SECT count=$P2_CNT conv=notrunc status=none

echo "[5/6] verify (read the files back out of the image)"
fail=0
for f in system/bin/ohos-diag system/bin/zz_audioup.sh system/bin/zz_audioguard.sh \
         system/etc/init/zz_audio.cfg system/bin/zz_audiotest; do
    debugfs -R "dump /$f $W/.verify" "$W/p2.img" >/dev/null 2>&1
    if cmp -s "$W/.verify" "$F/stage/p2/$f"; then
        echo "OK      /$f"
    else
        echo "MISMATCH /$f"; fail=1
    fi
done
if [ -f "$F/stage/p2/system/lib64/libhidumperservice.z.so" ]; then
    debugfs -R "dump /system/lib64/libhidumperservice.z.so $W/.verify" "$W/p2.img" >/dev/null 2>&1
    if cmp -s "$W/.verify" "$F/stage/p2/system/lib64/libhidumperservice.z.so"; then
        echo "OK      /system/lib64/libhidumperservice.z.so"
    else
        echo "MISMATCH /system/lib64/libhidumperservice.z.so"; fail=1
    fi
fi
rm -f "$W/.verify"

echo "[6/6] payload manifest + image sha256"
# payload manifest: stable across runs, this is what proves the injection is
# idempotent (compare it between two runs).
( cd "$F/stage/p2" && find . -type f | sort | while read -r _pf; do
    sha256sum "$_pf" | sed "s| \./|  |"
  done )
# The full disk image is 40+ GiB (sparse), hashing it takes ~10 min.  What
# this script can change is the p2 partition, so that is what is hashed by
# default; FULL_SHA=1 hashes the whole image as well.
sha256sum "$W/p2.img" | sed "s| .*|  p2 (system partition, not stable: ext4 metadata)|"
if [ "${FULL_SHA:-0}" = "1" ]; then
    sha256sum "$IMG"
fi
[ "$fail" -eq 0 ] || { echo "VERIFY FAILED"; exit 1; }
echo "DONE - $IMG"
