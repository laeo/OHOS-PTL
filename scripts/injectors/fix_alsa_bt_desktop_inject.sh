#!/bin/bash
# inject.sh — apply the fix_alsa_bt_desktop payload to p2 (system) and p3 (vendor)
# of partdisk/media/ohos_part_pc_ptl.img.  Creates a .zst backup first (no
# uncompressed whole-disk backup is ever kept).
set -euo pipefail
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
F=$BASE/fix_alsa_bt_desktop
W=$F/work
IMG=$BASE/partdisk/media/ohos_part_pc_ptl.img
BK=$BASE/partdisk/media/ohos_part_pc_ptl.pre_alsa_bt_desktop.img.zst
P1_SECT=2048;   P1_CNT=1048576
P2_SECT=1050624; P2_CNT=4194304
P3_SECT=5244928; P3_CNT=1048576
P4_SECT=6293504; P4_CNT=131072
P5_SECT=6424576; P5_CNT=131072

mkdir -p "$W"
pkill -9 -f 'qemu-system-x86_64 -[m]achine' 2>/dev/null || true

if [ ! -f "$BK" ]; then
  echo "[1/9] zstd backup -> $(basename "$BK")"
  zstd -q -T8 -1 -o "$BK" "$IMG"
  zstd -l "$BK" | tail -2
fi

echo "[2/9] extract p2/p3"
dd if="$IMG" of="$W/p2.img" bs=512 skip=$P2_SECT count=$P2_CNT status=none
dd if="$IMG" of="$W/p3.img" bs=512 skip=$P3_SECT count=$P3_CNT status=none

echo "[3/9] stage payload"
rm -rf "$F/stage/p2"; mkdir -p "$F/stage/p2/system/lib64" "$F/stage/p2/system/etc/audio/alsa/share" \
                           "$F/stage/p2/system/bin" "$F/stage/p2/system/etc" "$F/stage/p2/system/etc/init"
cp "$F/inject/libasound.so"            "$F/stage/p2/system/lib64/libasound.so"
cp -a "$F/stage/alsacnf/."             "$F/stage/p2/system/etc/audio/alsa/share/"
cp "$F/files/zz_audiotest"             "$F/stage/p2/system/bin/zz_audiotest"
cp "$F/files/zz_audioup.sh"            "$F/stage/p2/system/bin/zz_audioup.sh"
cp "$F/files/zz_audio.cfg"             "$F/stage/p2/system/etc/init/zz_audio.cfg"
cp "$F/files/zz_btbring.sh"            "$F/stage/p2/system/bin/zz_btbring.sh"
cp "$F/files/zz_imageid.sh"            "$F/stage/p2/system/bin/zz_imageid.sh"
cp "$F/files/ohos-diag.new"            "$F/stage/p2/system/bin/ohos-diag"
cp "$F/files/zz_diag_boot.sh.new"      "$F/stage/p2/system/bin/zz_diag_boot.sh"
chmod 755 "$F/stage/p2/system/bin/zz_audiotest" "$F/stage/p2/system/bin/zz_imageid.sh" \
          "$F/stage/p2/system/bin/ohos-diag" "$F/stage/p2/system/bin/zz_diag_boot.sh" \
          "$F/stage/p2/system/bin/zz_audioup.sh" "$F/stage/p2/system/bin/zz_btbring.sh"
chmod 644 "$F/stage/p2/system/etc/init/zz_audio.cfg"
chmod 644 "$F/stage/p2/system/lib64/libasound.so"
find "$F/stage/p2/system/etc/audio/alsa/share" -type f -exec chmod 644 {} +
find "$F/stage/p2/system/etc/audio/alsa/share" -type d -exec chmod 755 {} +

echo "[4/9] debugfs write p2"
python3 "$F/work/mk_dbgfs.py" --img "$W/p2.img" --root "$F/stage/p2" --tag "" \
        --log "$W/inject_p2.dbgfs"
python3 "$F/work/mk_dbgfs.py" --img "$W/p3.img" --root "$F/stage/p3" --tag "" \
        --log "$W/inject_p3.dbgfs"

echo "[5/9] e2fsck"
e2fsck -f -y "$W/p2.img" > "$W/e2fsck_p2.log" 2>&1 || true
e2fsck -f -y "$W/p3.img" > "$W/e2fsck_p3.log" 2>&1 || true
tail -2 "$W/e2fsck_p2.log"; tail -2 "$W/e2fsck_p3.log"

echo "[6/9] dd back"
dd if="$W/p2.img" of="$IMG" bs=512 seek=$P2_SECT count=$P2_CNT conv=notrunc status=none
dd if="$W/p3.img" of="$IMG" bs=512 seek=$P3_SECT count=$P3_CNT conv=notrunc status=none

echo "[7/9] partition hashes (p1/p3/p4/p5) + p2 key-file manifest"
P1_SHA=$(dd if="$IMG" bs=512 skip=$P1_SECT count=$P1_CNT status=none | sha256sum | cut -d' ' -f1)
P3_SHA=$(sha256sum "$W/p3.img" | cut -d' ' -f1)
P4_SHA=$(dd if="$IMG" bs=512 skip=$P4_SECT count=$P4_CNT status=none | sha256sum | cut -d' ' -f1)
P5_SHA=$(dd if="$IMG" bs=512 skip=$P5_SECT count=$P5_CNT status=none | sha256sum | cut -d' ' -f1)
echo "p1=$P1_SHA"; echo "p3=$P3_SHA"

# rebuild the manifest from what is now really inside p2 (paths as seen on device)
rm -f "$W/p2_manifest.txt"; : > "$W/p2_manifest.txt"
mkdir -p "$W/mnt"
for k in system/bin/aplay system/bin/amixer system/bin/speaker-test \
         system/lib64/libasound.so system/etc/audio/alsa/share/alsa.conf \
         system/etc/audio/alsa/share/smixer.conf \
         system/etc/audio/alsa/share/cards/HDA-Intel.conf \
         system/bin/zz_audiotest system/bin/zz_audioup.sh \
         system/etc/init/zz_audio.cfg system/bin/zz_btbring.sh \
         system/bin/zz_imageid.sh system/bin/ohos-diag \
         system/bin/zz_diag_boot.sh system/app/SceneBoard/SceneBoard.hap \
         system/app/Terminal/Terminal.hap system/app/org.aira.browser/Aira.hap \
         system/app/com.ohos.rimeime/RimeIme.hap system/app/com.ohos.settings/Settings.hap \
         system/bin/ohosshd system/bin/sudo \
         system/lib64/platformsdk/librender_service_base.z.so \
         system/lib64/libcursor_drawing_adapter.z.so \
         system/lib64/librender_service.z.so system/lib64/platformsdk/libmmi-util.z.so ; do
    mkdir -p "$W/mnt/$(dirname "$k")"
    if debugfs -R "dump /$k $W/mnt/$k" "$W/p2.img" >/dev/null 2>&1; then
        printf '%s  /%s\n' "$(sha256sum "$W/mnt/$k" | cut -d' ' -f1)" "$k" >> "$W/p2_manifest.txt"
    else
        printf 'MISSING  /%s\n' "$k" >> "$W/p2_manifest.txt"
    fi
done
cp "$W/p2_manifest.txt" "$F/evidence/p2_manifest.txt" 2>/dev/null || true
P2_KEY=$(sha256sum "$W/p2_manifest.txt" | cut -d' ' -f1)
echo "p2_keyfiles=$P2_KEY"

echo "[8/9] write identity stamp + refreshed build id into p2"
TAG="pc_ptl-alsa_bt_desktop-$(date -u +%Y%m%d-%H%M%SZ)"
cat > "$F/ohos-image-id" <<EOF
# pc_ptl image identity stamp (fix_alsa_bt_desktop)
# The legacy /system/etc/ohos_build_id kept reporting BUILD_ID=20261004-030120
# long after the image had been re-injected dozens of times, which is how we
# lost whole diagnostic rounds.  This stamp is content based: the partition
# hashes and P2_KEYFILES_SHA256 can be recomputed on the device with
#   /system/bin/zz_imageid.sh verify
IMAGE_TAG=$TAG
BUILT_FOR=pc_ptl x86_64 2in1 OpenHarmony-7.0 linux-7.2
INJECTED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ESP_PART_SHA256=$P1_SHA
VENDOR_PART_SHA256=$P3_SHA
SYS_PROD_PART_SHA256=$P4_SHA
CHIP_PROD_PART_SHA256=$P5_SHA
P2_KEYFILES_SHA256=$P2_KEY
P2_KEYFILES_LIST=/system/etc/ohos-image-id.manifest
BASE_IMAGE_SHA256=2582616e7aac5bef9220e2863a19d1f6173ca1920c2c17fcde671b2c7ef9eacc
EOF
cp "$F/ohos-image-id" "$F/stage/p2/system/etc/ohos-image-id"
cp "$W/p2_manifest.txt" "$F/stage/p2/system/etc/ohos-image-id.manifest"
cat > "$F/stage/p2/system/etc/ohos_build_id" <<EOF
BUILD_ID=$TAG
BUILD_TIME_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HARDWARE=pc_ptl
IMAGE_STAMP=/system/etc/ohos-image-id
NOTE=regenerated by fix_alsa_bt_desktop; the previous values (20261004-030120-d60f9a93)
NOTE=described the tmpfs_images build only and had been stale for many rounds.
BASE_IMAGE_SHA256=2582616e7aac5bef9220e2863a19d1f6173ca1920c2c17fcde671b2c7ef9eacc
EOF
rm -f "$W/p2_manifest.txt"
{
  echo "rm /system/etc/ohos-image-id"
  echo "write $F/stage/p2/system/etc/ohos-image-id /system/etc/ohos-image-id"
  echo "rm /system/etc/ohos-image-id.manifest"
  echo "write $F/stage/p2/system/etc/ohos-image-id.manifest /system/etc/ohos-image-id.manifest"
  echo "rm /system/etc/ohos_build_id"
  echo "write $F/stage/p2/system/etc/ohos_build_id /system/etc/ohos_build_id"
} > "$W/stamp.dbgfs"
debugfs -w -f "$W/stamp.dbgfs" "$W/p2.img" > "$W/inject_stamp.log" 2>&1
e2fsck -f -y "$W/p2.img" > "$W/e2fsck_p2b.log" 2>&1 || true
dd if="$W/p2.img" of="$IMG" bs=512 seek=$P2_SECT count=$P2_CNT conv=notrunc status=none

echo "[9/9] final"
sha256sum "$IMG" | tee "$F/new_sha256.txt"
ls -la "$IMG"
df -h /home/katax | tail -1