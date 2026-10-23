#!/bin/bash
# Inject Aira signed HAP + install_list entry into system (p2) and the fixed
# battery HDI library into vendor (p3) of the pc_ptl partdisk image.
set -e
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
IMG=$BASE/partdisk/media/ohos_part_pc_ptl.img
W=$BASE/fix_browser_batt
HAP=$W/aira/Aira-community-v3.7.1-signed.hap
BAT=/home/katax/Public/OHOS/out/ptl/hdf/drivers_peripheral_battery/libbattery_interface_service_2.0.z.so

echo "[1/7] extract p2 (2G, skip 513) and p3 (512M, skip 2561)"
dd if="$IMG" of="$W/p2.img" bs=1M skip=513 count=2048 status=none
dd if="$IMG" of="$W/p3.img" bs=1M skip=2561 count=512 status=none

echo "[2/7] p3: replace battery HDI lib"
debugfs -w "$W/p3.img" <<EOF
rm /lib64/libbattery_interface_service_2.0.z.so
write $BAT /lib64/libbattery_interface_service_2.0.z.so
sif /lib64/libbattery_interface_service_2.0.z.so mode 0100644
EOF

echo "[3/7] p2: install Aira HAP + install_list entry"
debugfs -w "$W/p2.img" <<EOF
mkdir /system/app/org.aira.browser
write $HAP /system/app/org.aira.browser/Aira.hap
sif /system/app/org.aira.browser/Aira.hap mode 0100644
rm /system/etc/app/install_list.json
write $W/install_list.json.new /system/etc/app/install_list.json
sif /system/etc/app/install_list.json mode 0100644
EOF

echo "[4/7] e2fsck p2/p3"
e2fsck -f -y "$W/p2.img" > "$W/e2fsck_p2.log" 2>&1 || true
e2fsck -f -y "$W/p3.img" > "$W/e2fsck_p3.log" 2>&1 || true
tail -1 "$W/e2fsck_p2.log"; tail -1 "$W/e2fsck_p3.log"

echo "[5/7] write back p2/p3"
dd if="$W/p2.img" of="$IMG" bs=1M seek=513 count=2048 conv=notrunc,fsync status=none
dd if="$W/p3.img" of="$IMG" bs=1M seek=2561 count=512 conv=notrunc,fsync status=none
sync

echo "[6/7] verify readback"
rm -f "$W/check_aira.hap" "$W/check_il.json" "$W/check_bat.so"
debugfs -R "dump /system/app/org.aira.browser/Aira.hap $W/check_aira.hap" "$IMG?offset=537919488" >/dev/null 2>&1
debugfs -R "dump /system/etc/app/install_list.json $W/check_il.json" "$IMG?offset=537919488" >/dev/null 2>&1
debugfs -R "dump /lib64/libbattery_interface_service_2.0.z.so $W/check_bat.so" "$IMG?offset=2685403136" >/dev/null 2>&1
echo "HAP  img=$(sha256sum $W/check_aira.hap | cut -d' ' -f1)  src=$(sha256sum $HAP | cut -d' ' -f1)"
echo "IL   img=$(sha256sum $W/check_il.json | cut -d' ' -f1)  src=$(sha256sum $W/install_list.json.new | cut -d' ' -f1)"
echo "BAT  img=$(sha256sum $W/check_bat.so | cut -d' ' -f1)  src=$(sha256sum $BAT | cut -d' ' -f1)"
grep -c org.aira.browser "$W/check_il.json"

echo "[7/7] cleanup temp partitions"
rm -f "$W/check_aira.hap" "$W/check_il.json" "$W/check_bat.so"
ls -la "$W/p2.img" "$W/p3.img"
echo "done"
