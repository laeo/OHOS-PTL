#!/bin/bash
# Inject the polished terminal HAP + unprivileged-session PTY daemon + setuid
# sudo helper into the delivered disk image (p2/system only).
set -e
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
IMG=$BASE/partdisk/media/ohos_part_pc_ptl.img
W=$BASE/fix_term_env
HAP=$W/terminal-signed.hap
DMN=$W/daemon/ohosptyd
SUD=$W/daemon/sudoh
P2=$W/p2_final.img

echo "[1/6] extract p2"
dd if="$IMG" of="$P2" bs=1M skip=513 count=2048 status=none

echo "[2/6] debugfs inject"
debugfs -w "$P2" <<EOF
rm /system/app/Terminal/Terminal.hap
write $HAP /system/app/Terminal/Terminal.hap
sif /system/app/Terminal/Terminal.hap mode 0100644
rm /system/bin/ohosshd
write $DMN /system/bin/ohosshd
sif /system/bin/ohosshd mode 0100755
rm /system/bin/sudo
write $SUD /system/bin/sudo
sif /system/bin/sudo mode 0104755
EOF

echo "[3/6] e2fsck"
e2fsck -f -y "$P2" > "$W/e2fsck.inject.log" 2>&1 || true
tail -1 "$W/e2fsck.inject.log"

echo "[4/6] write back p2"
dd if="$P2" of="$IMG" bs=1M seek=513 count=2048 conv=notrunc,fsync status=none
sync

echo "[5/6] verify (dump back from image)"
rm -f "$W/check.hap" "$W/check.ohosshd" "$W/check.sudo"
debugfs -R "dump /system/app/Terminal/Terminal.hap $W/check.hap" "$IMG?offset=537919488" >/dev/null 2>&1
debugfs -R "dump /system/bin/ohosshd $W/check.ohosshd" "$IMG?offset=537919488" >/dev/null 2>&1
debugfs -R "dump /system/bin/sudo $W/check.sudo" "$IMG?offset=537919488" >/dev/null 2>&1
echo "HAP  img=$(sha256sum $W/check.hap | cut -d' ' -f1)  src=$(sha256sum $HAP | cut -d' ' -f1)"
echo "DMN  img=$(sha256sum $W/check.ohosshd | cut -d' ' -f1)  src=$(sha256sum $DMN | cut -d' ' -f1)"
echo "SUD  img=$(sha256sum $W/check.sudo | cut -d' ' -f1)  src=$(sha256sum $SUD | cut -d' ' -f1)"
debugfs -R "stat /system/bin/sudo" "$IMG?offset=537919488" 2>/dev/null | grep -E 'Mode|Size'
rm -f "$W/check.hap" "$W/check.ohosshd" "$W/check.sudo"

echo "[6/6] done"
