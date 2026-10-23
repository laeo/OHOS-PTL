#!/bin/bash
# Inject rebuilt shared libraries into system.img (debugfs).
# Note: debugfs cannot overwrite existing files, so rm first.
# After this, run e2fsck and recreate the system.qcow2 overlay.
set -e
BASE=/home/katax/Public/OHOS/out/x86_64_virt
IMG=$BASE/packages/phone/images/system.img
OUT=$BASE
{
  echo "rm /system/lib64/libwms.z.so"
  echo "write $OUT/window/window_manager/libwms.z.so /system/lib64/libwms.z.so"
  echo "rm /system/lib64/libmmi-server.z.so"
  echo "write $OUT/multimodalinput/input/libmmi-server.z.so /system/lib64/libmmi-server.z.so"
  echo "rm /system/lib64/libmmi-client.z.so"
  echo "write $OUT/multimodalinput/input/libmmi-client.z.so /system/lib64/libmmi-client.z.so"
} | debugfs -w "$IMG"
echo "inject done"
