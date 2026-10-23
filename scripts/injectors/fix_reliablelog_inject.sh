#!/bin/bash
# fix_reliablelog inject: p3 vendor (4 display libs + init.pc_ptl.cfg),
#                         p2 system (zz_pslog.sh / zz_ptllog.sh),
#                         p1 ESP grub.cfg (add printk.devkmsg=on).
# Backup (media/*.pre_reliablelog.img) is taken by the caller (run.sh) first.
set -eu
ROOT=/home/katax/Public/OHOS
BASE=$ROOT/out/x86_64_virt/ohos-dbg
DISK=$BASE/partdisk/media/ohos_part_pc_ptl.img
W=$BASE/fix_reliablelog/work
OUT=$ROOT/out/ptl

VENDOR_LIB=$OUT/device_x86_64_virt/qemu_virt_full_x86_64/libdisplay_composer_vendor.z.so
VDI_LIB=$OUT/device_x86_64_virt/qemu_virt_full_x86_64/libdisplay_composer_vdi_impl.z.so
SVC_LIB=$OUT/hdf/drivers_peripheral_display/libdisplay_composer_service_1.5.z.so
DRV_LIB=$OUT/hdf/drivers_peripheral_display/libdisplay_composer_driver_1.0.z.so
ZZ_PSLOG=$BASE/partdisk/work/zz_pslog.sh
ZZ_PTLLOG=$BASE/partdisk/tmpfs/zz_ptllog.sh

for f in "$VENDOR_LIB" "$VDI_LIB" "$SVC_LIB" "$DRV_LIB" "$ZZ_PSLOG" "$ZZ_PTLLOG"; do
  [ -f "$f" ] || { echo "MISSING $f"; exit 1; }
done

echo "== extract fresh p2/p3 from disk =="
rm -f "$W/system.img" "$W/vendor.img"
dd if="$DISK" of="$W/system.img" bs=512 skip=1050624 count=4194304 status=none
dd if="$DISK" of="$W/vendor.img" bs=512 skip=5244928 count=1048576 status=none

echo "== p3: init.pc_ptl.cfg (create world-writable compkmsg dirs) =="
debugfs -R "dump /etc/init.pc_ptl.cfg $W/init.pc_ptl.cfg.orig" "$W/vendor.img" >/dev/null 2>&1
grep -q 'chmod 0666 /dev/kmsg' "$W/init.pc_ptl.cfg.orig" || { echo "init.pc_ptl.cfg: marker missing"; exit 1; }
if ! grep -q 'compkmsg' "$W/init.pc_ptl.cfg.orig"; then
  sed 's#\("chmod 0666 /dev/kmsg"\)#\1,\n                "mkdir /data/compkmsg 0777",\n                "chmod 0777 /data/compkmsg",\n                "mkdir /ohoslog/compkmsg 0777",\n                "chmod 0777 /ohoslog/compkmsg"#' \
    "$W/init.pc_ptl.cfg.orig" > "$W/init.pc_ptl.cfg.new"
else
  cp -f "$W/init.pc_ptl.cfg.orig" "$W/init.pc_ptl.cfg.new"
fi
grep -q 'mkdir /data/compkmsg 0777' "$W/init.pc_ptl.cfg.new" || { echo "mkdir inject failed"; exit 1; }

echo "== p3: inject 4 display libs + init.pc_ptl.cfg =="
{
  echo "rm /lib64/libdisplay_composer_vendor.z.so"
  echo "write $VENDOR_LIB /lib64/libdisplay_composer_vendor.z.so"
  echo "set_inode_field /lib64/libdisplay_composer_vendor.z.so mode 0100644"
  echo "set_inode_field /lib64/libdisplay_composer_vendor.z.so uid 0"
  echo "set_inode_field /lib64/libdisplay_composer_vendor.z.so gid 0"
  echo "rm /lib64/libdisplay_composer_vdi_impl.z.so"
  echo "write $VDI_LIB /lib64/libdisplay_composer_vdi_impl.z.so"
  echo "set_inode_field /lib64/libdisplay_composer_vdi_impl.z.so mode 0100644"
  echo "set_inode_field /lib64/libdisplay_composer_vdi_impl.z.so uid 0"
  echo "set_inode_field /lib64/libdisplay_composer_vdi_impl.z.so gid 0"
  echo "rm /lib64/libdisplay_composer_service_1.5.z.so"
  echo "write $SVC_LIB /lib64/libdisplay_composer_service_1.5.z.so"
  echo "set_inode_field /lib64/libdisplay_composer_service_1.5.z.so mode 0100644"
  echo "set_inode_field /lib64/libdisplay_composer_service_1.5.z.so uid 0"
  echo "set_inode_field /lib64/libdisplay_composer_service_1.5.z.so gid 0"
  echo "rm /lib64/libdisplay_composer_driver_1.0.z.so"
  echo "write $DRV_LIB /lib64/libdisplay_composer_driver_1.0.z.so"
  echo "set_inode_field /lib64/libdisplay_composer_driver_1.0.z.so mode 0100644"
  echo "set_inode_field /lib64/libdisplay_composer_driver_1.0.z.so uid 0"
  echo "set_inode_field /lib64/libdisplay_composer_driver_1.0.z.so gid 0"
  echo "rm /etc/init.pc_ptl.cfg"
  echo "write $W/init.pc_ptl.cfg.new /etc/init.pc_ptl.cfg"
  echo "set_inode_field /etc/init.pc_ptl.cfg mode 0100644"
  echo "set_inode_field /etc/init.pc_ptl.cfg uid 0"
  echo "set_inode_field /etc/init.pc_ptl.cfg gid 0"
} | debugfs -w "$W/vendor.img" > "$BASE/fix_reliablelog/inject_p3.log" 2>&1
e2fsck -f -y "$W/vendor.img" > "$BASE/fix_reliablelog/e2fsck_p3.log" 2>&1 || true
dd if="$W/vendor.img" of="$DISK" bs=512 seek=5244928 count=1048576 conv=notrunc,fsync status=none
echo "p3 written back"

echo "== p2: zz_pslog.sh / zz_ptllog.sh =="
{
  echo "rm /system/bin/zz_pslog.sh"
  echo "write $ZZ_PSLOG /system/bin/zz_pslog.sh"
  echo "set_inode_field /system/bin/zz_pslog.sh mode 0100755"
  echo "set_inode_field /system/bin/zz_pslog.sh uid 0"
  echo "set_inode_field /system/bin/zz_pslog.sh gid 0"
  echo "rm /system/bin/zz_ptllog.sh"
  echo "write $ZZ_PTLLOG /system/bin/zz_ptllog.sh"
  echo "set_inode_field /system/bin/zz_ptllog.sh mode 0100755"
  echo "set_inode_field /system/bin/zz_ptllog.sh uid 0"
  echo "set_inode_field /system/bin/zz_ptllog.sh gid 0"
} | debugfs -w "$W/system.img" > "$BASE/fix_reliablelog/inject_p2.log" 2>&1
e2fsck -f -y "$W/system.img" > "$BASE/fix_reliablelog/e2fsck_p2.log" 2>&1 || true
dd if="$W/system.img" of="$DISK" bs=512 seek=1050624 count=4194304 conv=notrunc,fsync status=none
echo "p2 written back"

echo "== p1 ESP: add printk.devkmsg=on to every kernel cmdline =="
mcopy -o -i "$DISK@@1048576" ::/boot/grub/grub.cfg "$W/grub_esp_before.cfg"
sed 's/intel_idle\.max_cstate=1/intel_idle.max_cstate=1 printk.devkmsg=on/g' \
    "$W/grub_esp_before.cfg" > "$W/grub_esp_after.cfg"
grep -q 'printk.devkmsg=on' "$W/grub_esp_after.cfg" || { echo "grub sed failed"; exit 1; }
mcopy -o -i "$DISK@@1048576" "$W/grub_esp_after.cfg" ::/boot/grub/grub.cfg
mcopy -i "$DISK@@1048576" ::/boot/grub/grub.cfg "$W/grub_esp_readback.cfg"
cmp -s "$W/grub_esp_after.cfg" "$W/grub_esp_readback.cfg" || { echo "grub readback mismatch"; exit 1; }
echo "grub.cfg patched (printk.devkmsg=on x$(grep -c printk.devkmsg=on "$W/grub_esp_readback.cfg"))"

echo "INJECT_DONE"
