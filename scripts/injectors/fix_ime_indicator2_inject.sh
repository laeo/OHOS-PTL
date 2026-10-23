#!/bin/bash
# fix_ime_indicator2: inject the rebuilt pc_sceneboard HAP (ImeIndicatorModule) into
# partdisk/media/ohos_part_pc_ptl.img, p2 = system (start sector 1050624, 2 GiB).
# Only p2 is touched; p1/p3-p6, GPT and the user USB stick are untouched.
# Backup (.zst) must already exist: ohos_part_pc_ptl.pre_ime_indicator2.img.zst
set -eu
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
DISK=$BASE/partdisk/media/ohos_part_pc_ptl.img
W=$BASE/fix_ime_indicator2
HAP=$BASE/porting/scb_src/product/pc/build/default/outputs/default/pc_sceneboard-default-signed.hap
mkdir -p "$W"

echo "=== new hap ==="; sha256sum "$HAP"; ls -la "$HAP"
echo "=== extract p2 (2 GiB, sparse) ==="
rm -f "$W/p2.img"
dd if="$DISK" of="$W/p2.img" bs=512 skip=1050624 count=4194304 conv=sparse status=none
ls -l "$W/p2.img"

echo "=== baseline SceneBoard.hap in p2 ==="
debugfs -R "dump /system/app/SceneBoard/SceneBoard.hap $W/old_sceneboard.hap" "$W/p2.img" >/dev/null 2>&1 || true
sha256sum "$W/old_sceneboard.hap" 2>/dev/null || echo "(old hap not dumped)"

echo "=== debugfs inject ==="
{
  echo "rm /system/app/SceneBoard/SceneBoard.hap"
  echo "write $HAP /system/app/SceneBoard/SceneBoard.hap"
  echo "set_inode_field /system/app/SceneBoard/SceneBoard.hap mode 0100644"
} | debugfs -w "$W/p2.img" > "$W/inject_p2.log" 2>&1 || true
cat "$W/inject_p2.log"
echo "=== e2fsck ==="
e2fsck -f -y "$W/p2.img" > "$W/e2fsck_p2.log" 2>&1 || true
tail -3 "$W/e2fsck_p2.log"
echo "=== dd back ==="
dd if="$W/p2.img" of="$DISK" bs=512 seek=1050624 count=4194304 conv=notrunc,fsync status=none
sync
echo "=== readback verify (from disk p2) ==="
rm -f "$W/p2rb.img"
dd if="$DISK" of="$W/p2rb.img" bs=512 skip=1050624 count=4194304 conv=sparse status=none
debugfs -R "dump /system/app/SceneBoard/SceneBoard.hap $W/rb_p2_scb.hap" "$W/p2rb.img" >/dev/null 2>&1 || true
s1=$(sha256sum "$W/rb_p2_scb.hap" | cut -d' ' -f1); s2=$(sha256sum "$HAP" | cut -d' ' -f1)
[ "$s1" = "$s2" ] && echo "OK hap $s1" || echo "FAIL hap $s1 vs $s2"
rm -f "$W/p2.img" "$W/p2rb.img"
echo "=== new disk sha256 / size ==="
sha256sum "$DISK"; ls -la "$DISK"
echo "INJECT_PARTDISK_DONE"
