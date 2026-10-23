#!/bin/bash
# fix_diag/inject.sh
#  * back up the pc_ptl disk image as .zst ONLY (no uncompressed full copy)
#  * inject /system/bin/ohos-diag, /system/bin/zz_diag_{boot,shutdown}.sh and
#    /system/etc/init/zz_diag.cfg into p2 (system)
#  * e2fsck + write p2 back + report new sha256 / free space
#  * NOTE: ramdisk / ESP / p3..p6 / the user's USB stick are NOT touched.
set -eu
ROOT=/home/katax/Public/OHOS
BASE=$ROOT/out/x86_64_virt/ohos-dbg
F=$BASE/fix_diag
DISK=$BASE/partdisk/media/ohos_part_pc_ptl.img
W=$F/work
FILES=$F/files
TAG=${TAG:-diag}

P2_OFF=1050624; P2_LEN=4194304      # sectors (2 GiB, sgdisk -p)
EXPECT_SHA=9fede5bef3fa13a56e237ecb7e846779052b3924baea4064eae8bf4fd8eb48b7

cur=$(sha256sum "$DISK" | cut -d' ' -f1)
echo "current disk sha256: $cur"
if [ "$cur" != "$EXPECT_SHA" ] && [ "${FORCE:-0}" != 1 ]; then
  echo "ABORT: base image is not the expected $EXPECT_SHA (set FORCE=1 to override)"
  exit 1
fi

echo "== free space before =="
dumpe2fs -h "$W/p2.img" 2>/dev/null | grep -E 'Free blocks|Block count' || true

echo "== 1) .zst backup (compressed only) =="
BAK=$BASE/partdisk/media/ohos_part_pc_ptl.pre_${TAG}.img.zst
if [ -f "$BAK" ]; then
  echo "backup already exists, reusing: $BAK"
else
  zstd -19 --long=27 -T4 -q -f "$DISK" -o "$BAK"
  zstd -t "$BAK" && echo "zstd backup verified"
fi
ls -la "$BAK"
sha256sum "$BAK" > "$F/backup_sha256.txt"

echo "== 2) re-extract a pristine p2 =="
rm -f "$W/p2.img"
dd if="$DISK" of="$W/p2.img" bs=512 skip=$P2_OFF count=$P2_LEN status=none

echo "== 3) inject the 4 files =="
{
  for n in /system/bin/ohos-diag /system/bin/zz_diag_boot.sh /system/bin/zz_diag_shutdown.sh; do
    b=$(basename "$n")
    echo "rm $n"
    echo "write $FILES/$b $n"
    echo "set_inode_field $n mode 0100755"
    echo "set_inode_field $n uid 0"
    echo "set_inode_field $n gid 0"
  done
  echo "rm /system/etc/init/zz_diag.cfg"
  echo "write $FILES/zz_diag.cfg /system/etc/init/zz_diag.cfg"
  echo "set_inode_field /system/etc/init/zz_diag.cfg mode 0100644"
  echo "set_inode_field /system/etc/init/zz_diag.cfg uid 0"
  echo "set_inode_field /system/etc/init/zz_diag.cfg gid 0"
} | debugfs -w "$W/p2.img" > "$F/inject_p2.log" 2>&1
grep -iE 'error|not found|failed' "$F/inject_p2.log" && { echo "inject had errors"; } || echo "inject log clean"

echo "== 4) e2fsck =="
e2fsck -f -y "$W/p2.img" > "$F/e2fsck_p2.log" 2>&1 || true
tail -5 "$F/e2fsck_p2.log"

echo "== 5) verify readback inside p2 =="
for p in /system/bin/ohos-diag /system/bin/zz_diag_boot.sh /system/bin/zz_diag_shutdown.sh /system/etc/init/zz_diag.cfg; do
  debugfs -R "stat $p" "$W/p2.img" 2>/dev/null | grep -E 'Size:|Mode:' | tr '\n' ' '
  echo " <- $p"
done
for b in ohos-diag zz_diag_boot.sh zz_diag_shutdown.sh zz_diag.cfg; do
  a=$(sha256sum "$FILES/$b" | cut -d' ' -f1)
  case "$b" in zz_diag.cfg) P=/system/etc/init/zz_diag.cfg;; *) P=/system/bin/$b;; esac
  debugfs -R "dump $P $F/.rb_$b" "$W/p2.img" >/dev/null 2>&1
  c=$(sha256sum "$F/.rb_$b" | cut -d' ' -f1)
  rm -f "$F/.rb_$b"
  [ "$a" = "$c" ] && echo "  $b: sha256 MATCH ($a)" || { echo "  $b: MISMATCH $a != $c"; exit 1; }
done

echo "== 6) write p2 back into the disk image =="
dd if="$W/p2.img" of="$DISK" bs=512 seek=$P2_OFF count=$P2_LEN conv=notrunc,fsync status=none
sync

echo "== 7) result =="
dumpe2fs -h "$W/p2.img" 2>/dev/null | grep -E 'Free blocks|Block count'
NEW=$(sha256sum "$DISK" | cut -d' ' -f1)
SZ=$(stat -c%s "$DISK")
echo "new sha256: $NEW"
echo "size      : $SZ"
{ echo "$NEW"; echo "$SZ"; } > "$F/new_sha.txt"
echo "base_sha  : $cur"
echo "backup    : $BAK"
echo "INJECT_DONE"