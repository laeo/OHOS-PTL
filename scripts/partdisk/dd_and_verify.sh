#!/bin/sh
# 用法: sudo sh dd_and_verify.sh /dev/sdX
#
# 把 pc_ptl 镜像写入 U 盘并修好 GPT。
# 关键约束：镜像里的 GPT 声明 userdata(p6) = 16 GiB（起始 ~3.13 GiB），
# 因此目标盘必须 >= ~19.2 GiB（建议 32GB 及以上）。16GB 盘放不下，会被拒绝。
set -eu

IMG=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/partdisk/media/ohos_part_pc_ptl.img
DEV="${1:-}"
[ -n "$DEV" ] || { echo "用法: sudo sh $0 /dev/sdX   (先 lsblk 认准 U 盘)"; exit 1; }
[ -b "$DEV" ] || { echo "$DEV 不是块设备"; exit 1; }
[ -f "$IMG" ] || { echo "找不到镜像 $IMG"; exit 1; }

# 保护：不能是系统根盘
ROOTSRC=$(findmnt -no SOURCE / 2>/dev/null || true)
ROOTDEV=$(lsblk -no PKNAME "$ROOTSRC" 2>/dev/null || true)
if [ -n "$ROOTDEV" ] && [ "$DEV" = "/dev/$ROOTDEV" ]; then
  echo "拒绝：$DEV 是系统根盘！"; exit 1
fi

# 保护：目标上不能有已挂载分区
MOUNTS=$(lsblk -nlo MOUNTPOINT "$DEV" | grep -v '^$' || true)
if [ -n "$MOUNTS" ]; then
  echo "拒绝：$DEV 上有挂载点，先 umount："; echo "$MOUNTS"; exit 1
fi

# 目标盘容量必须能容纳 p6(16GiB) 起点 + 大小 + 尾部 GPT。
# p6 结束扇区约 40114142（≈19.13 GiB），再加备份 GPT，要求 >= 19.2 GiB。
REQ_BYTES=$(( 40114142 * 512 + 2 * 1024 * 1024 ))
DEVSZ=$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)
REQ_H=$(numfmt --to=iec --suffix=B "$REQ_BYTES" 2>/dev/null || echo "$REQ_BYTES")
DEV_H=$(numfmt --to=iec --suffix=B "$DEVSZ" 2>/dev/null || echo "$DEVSZ")
echo "目标盘容量: $DEV_H (需 >= $REQ_H)"
if [ "$DEVSZ" -lt "$REQ_BYTES" ]; then
  echo "拒绝：$DEV 太小，装不下 16GiB 的 userdata 分区。"
  echo "      请换 >= 32GB 的 U 盘（16GB 盘一定不够）。"
  exit 1
fi

SIZE=$(stat -c%s "$IMG")
echo "镜像 : $IMG"
echo "大小 : $SIZE 字节"
echo "目标 : $DEV"
echo "== 1) 写入 =="
dd if="$IMG" of="$DEV" bs=16M conv=fsync status=progress
sync

echo "== 2) 读回校验 =="
IMG_SHA=$(sha256sum "$IMG" | cut -d' ' -f1)
DEV_SHA=$(head -c "$SIZE" "$DEV" | sha256sum | cut -d' ' -f1)
echo "镜像 sha : $IMG_SHA"
echo "U盘   sha: $DEV_SHA"

if [ "$IMG_SHA" != "$DEV_SHA" ]; then
  echo "== FAIL：U 盘读回与镜像不一致！=="
  echo "这是盘/线/USB 口不可靠的信号。换一支盘或换一个 USB 口，再跑本脚本。"
  exit 2
fi
echo "== PASS：写入正确 =="

echo "== 3) 把备份 GPT 挪到盘末尾 (sgdisk -e) =="
if ! sgdisk -e "$DEV"; then
  echo "ERROR: sgdisk -e 失败。盘太小或 GPT 异常。请换盘/重跑写入。"
  exit 3
fi
sync
command -v partprobe >/dev/null 2>&1 && partprobe "$DEV" 2>/dev/null || true

echo "== 4) GPT 完整性校验 =="
if sgdisk -v "$DEV" 2>&1 | grep -q 'No problems found'; then
  echo "GPT OK: No problems found."
else
  echo "WARN: sgdisk -v 报告问题，请检查下面输出："
  sgdisk -v "$DEV" 2>&1 | tail -15
fi
echo "-- 分区表 --"
sgdisk -p "$DEV" 2>&1 | sed -n '/Number/,$p'

# p6 的结束扇区必须 <= 盘的总扇区数
TOTSEC=$(( DEVSZ / 512 ))
P6END=$(sgdisk -p "$DEV" 2>/dev/null | awk '$1==6{print $3}')
if [ -n "$P6END" ] && [ "$P6END" -le "$TOTSEC" ]; then
  echo "p6(userdata) 结束扇区 $P6END <= 盘总扇区 $TOTSEC : OK"
else
  echo "WARN: p6($P6END) 超出盘($TOTSEC)！GPT 仍有问题，别上机。"
  exit 4
fi

echo "完成。可以拔盘上机（GRUB 菜单选 [0] DEFAULT 或 [1] debug verbose）。"
