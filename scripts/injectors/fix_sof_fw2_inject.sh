#!/bin/bash
# inject.sh - put the SOF / IPC4 firmware where the in-tree kernel looks for
#             it, on an already built pc_ptl partition disk.
#
# usage: inject.sh <image.img> [options]
#
#   -f DIR   firmware source directory
#            (default: <repo>/device/pc/ptl/firmware)
#   -n       do not write anything, only verify (exit 1 if something is missing)
#   -q       quiet
#
# What it does
# ------------
# The SOF IPC4 driver of this kernel (linux-7.2) asks the firmware loader for
#
#   intel/sof-ipc4/ptl/sof-ptl.ri                 (pci-ptl.c:42 + :51)
#   intel/sof-ipc4/ptl/sof-ptl-openmodules.ri     (ipc4-loader.c:296)
#   intel/sof-ipc4-tplg/<topology>.tplg          (pci-ptl.c:48)
#
# and the loader only searches
#
#   firmware_class.path (= /system/lib/firmware, from the kernel cmdline)
#   /lib/firmware                                 (firmware_loader/main.c:471-478)
#
# The SOF PCI driver is *built in* (CONFIG_SND_SOC_SOF_INTEL_PTL=y) and probes
# during the initcall phase, i.e. before /system is mounted -> the only place
# the firmware can come from at that moment is the initrd (the ESP ramdisk).
# Therefore the ramdisk MUST carry
#
#   lib/firmware/intel/sof-ipc4/ptl/sof-ptl.ri
#   lib/firmware/intel/sof-ipc4/ptl/sof-ptl-openmodules.ri
#   lib/firmware/intel/sof-ipc4-tplg/*.tplg
#
# (note the `intel/` prefix - it is part of the path the kernel asks for).
#
# This script
#   1. rewrites <ESP>:/boot/ramdisk_bootmedia.img so that it contains the
#      firmware tree (idempotent: the file list of the result is identical no
#      matter how often you run it),
#   2. makes sure <p2>:/system/lib/firmware/intel/... has the same files
#      (that is where the loader finds them once /system is mounted, and where
#      a future "driver as module" setup would look),
#   3. verifies both and exits non-zero if anything is missing.
#
# It never touches p3..p6, never touches the user's USB stick and never
# writes outside this directory.
set -e

ROOT=/home/katax/Public/OHOS
HERE="$(cd "$(dirname "$0")" && pwd)"
FW_DIR="${FW_DIR:-$ROOT/device/pc/ptl/firmware}"
CPIO_LIST="$HERE/tools/cpio_list.py"
REPACK="$HERE/tools/ramdisk_repack.py"
WORK="$HERE/work/inject"
DO_WRITE=1
QUIET=0

usage() {
    sed -n '2,40p' "$0"
    exit 1
}

IMG=""
while [ $# -gt 0 ]; do
    case "$1" in
        -f) FW_DIR="$2"; shift 2 ;;
        -n) DO_WRITE=0; shift ;;
        -q) QUIET=1; shift ;;
        -h|--help) usage ;;
        *) IMG="$1"; shift ;;
    esac
done
[ -n "$IMG" ] || usage
[ -f "$IMG" ] || { echo "ERROR: no such image: $IMG"; exit 1; }
[ -d "$FW_DIR" ] || { echo "ERROR: no such firmware dir: $FW_DIR"; exit 1; }
[ -f "$CPIO_LIST" ] || { echo "ERROR: missing $CPIO_LIST"; exit 1; }
[ -f "$REPACK" ] || { echo "ERROR: missing $REPACK"; exit 1; }

log() { [ "$QUIET" = "1" ] || echo "$@"; }

# --- the files the kernel really asks for -------------------------------------
REQUIRED="lib/firmware/intel/sof-ipc4/ptl/sof-ptl.ri
lib/firmware/intel/sof-ipc4/ptl/sof-ptl-openmodules.ri
lib/firmware/intel/sof-ipc4-tplg/sof-hda-generic-4ch.tplg
lib/firmware/intel/sof-ipc4-tplg/sof-ptl-rt722-l0-rt1320-l23.tplg"
MIN_TPLG=10

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

# =============================================================== ESP ramdisk
log "== p1 (ESP): ramdisk =="
dd if="$IMG" of="$WORK/p1.img" bs=512 skip="$P1_START" count="$P1_SECTORS" status=none
mcopy -i "$WORK/p1.img" "::/boot/ramdisk_bootmedia.img" "$WORK/ramdisk_in.img"
log "   ramdisk in : $(stat -c%s "$WORK/ramdisk_in.img") bytes"

python3 "$REPACK" --in "$WORK/ramdisk_in.img" --out "$WORK/ramdisk_out.img" \
    --fw-dir "$FW_DIR" | sed 's/^/   /'

python3 "$CPIO_LIST" "$WORK/ramdisk_out.img" > "$WORK/ramdisk_listing.txt" 2>/dev/null
missing=0
for f in $REQUIRED; do
    grep -qx "$f" "$WORK/ramdisk_listing.txt" || { echo "ERROR: ramdisk missing $f"; missing=1; }
done
ntplg=$(grep -c '^lib/firmware/intel/sof-ipc4-tplg/.*\.tplg$' "$WORK/ramdisk_listing.txt" || true)
[ "$ntplg" -ge "$MIN_TPLG" ] || { echo "ERROR: only $ntplg SOF topologies in the ramdisk (need >= $MIN_TPLG)"; missing=1; }
[ "$missing" = "0" ] || { echo "ERROR: new ramdisk is incomplete"; exit 1; }
log "   assertion OK: SOF fw + $ntplg topologies under lib/firmware/intel/"

if [ "$DO_WRITE" = "1" ]; then
    if cmp -s "$WORK/ramdisk_in.img" "$WORK/ramdisk_out.img"; then
        log "   ramdisk unchanged - ESP left alone (idempotent)"
    else
        mcopy -o -i "$WORK/p1.img" "$WORK/ramdisk_out.img" "::/boot/ramdisk_bootmedia.img"
        dd if="$WORK/p1.img" of="$IMG" bs=512 seek="$P1_START" count="$P1_SECTORS" conv=notrunc status=none
        log "   p1 written back at sector $P1_START ($P1_SECTORS sectors)"
    fi
fi

# =============================================================== p2 (system)
log "== p2 (system): /system/lib/firmware/intel =="
dd if="$IMG" of="$WORK/p2.img" bs=512 skip="$P2_START" count="$P2_SECTORS" status=none
p2_need=0
p2_changed=0
p2_size() {
    # debugfs prints "User: 0 Group: 0 Project: 0 Size: 586648" on one line
    debugfs -R "stat $1" "$WORK/p2.img" 2>/dev/null | sed -n 's/.*Size: \([0-9][0-9]*\).*/\1/p' | head -1
}

p2_need=0
for f in \
    /system/lib/firmware/intel/sof-ipc4/ptl/sof-ptl.ri \
    /system/lib/firmware/intel/sof-ipc4/ptl/sof-ptl-openmodules.ri \
    /system/lib/firmware/intel/sof-ipc4-tplg/sof-hda-generic-4ch.tplg ; do
    [ -n "$(p2_size "$f")" ] || p2_need=1
done
# the content has to match the source, not just exist
for rel in sof-ipc4/ptl/sof-ptl.ri sof-ipc4/ptl/sof-ptl-openmodules.ri \
           sof-ipc4-tplg/sof-hda-generic-4ch.tplg; do
    src=$(stat -c%s "$FW_DIR/intel/$rel" 2>/dev/null || echo 0)
    cur=$(p2_size "/system/lib/firmware/intel/$rel")
    [ "$src" = "$cur" ] || p2_need=1
done
if [ "$p2_need" = "0" ]; then
    log "   already present and up to date - nothing to do"
else
    log "   injecting the SOF firmware tree ..."
    for d in intel/sof-ipc4/ptl intel/sof-ipc4-tplg intel/sof-ipc4-lib/lnl \
             intel/sof-ipc4-lib/lnl/community intel/sof-ipc4-lib/lnl/intel-signed; do
        [ -d "$FW_DIR/$d" ] || continue
        debugfs -R "mkdir /system/lib/firmware/$d" "$WORK/p2.img" >/dev/null 2>&1 || true
    done
    {
        while read -r f; do
            rel="${f#intel/}"
            # debugfs refuses to overwrite: rm first
            echo "rm /system/lib/firmware/intel/$rel"
            echo "write $FW_DIR/intel/$rel /system/lib/firmware/intel/$rel"
        done < <(cd "$FW_DIR/intel" && find sof-ipc4 sof-ipc4-lib -type f | sort)
    } > "$WORK/p2.cmds"
    debugfs -w -f "$WORK/p2.cmds" "$WORK/p2.img" > "$WORK/p2_debugfs.log" 2>&1 || true
    e2fsck -f -y "$WORK/p2.img" > "$WORK/p2_e2fsck.log" 2>&1 || true
    for f in \
        /system/lib/firmware/intel/sof-ipc4/ptl/sof-ptl.ri \
        /system/lib/firmware/intel/sof-ipc4/ptl/sof-ptl-openmodules.ri \
        /system/lib/firmware/intel/sof-ipc4-tplg/sof-hda-generic-4ch.tplg ; do
        debugfs -R "stat $f" "$WORK/p2.img" >/dev/null 2>&1 \
            || { echo "ERROR: p2 still missing $f"; exit 1; }
    done
    log "   p2 firmware injected"
    p2_changed=1
fi

# --- 2b. zz_audio: align the boot-time volume pass with the real card ------
# The sound card of this machine is `sofhdadsp` (long name `sof-hda-dsp`).
# The previous version of the script hard-coded `amixer -c 0` and did not even
# look at /proc/asound/cards, so it could not tell "card 0 is missing" from
# "card 0 has no such control".  The new one resolves the card id from
# /proc/asound/cards and logs it.
if [ -f "$HERE/stage/zz_audioup.sh" ]; then
    need_audio=0
    debugfs -R "dump /system/bin/zz_audioup.sh $WORK/cur_zz_audioup.sh" "$WORK/p2.img" >/dev/null 2>&1 || true
    if [ ! -f "$WORK/cur_zz_audioup.sh" ] || \
       ! cmp -s "$WORK/cur_zz_audioup.sh" "$HERE/stage/zz_audioup.sh"; then
        need_audio=1
    fi
    if [ "$need_audio" = "1" ]; then
        log "== p2 (system): zz_audio aligned to the sofhdadsp card =="
        {
            echo "rm /system/bin/zz_audioup.sh"
            echo "write $HERE/stage/zz_audioup.sh /system/bin/zz_audioup.sh"
            [ -f "$HERE/stage/zz_audio.cfg" ] && {
                echo "rm /system/etc/init/zz_audio.cfg"
                echo "write $HERE/stage/zz_audio.cfg /system/etc/init/zz_audio.cfg"
            }
        } > "$WORK/p2_audio.cmds"
        debugfs -w -f "$WORK/p2_audio.cmds" "$WORK/p2.img" > "$WORK/p2_audio_debugfs.log" 2>&1 || true
        e2fsck -f -y "$WORK/p2.img" > "$WORK/p2_audio_e2fsck.log" 2>&1 || true
        debugfs -R "stat /system/bin/zz_audioup.sh" "$WORK/p2.img" >/dev/null 2>&1 \
            || { echo "ERROR: zz_audioup.sh not in p2"; exit 1; }
        log "   zz_audioup.sh updated"
        p2_changed=1
    else
        log "== p2 (system): zz_audio already aligned =="
    fi
fi

if [ "$p2_changed" = "1" ] && [ "$DO_WRITE" = "1" ]; then
    dd if="$WORK/p2.img" of="$IMG" bs=512 seek="$P2_START" count="$P2_SECTORS" conv=notrunc status=none
    log "   p2 written back at sector $P2_START ($P2_SECTORS sectors)"
fi

# =============================================================== final check
log "== final verification =="
dd if="$IMG" of="$WORK/v_p1.img" bs=512 skip="$P1_START" count="$P1_SECTORS" status=none
mcopy -i "$WORK/v_p1.img" "::/boot/ramdisk_bootmedia.img" "$WORK/v_ramdisk.img"
python3 "$CPIO_LIST" "$WORK/v_ramdisk.img" > "$WORK/v_listing.txt" 2>/dev/null
rc=0
for f in $REQUIRED; do
    if grep -qx "$f" "$WORK/v_listing.txt"; then
        log "   OK   $f"
    else
        echo "   FAIL $f"; rc=1
    fi
done
n=$(grep -c '^lib/firmware/intel/sof-ipc4-tplg/.*\.tplg$' "$WORK/v_listing.txt" || true)
log "   topologies in the ramdisk: $n"
[ "$n" -ge "$MIN_TPLG" ] || { echo "   FAIL: not enough topologies"; rc=1; }
log "   part_init present: $(grep -qx part_init "$WORK/v_listing.txt" && echo yes || echo NO)"
grep -qx part_init "$WORK/v_listing.txt" || rc=1
log "   ACPI override present: $(grep -qx kernel/firmware/acpi/SSDT27_TPD0.aml "$WORK/v_listing.txt" && echo yes || echo NO)"
grep -qx kernel/firmware/acpi/SSDT27_TPD0.aml "$WORK/v_listing.txt" || rc=1
[ "$rc" = "0" ] || { echo "ERROR: verification failed"; exit 1; }
log "== all good =="
exit 0
