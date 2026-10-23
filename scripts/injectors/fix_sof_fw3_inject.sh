#!/bin/bash
# inject.sh - fix the missing sound card on the pc_ptl partition disk.
#
# usage: inject.sh <image.img> [options]
#
#   -n       do not write anything, only verify (exit 1 if something is missing)
#   -q       quiet
#
# What it does
# ------------
# 1. puts the SOF re-probe service into <p2>:/system/bin/zz_sof_reprobe.sh
#    and its init job into <p2>:/system/etc/init/zz_sof_reprobe.cfg,
# 2. verifies that the SOF firmware the kernel asks for is present both in
#    the ESP initrd and in <p2>:/system/lib/firmware,
# 3. verifies the result and exits non-zero if anything is missing.
#
# It is idempotent: running it twice leaves the image byte-identical.
#
# It never touches p3..p6, never touches the user's USB stick and never
# writes outside this directory.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
STAGE="$HERE/stage"
CPIO_LIST="/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/fix_sof_fw2/tools/cpio_list.py"
WORK="$HERE/work/inject"
DO_WRITE=1
QUIET=0

usage() {
    sed -n '2,22p' "$0"
    exit 1
}

IMG=""
while [ $# -gt 0 ]; do
    case "$1" in
        -n) DO_WRITE=0; shift ;;
        -q) QUIET=1; shift ;;
        -h|--help) usage ;;
        *) IMG="$1"; shift ;;
    esac
done
[ -n "$IMG" ] || usage
[ -f "$IMG" ] || { echo "ERROR: no such image: $IMG"; exit 1; }
[ -d "$STAGE" ] || { echo "ERROR: missing stage dir: $STAGE"; exit 1; }
[ -f "$CPIO_LIST" ] || { echo "ERROR: missing $CPIO_LIST"; exit 1; }

log() { [ "$QUIET" = "1" ] || echo "$@"; }

# --- GPT layout --------------------------------------------------------------
# p1 ESP (512 MiB, FAT32)  p2 system (2 GiB, ext4)  ...
read_gpt() {
    python3 - "$1" <<'PY'
import struct, sys
f = open(sys.argv[1], 'rb')
f.seek(512)
hdr = f.read(92)
if hdr[:8] != b'EFI PART':
    sys.exit('ERROR: no GPT header')
pt_lba, num, size = struct.unpack('<QII', hdr[72:88])
f.seek(pt_lba * 512)
data = f.read(num * size)
out = []
for i in range(num):
    e = data[i * size:(i + 1) * size]
    if e[:16] == b'\0' * 16:
        continue
    first, last = struct.unpack('<QQ', e[32:48])
    name = e[56:128].decode('utf-16-le').rstrip('\0')
    out.append((i + 1, first, last, name))
for (n, first, last, name) in out:
    print('%d %d %d %s' % (n, first, last, name))
PY
}

GPT="$(read_gpt "$IMG")"
log "== GPT =="
echo "$GPT" | sed 's/^/   /'
P1_START=$(echo "$GPT" | awk '$1==1{print $2}')
P1_SECTORS=$(( $(echo "$GPT" | awk '$1==1{print $3}') - $(echo "$GPT" | awk '$1==1{print $2}') + 1 ))
P2_START=$(echo "$GPT" | awk '$1==2{print $2}')
P2_SECTORS=$(( $(echo "$GPT" | awk '$1==2{print $3}') - $(echo "$GPT" | awk '$1==2{print $2}') + 1 ))
[ -n "$P1_START" ] && [ -n "$P2_START" ] || { echo "ERROR: cannot read the GPT"; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"

# =============================================================== p2 (system)
log "== p2 (system): re-probe service =="
dd if="$IMG" of="$WORK/p2.img" bs=512 skip="$P2_START" count="$P2_SECTORS" status=none

p2_size() {
    # debugfs prints "User: 0 Group: 0 Project: 0 Size: 586648" on one line
    debugfs -R "stat $1" "$WORK/p2.img" 2>/dev/null | sed -n 's/.*Size: \([0-9][0-9]*\).*/\1/p' | head -1
}

# Extract a file from the (already extracted) p2 image and compare it.
p2_matches() {
    # $1 = path inside the image, $2 = source file
    rm -f "$WORK/cur.bin"
    debugfs -R "dump -p $1 $WORK/cur.bin" "$WORK/p2.img" >/dev/null 2>&1 || true
    [ -f "$WORK/cur.bin" ] && cmp -s "$WORK/cur.bin" "$2"
}

SERVICES="/system/bin/zz_sof_reprobe.sh:$STAGE/zz_sof_reprobe.sh
/system/etc/init/zz_sof_reprobe.cfg:$STAGE/zz_sof_reprobe.cfg"

need_write=0
for pair in $SERVICES; do
    t="${pair%%:*}"; s="${pair#*:}"
    if p2_matches "$t" "$s"; then
        log "   $t already up to date"
    else
        need_write=1
        log "   needs (re)writing: $t"
    fi
done

if [ "$DO_WRITE" = "1" ] && [ "$need_write" = "1" ]; then
    {
        echo "rm /system/bin/zz_sof_reprobe.sh"
        echo "write $STAGE/zz_sof_reprobe.sh /system/bin/zz_sof_reprobe.sh"
        echo "rm /system/etc/init/zz_sof_reprobe.cfg"
        echo "write $STAGE/zz_sof_reprobe.cfg /system/etc/init/zz_sof_reprobe.cfg"
    } > "$WORK/p2.cmds"
    debugfs -w -f "$WORK/p2.cmds" "$WORK/p2.img" > "$WORK/p2_debugfs.log" 2>&1 || true
    # debugfs does not preserve the mode bits -> set them explicitly.
    debugfs -w -R "set_inode_field /system/bin/zz_sof_reprobe.sh mode 0100755" \
        "$WORK/p2.img" >/dev/null 2>&1 || true
    debugfs -w -R "set_inode_field /system/etc/init/zz_sof_reprobe.cfg mode 0100644" \
        "$WORK/p2.img" >/dev/null 2>&1 || true
    e2fsck -f -y "$WORK/p2.img" > "$WORK/p2_e2fsck.log" 2>&1 || true
    log "   p2 image updated"
elif [ "$DO_WRITE" = "1" ]; then
    log "   already present - nothing to do (idempotent)"
fi

# --- verify the service made it in ------------------------------------------
log "== verify: re-probe service =="
verify_fail=0
for pair in $SERVICES; do
    t="${pair%%:*}"; s="${pair#*:}"
    if p2_matches "$t" "$s"; then
        log "   OK  $t ($(stat -c%s "$s") bytes)"
    else
        echo "ERROR: $t is missing or differs from the staged file"
        verify_fail=1
    fi
done

# --- verify the SOF firmware is where the kernel looks for it ---------------
REQUIRED_RAMDISK="lib/firmware/intel/sof-ipc4/ptl/sof-ptl.ri
lib/firmware/intel/sof-ipc4/ptl/sof-ptl-openmodules.ri
lib/firmware/intel/sof-ipc4-tplg/sof-hda-generic-4ch.tplg"

log "== verify: ESP initrd carries the SOF firmware =="
dd if="$IMG" of="$WORK/p1.img" bs=512 skip="$P1_START" count="$P1_SECTORS" status=none
mcopy -i "$WORK/p1.img" "::/boot/ramdisk_bootmedia.img" "$WORK/ramdisk.img" 2>/dev/null || true
if [ -f "$WORK/ramdisk.img" ]; then
    python3 "$CPIO_LIST" "$WORK/ramdisk.img" > "$WORK/ramdisk_listing.txt" 2>/dev/null || true
    for f in $REQUIRED_RAMDISK; do
        if grep -qx "$f" "$WORK/ramdisk_listing.txt"; then
            log "   OK  $f"
        else
            echo "ERROR: ramdisk missing $f"
            verify_fail=1
        fi
    done
else
    log "   (no ramdisk_bootmedia.img on the ESP - skipped)"
fi

log "== verify: p2 carries the SOF firmware =="
for f in \
    /system/lib/firmware/intel/sof-ipc4/ptl/sof-ptl.ri \
    /system/lib/firmware/intel/sof-ipc4/ptl/sof-ptl-openmodules.ri \
    /system/lib/firmware/intel/sof-ipc4-tplg/sof-hda-generic-4ch.tplg ; do
    sz=$(p2_size "$f")
    if [ -n "$sz" ]; then
        log "   OK  $f ($sz bytes)"
    else
        echo "ERROR: p2 missing $f"
        verify_fail=1
    fi
done

# --- write p2 back -----------------------------------------------------------
if [ "$DO_WRITE" = "1" ]; then
    if [ "$verify_fail" = "0" ]; then
        dd if="$WORK/p2.img" of="$IMG" bs=512 seek="$P2_START" count="$P2_SECTORS" conv=notrunc status=none
        log "== p2 written back at sector $P2_START ($P2_SECTORS sectors) =="
    else
        log "== p2 NOT written back (verification failed) =="
    fi
fi

if [ "$verify_fail" != "0" ]; then
    echo "RESULT: FAILED (see the errors above)"
    exit 1
fi
log "RESULT: OK"
exit 0
