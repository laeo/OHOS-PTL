#!/bin/bash
# run_bootmedia_qemu.sh - smoke-test the boot-media ISO in QEMU (UEFI/OVMF).
# Boots the ISO as a CD-ROM, no OHOS data disks, serial -> log file.
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
ISO="${ISO:-$BASE/bootmedia/ohos-pc-virt.iso}"
OVMF="${OVMF:-/usr/share/ovmf/OVMF.fd}"
VNC="${VNC:-25}"
mkdir -p "$BASE/run"
pkill -9 -f 'qemu-system-x86_64 -[m]achine' 2>/dev/null
sleep 1
rm -f "$BASE/run/bm_ser.log" "$BASE/run/qmp_bm.sock"
exec qemu-system-x86_64 -machine q35 -accel kvm -cpu max -smp 4 -m 6144 \
  -bios "$OVMF" -boot order=d,menu=off \
  -cdrom "$ISO" \
  -vga none -device virtio-gpu-gl-pci,xres=1280,yres=720 -display egl-headless,gl=on -vnc 127.0.0.1:${VNC} \
  -device virtio-multitouch-pci -device virtio-mouse-pci -device virtio-keyboard-pci \
  -chardev file,id=ser0,path=$BASE/run/bm_ser.log -serial chardev:ser0 \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:5556-:5555 -device virtio-net-pci,netdev=net0 \
  -qmp unix:$BASE/run/qmp_bm.sock,server=on,wait=off \
  -no-reboot
