#!/bin/bash
# fix_desktop_layout/inject.sh
#
#   inject.sh <image> [hap]
#
# 把新构建的 PC 产品版 SceneBoard HAP 注入 pc_ptl 磁盘镜像的 **p2(system)** 分区。
#
#   <image> : 目标磁盘镜像（partdisk/media/ohos_part_pc_ptl.img 或 QEMU 用的 scratch.img）
#   <hap>   : 新 HAP（默认用 porting/scb_src 的构建产物）
#
# 关键点
#  * p2 空闲空间只有 ~24MiB，而 HAP 有 ~91MiB —— 直接 write 会失败。
#    这里先 `rm` 旧 HAP（释放 ~91MiB）再 `write`，因此**可以原地替换**，
#    不需要把 HAP 挪到 p3(/vendor)，也不需要改 install_list.json
#    （bundleName / 模块名 / 安装路径都没变）。
#  * 幂等：重复执行得到同样的结果（rm + write 同一份 HAP）。
#  * 不改 GPT、不改镜像大小（交付镜像保持 5.5G 裁剪版；写 U 盘时由
#    partdisk/dd_and_verify.sh 里的 sgdisk -e 负责补 GPT）。
set -eu

BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
TASK=$BASE/fix_desktop_layout
W=$TASK/work
DEFAULT_HAP=$BASE/porting/scb_src/product/pc/build/default/outputs/default/pc_sceneboard-default-signed.hap

IMG=${1:-$BASE/partdisk/media/ohos_part_pc_ptl.img}
HAP=${2:-$DEFAULT_HAP}

[ -f "$IMG" ] || { echo "ERROR: image not found: $IMG"; exit 1; }
[ -f "$HAP" ] || { echo "ERROR: hap not found: $HAP"; exit 1; }

mkdir -p "$W"
P2_OFF_MB=513           # p2 (system) 起始偏移，= 扇区 1050624 * 512 / 1MiB
P2_LEN_MB=2048          # p2 大小
HAP_PATH=/system/app/SceneBoard/SceneBoard.hap

echo "=== image : $IMG"
echo "=== hap   : $HAP"
HAP_SIZE=$(stat -c%s "$HAP")
echo "=== hap size: $HAP_SIZE bytes"
echo "=== hap sha256: $(sha256sum "$HAP" | cut -d' ' -f1)"

echo "--- sha256 of image BEFORE: $(sha256sum "$IMG" | cut -d' ' -f1)"

# 1) 抽出 p2
echo "--- extracting p2 ..."
dd if="$IMG" of="$W/inject_p2.img" bs=1M skip=$P2_OFF_MB count=$P2_LEN_MB status=none

# 2) 替换 HAP（先 rm 再 write）
echo "--- replacing $HAP_PATH ..."
{
  echo "rm $HAP_PATH"
  echo "write $HAP $HAP_PATH"
} | debugfs -w "$W/inject_p2.img" 2>&1 | sed 's/^/    /'

# 3) fsck
echo "--- e2fsck ..."
e2fsck -f -y "$W/inject_p2.img" > "$W/inject_e2fsck.log" 2>&1 || true
tail -3 "$W/inject_e2fsck.log" | sed 's/^/    /'

# 4) 写回镜像
echo "--- writing p2 back ..."
dd if="$W/inject_p2.img" of="$IMG" bs=1M seek=$P2_OFF_MB count=$P2_LEN_MB conv=notrunc,fsync status=none

# 5) 校验：把镜像里的 HAP dump 出来比对 sha256
echo "--- verifying ..."
debugfs -R "dump $HAP_PATH $W/inject_check.hap" "$W/inject_p2.img" >/dev/null 2>&1
CK_SIZE=$(stat -c%s "$W/inject_check.hap")
CK_SHA=$(sha256sum "$W/inject_check.hap" | cut -d' ' -f1)
echo "    in-image hap size: $CK_SIZE"
echo "    in-image hap sha256: $CK_SHA"
if [ "$CK_SHA" != "$(sha256sum "$HAP" | cut -d' ' -f1)" ]; then
  echo "ERROR: hap mismatch after inject"; exit 1
fi
echo "--- sha256 of image AFTER : $(sha256sum "$IMG" | cut -d' ' -f1)"
echo "=== OK: SceneBoard HAP injected into $IMG"
