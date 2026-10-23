#!/bin/bash
# run_bootmedia_disk_qemu.sh - smoke-test the boot media from a *writable*
# ext4 disk image (option C: partition/disk media, no ISO, no tmpfs).
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
IMG=/home/katax/Public/OHOS/out/x86_64_virt/packages/phone/images
DISK="${DISK:-$BASE/bootmedia/ohos_disk.img}"
VNC="${VNC:-25}"
mkdir -p "$BASE/run"
pkill -9 -f 'qemu-system-x86_64 -[m]achine' 2>/dev/null
sleep 1
rm -f "$BASE/run/bm_ser.log" "$BASE/run/qmp_bm.sock"
exec qemu-system-x86_64 -machine q35 -accel kvm -cpu max -smp 4 -m 6144 \
  -kernel "$IMG/bzImage" -initrd "$BASE/bootmedia/ramdisk_bootmedia.img" \
  -vga none -device virtio-gpu-gl-pci,xres=1280,yres=720 -display egl-headless,gl=on -vnc 127.0.0.1:${VNC} \
  -device virtio-multitouch-pci -device virtio-mouse-pci -device virtio-keyboard-pci \
  -chardev file,id=ser0,path=$BASE/run/bm_ser.log -serial chardev:ser0 \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:5556-:5555 -device virtio-net-pci,netdev=net0 \
  -drive file="$DISK",format=raw,if=virtio \
  -qmp unix:$BASE/run/qmp_bm.sock,server=on,wait=off \
  -append "console=tty0 console=ttyS0,115200 ignore_loglevel loglevel=7 rdinit=/boot_init root=/dev/ram0 rw sn=0123456789 hardware=virt ohos.boot.hardware=virt ohos.required_mount.system=/dev/block/by-name/system@/usr@ext4@ro,barrier=1@wait,required ohos.required_mount.vendor=/dev/block/by-name/vendor@/vendor@ext4@ro,barrier=1@wait,required ohos.required_mount.sys_prod=/dev/block/by-name/sys_prod@/sys_prod@ext4@rw,barrier=1@wait,required ohos.required_mount.chip_prod=/dev/block/by-name/chip_prod@/chip_prod@ext4@rw,barrier=1@wait,required ohos.required_mount.data=/dev/block/by-name/userdata@/data@ext4@nosuid,nodev,noatime,barrier=1,data=ordered,noauto_da_alloc@wait,reservedsize=104857600"
