#!/bin/bash
# 体验 SceneBoard（合一架构）PC 桌面（最终可用版）。
#
# 关键点：
#  1) 必须用 -device virtio-gpu-gl-pci（3D/virgl），否则 guest 只有 softpipe，画面出不来。
#  2) 必须带 virtio-multitouch-pci：锁屏要「触摸上滑」才能解锁（鼠标拖动不解锁）。
#  3) 镜像里已预置 init 服务 zzkeepawake，持续把熄屏超时改成 86400000ms，
#     抵消 SceneBoard 自己下发的 overrideScreenOffTime(10000)（否则 ~10s 就黑屏/休眠）。
#  4) 启动后 scripts/pc_session.py 会自动通过串口给 guest 注入一次上滑解锁。
#
# 用法：bash out/x86_64_virt/ohos-dbg/scripts/run_pc.sh
# 退出：关掉 GTK 窗口，或另开终端 pkill -9 -f 'qemu-system-x86_64 -[m]achine'
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
IMG=/home/katax/Public/OHOS/out/x86_64_virt/packages/phone/images
mkdir -p "$BASE/run"
pkill -9 -f 'qemu-system-x86_64 -[m]achine' 2>/dev/null
sleep 1
rm -f "$BASE/run/ser.sock" "$BASE/run/qmp_pc.sock" "$BASE/run/pc_ser.log"
setsid python3 "$BASE/scripts/pc_session.py" > "$BASE/run/pc_session.log" 2>&1 < /dev/null &
exec qemu-system-x86_64 -machine q35 -accel kvm -cpu max -smp 4 -m 4096 \
 -kernel "$IMG/bzImage" -initrd "$IMG/ramdisk.img" -vga none \
 -device virtio-gpu-gl-pci,xres=1280,yres=800 -display gtk,gl=on -trace enable=virtio_gpu_cmd_set_scanout -trace enable=virtio_gpu_cmd_res_flush -trace enable=virtio_gpu_cmd_res_create_2d \
 -device virtio-multitouch-pci -device virtio-mouse-pci -device virtio-keyboard-pci \
 -chardev socket,id=ser0,path=$BASE/run/ser.sock,server=on,wait=off -serial chardev:ser0 \
 -netdev user,id=net0,hostfwd=tcp:127.0.0.1:5555-:5555 -device virtio-net-pci,netdev=net0 \
 -drive if=none,id=updater,file=$BASE/dbg/updater.qcow2,format=qcow2 -device virtio-blk-pci,drive=updater,serial=updater \
 -drive if=none,id=system,file=$BASE/dbg/system.qcow2,format=qcow2 -device virtio-blk-pci,drive=system,serial=system \
 -drive if=none,id=vendor,file=$BASE/dbg/vendor.qcow2,format=qcow2 -device virtio-blk-pci,drive=vendor,serial=vendor \
 -drive if=none,id=sys_prod,file=$BASE/dbg/sys_prod.qcow2,format=qcow2 -device virtio-blk-pci,drive=sys_prod,serial=sys_prod \
 -drive if=none,id=chip_prod,file=$BASE/dbg/chip_prod.qcow2,format=qcow2 -device virtio-blk-pci,drive=chip_prod,serial=chip_prod \
 -drive if=none,id=userdata,file=$BASE/dbg/userdata.qcow2,format=qcow2 -device virtio-blk-pci,drive=userdata,serial=userdata \
 -qmp unix:$BASE/run/qmp_pc.sock,server=on,wait=off \
 -append "console=ttyS0,115200 no_console_suspend sn=0123456789 init=/bin/init hardware=virt root=/dev/ram0 rw ohos.required_mount.system=/dev/block/vdb@/usr@ext4@ro,barrier=1@wait,required ohos.required_mount.vendor=/dev/block/vdc@/vendor@ext4@ro,barrier=1@wait,required ohos.required_mount.sys_prod=/dev/block/vdd@/sys_prod@ext4@rw,barrier=1@wait,required ohos.required_mount.chip_prod=/dev/block/vde@/chip_prod@ext4@rw,barrier=1@wait,required ohos.required_mount.data=/dev/block/vdf@/data@ext4@nosuid,nodev,noatime,barrier=1,data=ordered,noauto_da_alloc@wait,reservedsize=104857600"
