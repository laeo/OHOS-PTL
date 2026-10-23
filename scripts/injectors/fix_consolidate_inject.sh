#!/bin/bash
# fix_consolidate inject: p2 (system) + p3 (vendor) of the pc_ptl disk image.
# Backup already at media/ohos_part_pc_ptl.pre_consolidate.img
set -eu
ROOT=/home/katax/Public/OHOS
BASE=$ROOT/out/x86_64_virt/ohos-dbg
DISK=$BASE/partdisk/media/ohos_part_pc_ptl.img
W=$BASE/fix_consolidate/work
OUT=$ROOT/out/ptl

# --- inputs ---
ZZ_PSLOG=$BASE/partdisk/work/zz_pslog.sh
ZZ_PTLLOG=$BASE/partdisk/tmpfs/zz_ptllog.sh
HDF_HOST=$OUT/hdf/hdf_core/libhdf_host.z.so
VENDOR=$OUT/device_x86_64_virt/qemu_virt_full_x86_64/libdisplay_composer_vendor.z.so
for f in "$ZZ_PSLOG" "$ZZ_PTLLOG" "$HDF_HOST" "$VENDOR"; do
  [ -f "$f" ] || { echo "MISSING $f"; exit 1; }
done

echo "== p2 system =="
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
  echo "rm /system/lib64/libhdf_host.z.so"
  echo "write $HDF_HOST /system/lib64/libhdf_host.z.so"
  echo "set_inode_field /system/lib64/libhdf_host.z.so mode 0100644"
  echo "set_inode_field /system/lib64/libhdf_host.z.so uid 0"
  echo "set_inode_field /system/lib64/libhdf_host.z.so gid 0"
  echo "rm /system/lib64/chipset-sdk-sp/libhdf_host.z.so"
  echo "write $HDF_HOST /system/lib64/chipset-sdk-sp/libhdf_host.z.so"
  echo "set_inode_field /system/lib64/chipset-sdk-sp/libhdf_host.z.so mode 0100644"
  echo "set_inode_field /system/lib64/chipset-sdk-sp/libhdf_host.z.so uid 0"
  echo "set_inode_field /system/lib64/chipset-sdk-sp/libhdf_host.z.so gid 0"
} | debugfs -w "$W/system.img" > "$BASE/fix_consolidate/inject_p2.log" 2>&1
e2fsck -f -y "$W/system.img" > "$BASE/fix_consolidate/e2fsck_p2.log" 2>&1 || true
dd if="$W/system.img" of="$DISK" bs=512 seek=1050624 count=4194304 conv=notrunc,fsync status=none
echo "p2 written back"

echo "== p3 vendor =="
{
  echo "rm /lib64/libdisplay_composer_vendor.z.so"
  echo "write $VENDOR /lib64/libdisplay_composer_vendor.z.so"
  echo "set_inode_field /lib64/libdisplay_composer_vendor.z.so mode 0100644"
  echo "set_inode_field /lib64/libdisplay_composer_vendor.z.so uid 0"
  echo "set_inode_field /lib64/libdisplay_composer_vendor.z.so gid 0"
} | debugfs -w "$W/vendor.img" > "$BASE/fix_consolidate/inject_p3.log" 2>&1
e2fsck -f -y "$W/vendor.img" > "$BASE/fix_consolidate/e2fsck_p3.log" 2>&1 || true
dd if="$W/vendor.img" of="$DISK" bs=512 seek=5244928 count=1048576 conv=notrunc,fsync status=none
echo "p3 written back"
echo "INJECT_DONE"
