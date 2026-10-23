#!/bin/bash
set -u
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/partdisk
DISK=$BASE/media/ohos_part_pc_ptl.img
OVL=$BASE/work/shell_net.qcow2
SER=$BASE/shell_net_serial.log
VARS=$BASE/work/OVMF_VARS_shellnet.fd
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
  -vga none -device virtio-gpu-pci -vnc 127.0.0.1:27 \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:5556-:5555 -device virtio-net-pci,netdev=net0 \
  -chardev file,id=ser0,path="$SER" -serial chardev:ser0 \
  -boot menu=off -no-reboot
