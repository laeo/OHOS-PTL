#!/bin/bash
# run_nodisk_diag.sh - deliberately boot with NO block device attached, to prove
# the DIAGNOSTIC part_init output reaches the console even when the USB disk is
# invisible.  Uses -kernel/-initrd so we get a serial console for capture.
set -u
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/partdisk
MEDIA=$BASE/media
BZIMAGE=/home/katax/Public/OHOS/out/ptl/packages/phone/images/bzImage
SER=$BASE/nodisk_serial.log
pkill -9 -f 'qemu-system-x86_64 -[m]achine' 2>/dev/null
sleep 1
rm -f "$SER"
APPEND='console=tty0 console=ttyS0,115200 earlycon=efifb log_buf_len=4M panic=10 softlockup_panic=1 sysrq_always_enabled=1 split_lock_detect=off rdinit=/part_init root=/dev/ram0 rw sn=0123456789 hardware=pc_ptl ohos.boot.hardware=pc_ptl'
# NOTE: no -drive / no USB storage at all.
exec qemu-system-x86_64 -machine q35 -accel kvm -cpu max -smp 4 -m 2048 \
  -kernel "$BZIMAGE" \
  -initrd "$MEDIA/ramdisk_bootmedia.img" \
  -append "$APPEND" \
  -vga none -display none \
  -chardev file,id=ser0,path="$SER" -serial chardev:ser0 \
  -boot menu=off -no-reboot
