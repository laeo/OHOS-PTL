#!/bin/bash
# fix_browser_avc/inject.sh
#
#   inject.sh <disk-image> [hap]
#
# 把新构建的（HEVC 屏蔽 + 取流参数改写）Browser.hap 注入 pc_ptl 磁盘镜像的
# **p2(system)** 分区，替换 `/system/app/com.ohos.browser/Browser.hap`。
#
#   <disk-image> : 目标磁盘镜像（**必填**，避免误改交付镜像
#                  partdisk/media/ohos_part_pc_ptl.img）
#   <hap>        : 新 HAP（默认 fix_browser_avc/Browser.hap）
#
# 关键点
#  * p2 空闲空间紧张：先 `rm` 旧 HAP 再 `write`（原地替换，路径/包名/模块名不变，
#    因此**不需要**改 install_list.json / install_list_capability.json）。
#  * 幂等：重复执行结果一致（rm + write 同一份 HAP）。
#  * 只动 p2，GPT / 其它分区 / 镜像大小均不变。
set -eu

BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
TASK=$BASE/fix_browser_avc
W=$TASK/work
DEFAULT_HAP=$TASK/Browser.hap

IMG=${1:-}
HAP=${2:-$DEFAULT_HAP}

if [ -z "$IMG" ]; then
  echo "usage: $0 <disk-image> [hap]"
  echo "  例: $0 $BASE/work/pcptl_scratch.img"
  exit 2
fi
[ -f "$IMG" ] || { echo "ERROR: image not found: $IMG"; exit 1; }
[ -f "$HAP" ] || { echo "ERROR: hap not found: $HAP"; exit 1; }

mkdir -p "$W"
P2_OFF_MB=513           # p2 (system) 起始偏移 = 扇区 1050624 * 512 / 1MiB
P2_LEN_MB=2048          # p2 大小
HAP_PATH=/system/app/com.ohos.browser/Browser.hap

echo "=== image : $IMG"
echo "=== hap   : $HAP"
HAP_SIZE=$(stat -c%s "$HAP")
HAP_SHA=$(sha256sum "$HAP" | cut -d' ' -f1)
echo "=== hap size : $HAP_SIZE bytes"
echo "=== hap sha256: $HAP_SHA"
echo "--- sha256 of image BEFORE: $(sha256sum "$IMG" | cut -d' ' -f1)"

echo "--- extracting p2 ..."
dd if="$IMG" of="$W/inject_p2.img" bs=1M skip=$P2_OFF_MB count=$P2_LEN_MB status=none

echo "--- replacing $HAP_PATH (rm + write) ..."
{
  echo "rm $HAP_PATH"
  echo "write $HAP $HAP_PATH"
} | debugfs -w "$W/inject_p2.img" 2>&1 | sed 's/^/    /'

echo "--- e2fsck ..."
e2fsck -f -y "$W/inject_p2.img" > "$W/inject_e2fsck.log" 2>&1 || true
tail -3 "$W/inject_e2fsck.log" | sed 's/^/    /'

echo "--- writing p2 back ..."
dd if="$W/inject_p2.img" of="$IMG" bs=1M seek=$P2_OFF_MB count=$P2_LEN_MB conv=notrunc,fsync status=none

echo "--- verifying ..."
debugfs -R "dump $HAP_PATH $W/inject_check.hap" "$W/inject_p2.img" >/dev/null 2>&1
CK_SIZE=$(stat -c%s "$W/inject_check.hap")
CK_SHA=$(sha256sum "$W/inject_check.hap" | cut -d' ' -f1)
echo "    in-image hap size  : $CK_SIZE"
echo "    in-image hap sha256: $CK_SHA"
if [ "$CK_SHA" != "$HAP_SHA" ]; then
  echo "ERROR: hap mismatch after inject"; exit 1
fi
echo "--- sha256 of image AFTER : $(sha256sum "$IMG" | cut -d' ' -f1)"
echo "=== OK: Browser.hap injected into $IMG (p2 only)"
