#!/bin/bash
# Inject rebuilt RS libs into system.img. debugfs cannot overwrite -> rm first.
set -e
BASE=/home/katax/Public/OHOS/out/x86_64_virt
IMG=$BASE/packages/phone/images/system.img
G=$BASE/graphic/graphic_2d
{
  echo "rm /system/lib64/librender_service.z.so"
  echo "write $G/librender_service.z.so /system/lib64/librender_service.z.so"
  echo "rm /system/lib64/platformsdk/librender_service_base.z.so"
  echo "write $G/librender_service_base.z.so /system/lib64/platformsdk/librender_service_base.z.so"
} | debugfs -w "$IMG"
echo "inject_rs done"
