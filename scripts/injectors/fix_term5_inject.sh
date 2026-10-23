#!/bin/bash
# fix_term5/inject.sh - inject the reworked terminal HAP + the chroot-session
# PTY daemon into the pc_ptl partdisk image.  Touches ONLY p2 (system).
# Leaves exactly one .zst backup of the previous image, never an uncompressed
# whole-disk copy.
set -e
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
IMG=$BASE/partdisk/media/ohos_part_pc_ptl.img
W=$BASE/fix_term5
HAP=$W/terminal-signed.hap
DMN=$W/daemon/ohosptyd
P2=$W/p2_t5.img
BK=$BASE/partdisk/media/ohos_part_pc_ptl.pre_term5.img.zst

echo "[0/7] stop qemu"
pkill -9 -f 'qemu-system-x86_64 -[m]achine' 2>/dev/null || true
sleep 2

echo "[1/7] sha256 before"
sha256sum "$IMG" | tee "$W/sha_before.txt"
if [ -f "$BK" ]; then rm -f "$BK"; fi

echo "[2/7] backup -> $(basename "$BK")"
zstd -T8 -6 -q -f "$IMG" -o "$BK"
ls -la "$BK"

echo "[3/7] extract p2"
rm -f "$P2"
dd if="$IMG" of="$P2" bs=1M skip=513 count=2048 status=none
echo "free before: $(debugfs -R 'stats' "$P2" 2>/dev/null | grep -i 'Free blocks' | head -1)"

echo "[4/7] debugfs inject"
debugfs -w "$P2" 2>&1 <<EOF | grep -vE '^debugfs ' || true
rm /system/app/Terminal/Terminal.hap
write $HAP /system/app/Terminal/Terminal.hap
sif /system/app/Terminal/Terminal.hap mode 0100644
sif /system/app/Terminal/Terminal.hap uid 0
sif /system/app/Terminal/Terminal.hap gid 0
rm /system/bin/ohosshd
write $DMN /system/bin/ohosshd
sif /system/bin/ohosshd mode 0100755
sif /system/bin/ohosshd uid 0
sif /system/bin/ohosshd gid 0
EOF

echo "[5/7] e2fsck p2"
e2fsck -f -y "$P2" > "$W/e2fsck.inject.log" 2>&1 || true
tail -2 "$W/e2fsck.inject.log"
echo "free after: $(debugfs -R 'stats' "$P2" 2>/dev/null | grep -i 'Free blocks' | head -1)"

echo "[6/7] write back p2"
dd if="$P2" of="$IMG" bs=1M seek=513 count=2048 conv=notrunc,fsync status=none
sync
rm -f "$P2"

echo "[7/7] verify + sha256"
rm -f "$W/check.hap" "$W/check.dmn"
debugfs -R "dump /system/app/Terminal/Terminal.hap $W/check.hap" "$IMG?offset=537919488" >/dev/null 2>&1
debugfs -R "dump /system/bin/ohosshd $W/check.dmn" "$IMG?offset=537919488" >/dev/null 2>&1
echo "HAP  img=$(sha256sum $W/check.hap | cut -d' ' -f1)  src=$(sha256sum $HAP | cut -d' ' -f1)"
echo "DMN  img=$(sha256sum $W/check.dmn | cut -d' ' -f1)  src=$(sha256sum $DMN | cut -d' ' -f1)"
rm -f "$W/check.hap" "$W/check.dmn"
sha256sum "$IMG" | tee "$W/new_sha256.txt"
stat -c '%s bytes' "$IMG"
echo "[done]"