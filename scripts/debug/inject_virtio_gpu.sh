#!/bin/bash
# Inject the virgl gallium DRI driver (virtio_gpu_dri.so) into system.img /system/lib64.
# debugfs cannot overwrite: rm first, then write.
set -e
IMG=/home/katax/Public/OHOS/out/x86_64_virt/packages/phone/images/system.img
SRC=/home/katax/Public/OHOS/device/qemu/common/virt_full/hardware/gpu/x86_64/virtio_gpu_dri.so
DST=/system/lib64/virtio_gpu_dri.so
{
  echo "rm $DST"
  echo "write $SRC $DST"
} | debugfs -w "$IMG"
echo "--- verify ---"
debugfs -R "stat $DST" "$IMG"
