#!/bin/bash
set -u
D=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/partdisk
ESP="$1"
SER="$2"
pkill -9 -x qemu-system-x86 2>/dev/null
sleep 1
cp -f /usr/share/OVMF/OVMF_VARS_4M.fd "$D/work/OVMF_VARS_esp.fd"
rm -f "$SER"
exec qemu-system-x86_64 -machine q35 -accel kvm -cpu max -m 1024 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,unit=1,file="$D/work/OVMF_VARS_esp.fd" \
  -drive if=none,id=usbstick,format=raw,file="$ESP" \
  -device qemu-xhci,id=xhci -device usb-storage,bus=xhci.0,drive=usbstick \
  -vga none -device virtio-gpu-pci -display none \
  -serial "file:$SER" -boot menu=off -no-reboot
