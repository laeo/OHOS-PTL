#!/bin/bash
# fix_instr: inject rebuilt display HDI libs into vendor partition (p3) of the U-disk image.
set -eu
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/fix_instr
WORK=$BASE/work
DISK=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/partdisk/media/ohos_part_pc_ptl.img
OUT=/home/katax/Public/OHOS/out/ptl
V=$WORK/vendor_instr.img

D1=$OUT/hdf/drivers_peripheral_display/libdisplay_composer_driver_1.0.z.so
D2=$OUT/hdf/drivers_peripheral_display/libdisplay_composer_service_1.5.z.so
D3=$OUT/device_x86_64_virt/qemu_virt_full_x86_64/libdisplay_composer_vdi_impl.z.so
D4=$OUT/device_x86_64_virt/qemu_virt_full_x86_64/libdisplay_composer_vendor.z.so

for f in "$D1" "$D2" "$D3" "$D4"; do
  [ -f "$f" ] || { echo "missing $f"; exit 1; }
done

{
  echo "rm /lib64/libdisplay_composer_driver_1.0.z.so"
  echo "write $D1 /lib64/libdisplay_composer_driver_1.0.z.so"
  echo "set_inode_field /lib64/libdisplay_composer_driver_1.0.z.so mode 0100644"
  echo "rm /lib64/libdisplay_composer_service_1.5.z.so"
  echo "write $D2 /lib64/libdisplay_composer_service_1.5.z.so"
  echo "set_inode_field /lib64/libdisplay_composer_service_1.5.z.so mode 0100644"
  echo "rm /lib64/libdisplay_composer_vdi_impl.z.so"
  echo "write $D3 /lib64/libdisplay_composer_vdi_impl.z.so"
  echo "set_inode_field /lib64/libdisplay_composer_vdi_impl.z.so mode 0100644"
  echo "rm /lib64/libdisplay_composer_vendor.z.so"
  echo "write $D4 /lib64/libdisplay_composer_vendor.z.so"
  echo "set_inode_field /lib64/libdisplay_composer_vendor.z.so mode 0100644"
} | debugfs -w "$V"

e2fsck -f -y "$V"

dd if="$V" of="$DISK" bs=512 seek=5244928 count=1048576 conv=notrunc,fsync status=none
echo "INJECT_DONE"
