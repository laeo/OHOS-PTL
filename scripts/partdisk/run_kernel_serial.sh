#!/bin/bash
# Stage A: -kernel/-initrd + verbose serial, disk attached as USB storage.
# Proves: real GPT partitions -> part_init by-name -> stock init mounts ->
# switch_root -> userland.  Uses a qcow2 overlay so the deliverable disk is
# never modified.
set -u
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/partdisk
MEDIA=$BASE/media
BZIMAGE=/home/katax/Public/OHOS/out/ptl/packages/phone/images/bzImage
DISK=$MEDIA/ohos_part_pc_ptl.img
OVL=$BASE/work/stepA_overlay.qcow2
SER=$BASE/stepA_serial.log
pkill -9 -f 'qemu-system-x86_64 -[m]achine' 2>/dev/null
sleep 1
rm -f "$OVL" "$SER"
qemu-img create -f qcow2 -b "$DISK" -F raw "$OVL" >/dev/null || exit 1
APPEND='console=tty0 console=ttyS0,115200 earlycon=efifb log_buf_len=4M panic=10 softlockup_panic=1 nmi_watchdog=panic,1 sysrq_always_enabled=1 firmware_class.path=/system/lib/firmware memmap=1M$0x7e000000 ramoops.mem_address=0x7e000000 ramoops.mem_size=0x100000 ramoops.console_size=0x80000 split_lock_detect=off rdinit=/part_init root=/dev/ram0 rw sn=0123456789 hardware=pc_ptl ohos.required_mount.system=/dev/block/by-name/system@/usr@ext4@ro,barrier=1@wait,required ohos.required_mount.vendor=/dev/block/by-name/vendor@/vendor@ext4@ro,barrier=1@wait,required ohos.required_mount.sys_prod=/dev/block/by-name/sys_prod@/sys_prod@ext4@rw,barrier=1@wait,required ohos.required_mount.chip_prod=/dev/block/by-name/chip_prod@/chip_prod@ext4@rw,barrier=1@wait,required ohos.required_mount.data=/dev/block/by-name/userdata@/data@ext4@nosuid,nodev,noatime,barrier=1,data=ordered,noauto_da_alloc@wait,reservedsize=104857600 ohos.boot.hardware=pc_ptl'
exec qemu-system-x86_64 -machine q35 -accel kvm -cpu max -smp 4 -m 4096 \
  -kernel "$BZIMAGE" \
  -initrd "$MEDIA/ramdisk_bootmedia.img" \
  -append "$APPEND" \
  -drive if=none,id=ud,file="$OVL",format=qcow2 \
  -device qemu-xhci,id=xhci -device usb-storage,bus=xhci.0,drive=ud \
  -vga none -device virtio-gpu-pci -display none \
  -chardev file,id=ser0,path="$SER" -serial chardev:ser0 \
  -boot menu=off -no-reboot
