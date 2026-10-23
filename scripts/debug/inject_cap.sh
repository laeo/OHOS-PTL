#!/bin/bash
IMG=/home/katax/Public/OHOS/out/x86_64_virt/packages/phone/images/system.img
OBJ=/home/katax/Public/OHOS/out/x86_64_virt/obj/vendor/ohemu/virt/preinstall-config
{
  echo "rm /system/etc/app/install_list_capability.json"
  echo "write $OBJ/install_list_capability.json /system/etc/app/install_list_capability.json"
  echo "rm /system/etc/app/install_list.json"
  echo "write $OBJ/install_list.json /system/etc/app/install_list.json"
} | debugfs -w "$IMG"
echo "INJECT_DONE rc=$?"
