#!/bin/bash
# QEMU launch with virtio-gpu-gl (3D: virgl + venus), serial to file, for a quick feasibility probe.
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
IMG=/home/katax/Public/OHOS/out/x86_64_virt/packages/phone/images
mkdir -p "$BASE/run"
exec qemu-system-x86_64 -machine q35 -accel kvm -cpu max -smp 4 -m 4096 \
 -kernel "$IMG/bzImage" -initrd "$IMG/ramdisk.img" -vga none \
 -device virtio-gpu-gl-pci -display gtk,gl=on \
 -device virtio-multitouch-pci -device virtio-keyboard-pci \
 -serial file:$BASE/run/gl_ser.log \
 -netdev user,id=net0,hostfwd=tcp:127.0.0.1:5555-:5555 -device virtio-net-pci,netdev=net0 \
 -drive if=none,id=updater,file=$BASE/dbg/updater.qcow2,format=qcow2 -device virtio-blk-pci,drive=updater,serial=updater \
 -drive if=none,id=system,file=$BASE/dbg/system.qcow2,format=qcow2 -device virtio-blk-pci,drive=system,serial=system \
 -drive if=none,id=vendor,file=$BASE/dbg/vendor.qcow2,format=qcow2 -device virtio-blk-pci,drive=vendor,serial=vendor \
 -drive if=none,id=sys_prod,file=$BASE/dbg/sys_prod.qcow2,format=qcow2 -device virtio-blk-pci,drive=sys_prod,serial=sys_prod \
 -drive if=none,id=chip_prod,file=$BASE/dbg/chip_prod.qcow2,format=qcow2 -device virtio-blk-pci,drive=chip_prod,serial=chip_prod \
 -drive if=none,id=userdata,file=$BASE/dbg/userdata.qcow2,format=qcow2 -device virtio-blk-pci,drive=userdata,serial=userdata \
 -qmp unix:$BASE/run/qmp_gl.sock,server=on,wait=off \
 -append "console=ttyS0,115200 no_console_suspend sn=0123456789 init=/bin/init hardware=virt root=/dev/ram0 rw ohos.required_mount.system=/dev/block/vdb@/usr@ext4@ro,barrier=1@wait,required ohos.required_mount.vendor=/dev/block/vdc@/vendor@ext4@ro,barrier=1@wait,required ohos.required_mount.sys_prod=/dev/block/vdd@/sys_prod@ext4@rw,barrier=1@wait,required ohos.required_mount.chip_prod=/dev/block/vde@/chip_prod@ext4@rw,barrier=1@wait,required ohos.required_mount.data=/dev/block/vdf@/data@ext4@nosuid,nodev,noatime,barrier=1,data=ordered,noauto_da_alloc@wait,reservedsize=104857600"
