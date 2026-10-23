#!/bin/bash
set -e
IMG=/home/katax/Public/OHOS/out/x86_64_virt/packages/phone/images
DBG=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/dbg
mkdir -p "$DBG"
for part in updater system vendor sys_prod chip_prod userdata; do
  rm -f "$DBG/$part.qcow2"
  qemu-img create -f qcow2 -b "$IMG/$part.img" -F raw "$DBG/$part.qcow2" >/dev/null
  echo "rebuilt $part.qcow2"
done
ls -lh "$DBG"
