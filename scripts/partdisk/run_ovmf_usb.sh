#!/bin/bash
# Stage B: faithful UEFI -> GRUB(ESP) -> kernel/ramdisk -> OHOS userland,
# booting the *whole disk image* as USB mass storage (as a real U-disk would).
# Overlay so the deliverable is not modified.
set -u
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/partdisk
MEDIA=$BASE/media
DISK=$MEDIA/ohos_part_pc_ptl.img
OVL=$BASE/work/stepB_overlay.qcow2
SER=$BASE/stepB_serial.log
VARS=$BASE/work/OVMF_VARS_stepB.fd
pkill -9 -f 'qemu-system-x86_64 -[m]achine' 2>/dev/null
sleep 1
rm -f "$OVL" "$SER"
qemu-img create -f qcow2 -b "$DISK" -F raw "$OVL" >/dev/null || exit 1
cp -f /usr/share/OVMF/OVMF_VARS_4M.fd "$VARS"
exec qemu-system-x86_64 -machine q35 -accel kvm -cpu max -smp 4 -m 4096 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive if=none,id=usbstick,format=qcow2,file="$OVL" \
  -device qemu-xhci,id=xhci -device usb-storage,bus=xhci.0,drive=usbstick \
  -vga none -device virtio-gpu-pci -display none \
  -chardev file,id=ser0,path="$SER" -serial chardev:ser0 \
  -boot menu=off -no-reboot
