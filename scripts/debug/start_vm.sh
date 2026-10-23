#!/bin/bash
# 自己启动 QEMU x86_64_virt 诊断实例。
#
# 用法：bash out/x86_64_virt/ohos-dbg/scripts/start_vm.sh
# 前台运行；Ctrl-C 停止。所有文件都在项目 out/ 下（不写 /tmp）。
#
# 连接：VNC 127.0.0.1:24（Remmina 填 "127.0.0.1:24"，别填 5924）
# 串口：unix socket $BASE/run/ser.sock
# QMP ：unix socket $BASE/run/qmp.sock

set -e
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
IMG=/home/katax/Public/OHOS/out/x86_64_virt/packages/phone/images
mkdir -p "$BASE/run" "$BASE/dbg"

# 可选：重建 system/qcow2 overlay（改了 system.img 后需要）。
# 默认不重建，用现有 overlay。
if [ "$1" = "--fresh-system" ]; then
  rm -f "$BASE/dbg/system.qcow2"
  qemu-img create -f qcow2 -b "$IMG/system.img" -F raw "$BASE/dbg/system.qcow2" >/dev/null
  echo "recreated $BASE/dbg/system.qcow2"
fi

rm -f "$BASE/run/ser.sock" "$BASE/run/qmp.sock"

exec qemu-system-x86_64 -machine q35 -accel kvm -cpu max -smp 4 -m 4096 \
 -kernel "$IMG/bzImage" -initrd "$IMG/ramdisk.img" -vga none \
 -device virtio-gpu-pci -vnc 127.0.0.1:24 \
 -device virtio-multitouch-pci -device virtio-keyboard-pci \
 -chardev socket,id=ser0,path=$BASE/run/ser.sock,server=on,wait=off -serial chardev:ser0 \
 -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
 -drive if=none,id=updater,file=$BASE/dbg/updater.qcow2,format=qcow2 -device virtio-blk-pci,drive=updater,serial=updater \
 -drive if=none,id=system,file=$BASE/dbg/system.qcow2,format=qcow2 -device virtio-blk-pci,drive=system,serial=system \
 -drive if=none,id=vendor,file=$BASE/dbg/vendor.qcow2,format=qcow2 -device virtio-blk-pci,drive=vendor,serial=vendor \
 -drive if=none,id=sys_prod,file=$BASE/dbg/sys_prod.qcow2,format=qcow2 -device virtio-blk-pci,drive=sys_prod,serial=sys_prod \
 -drive if=none,id=chip_prod,file=$BASE/dbg/chip_prod.qcow2,format=qcow2 -device virtio-blk-pci,drive=chip_prod,serial=chip_prod \
 -drive if=none,id=userdata,file=$BASE/dbg/userdata.qcow2,format=qcow2 -device virtio-blk-pci,drive=userdata,serial=userdata \
 -qmp unix:$BASE/run/qmp.sock,server=on,wait=off \
 -append "console=ttyS0,115200 sn=0123456789 init=/bin/init hardware=virt root=/dev/ram0 rw ohos.required_mount.system=/dev/block/vdb@/usr@ext4@ro,barrier=1@wait,required ohos.required_mount.vendor=/dev/block/vdc@/vendor@ext4@ro,barrier=1@wait,required ohos.required_mount.sys_prod=/dev/block/vdd@/sys_prod@ext4@rw,barrier=1@wait,required ohos.required_mount.chip_prod=/dev/block/vde@/chip_prod@ext4@rw,barrier=1@wait,required ohos.required_mount.data=/dev/block/vdf@/data@ext4@nosuid,nodev,noatime,barrier=1,data=ordered,noauto_da_alloc@wait,reservedsize=104857600"
