#!/bin/bash
# fix_rime_rebuild/inject.sh
# Inject the rebuilt com.ohos.rimeime HAP into the pc_ptl partdisk image (ONLY p2 / system).
# Leaves exactly one .zst whole-disk backup; never an uncompressed whole-disk copy.
set -e
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
IMG=$BASE/partdisk/media/ohos_part_pc_ptl.img
W=$BASE/fix_rime_rebuild
P2=$W/work/p2.img
BK=$BASE/partdisk/media/ohos_part_pc_ptl.pre_rime_rebuild.img.zst
HAP=$W/work/rimeime_src/entry/build/default/outputs/default/entry-default-unsigned.hap
OLDHAP=$W/work/RimeIme.cur.hap

echo "[0/7] stop qemu"
pkill -9 -f 'qemu-system-x86_64 -[m]achine' 2>/dev/null || true
sleep 1

echo "[1/7] sha256 before"
sha256sum "$IMG" | tee "$W/sha_before.txt"
ls -la "$HAP"
sha256sum "$HAP" | tee "$W/hap_sha256.txt"

if [ ! -f "$BK" ]; then
  echo "[2/7] backup -> $(basename "$BK")"
  zstd -T8 -3 -q -f "$IMG" -o "$BK"
  sha256sum "$BK" | tee "$W/backup_sha256.txt"
  ls -la "$BK"
else
  echo "[2/7] backup exists, reuse"
fi

echo "[3/7] extract p2"
rm -f "$P2"
dd if="$IMG" of="$P2" bs=1M skip=513 count=2048 status=none
# keep a copy of the old HAP for rollback reference
debugfs -R "dump /system/app/com.ohos.rimeime/RimeIme.hap $OLDHAP" "$P2" 2>/dev/null || true
sha256sum "$OLDHAP"

echo "[4/7] debugfs inject"
debugfs -w "$P2" 2>&1 <<EOF | grep -vE '^debugfs ' || true
rm /system/app/com.ohos.rimeime/RimeIme.hap
write $HAP /system/app/com.ohos.rimeime/RimeIme.hap
sif /system/app/com.ohos.rimeime/RimeIme.hap mode 0100644
sif /system/app/com.ohos.rimeime/RimeIme.hap uid 0
sif /system/app/com.ohos.rimeime/RimeIme.hap gid 0
EOF

echo "[5/7] e2fsck p2"
e2fsck -f -y "$P2" > "$W/e2fsck_p2.log" 2>&1 || true
tail -2 "$W/e2fsck_p2.log"
debugfs -R 'stats' "$P2" 2>/dev/null | grep -i 'Free blocks' | head -1

echo "[6/7] write back p2"
dd if="$P2" of="$IMG" bs=1M seek=513 count=2048 conv=notrunc status=none
sync

echo "[7/7] readback verify"
rm -f "$W/work/rb_rime.hap"
debugfs -R "dump /system/app/com.ohos.rimeime/RimeIme.hap $W/work/rb_rime.hap" "$P2" 2>/dev/null
OK=1
cmp -s "$HAP" "$W/work/rb_rime.hap" && echo "OK rimeime" || { echo "MISMATCH rimeime"; OK=0; }
rm -f "$W/work/rb_rime.hap"
echo "verify_ok=$OK"
sha256sum "$IMG" | tee "$W/new_sha256.txt"
ls -la "$IMG"