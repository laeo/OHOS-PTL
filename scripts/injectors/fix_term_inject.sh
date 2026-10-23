#!/bin/bash
# Inject the new terminal HAP + ohosptyd daemon + Alpine musl node into the
# pc_ptl partdisk SYSTEM partition (p2).  Touches ONLY p2.
set -e
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
SB=$BASE/fix_term
DISK=$BASE/partdisk/media/ohos_part_pc_ptl.img
WORK=$SB/work
P2_START=1050624
P2_COUNT=4194304

mkdir -p "$WORK"
pkill -9 -f 'qemu-system-x86_64 -[m]achine' 2>/dev/null || true
sleep 1

if [ ! -f "$BASE/partdisk/media/ohos_part_pc_ptl.pre_term.img.zst" ]; then
  echo "[backup] -> ohos_part_pc_ptl.pre_term.img.zst"
  zstd -T8 -3 -q -f "$DISK" -o "$BASE/partdisk/media/ohos_part_pc_ptl.pre_term.img.zst"
fi

echo "[extract] p2"
dd if="$DISK" of="$WORK/p2.img" bs=512 skip=$P2_START count=$P2_COUNT status=none

echo "[debugfs] apply inject.dbgfs"
debugfs -w -f "$WORK/inject.dbgfs" "$WORK/p2.img" > "$WORK/debugfs.log" 2>&1 || true
grep -icE 'error|not found|does not exist' "$WORK/debugfs.log" | sed 's/^/[debugfs suspicious lines] /'
tail -5 "$WORK/debugfs.log"

echo "[e2fsck]"
e2fsck -f -y "$WORK/p2.img" >/dev/null 2>&1 || true

echo "[dd back]"
dd if="$WORK/p2.img" of="$DISK" bs=512 seek=$P2_START conv=notrunc,fsync status=none
sync

echo "[sha256]"
sha256sum "$DISK" | tee "$WORK/new_sha256.txt"
stat -c '%s bytes' "$DISK"
echo "[done]"
