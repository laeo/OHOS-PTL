#!/bin/bash
# fix_conn: replace ONLY libdisplay_composer_vendor.z.so in the pc_ptl disk's
# vendor partition (p3).  All other fix_instr/fix_encdr/fix_bootorder contents
# (driver/service/vdi_impl .so, hdf_devhost.cfg, init.cfg, GRUB, bootevents,
# load_order, tmpfs /data) are left untouched.
set -eu
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/fix_conn
WORK=$BASE/work
DISK=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/partdisk/media/ohos_part_pc_ptl.img
OUT=/home/katax/Public/OHOS/out/ptl
V=$WORK/vendor_conn.img

# p3 vendor: start sector 5244928, length 1048576 sectors (512 MiB)
dd if=$DISK of=$V bs=512 skip=5244928 count=1048576 status=none conv=sparse

D4=$OUT/device_x86_64_virt/qemu_virt_full_x86_64/libdisplay_composer_vendor.z.so
if [ ! -f "$D4" ]; then echo "MISSING $D4"; exit 1; fi

{
  echo "rm /lib64/libdisplay_composer_vendor.z.so"
  echo "write $D4 /lib64/libdisplay_composer_vendor.z.so"
  echo "set_inode_field /lib64/libdisplay_composer_vendor.z.so mode 0100644"
} | debugfs -w "$V" 2>/dev/null

e2fsck -f -y "$V" >/dev/null 2>&1
dd if="$V" of="$DISK" bs=512 seek=5244928 count=1048576 conv=notrunc,fsync status=none
echo "INJECT_CONN_DONE"
