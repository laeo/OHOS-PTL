#!/bin/bash
# fix_aira_avc/inject.sh <image> [hap]
#
# 把带「HEVC 屏蔽 + 取流参数改写」的 Aira HAP 注入 pc_ptl 磁盘镜像的 **p2(system)** 分区：
#   1) /system/app/org.aira.browser/Aira.hap          ← 新 HAP（rm + write 原地替换）
#   2) /system/etc/aira_codec_guard.conf             ← 静态标记（版本 + HAP sha256）
#
# 特点
#   * 幂等：重复执行结果一致（rm + write 同一份文件），镜像内文件 sha256 自校验。
#   * 不动 GPT / 不改镜像大小 / 不动 p1(ESP)、p3~p6。
#   * p2 空闲只有 ~24MiB：先 rm 旧 HAP 释放空间再 write（路径/包名/模块名/签名都不变，
#     所以**不需要**改 install_list.json / install_list_capability.json）。
#   * 可选 `--with-diag`：同时把带「HEVC 屏蔽保护」判据的 ohos-diag 装进 /system/bin。
#   * **不会**改 out/x86_64_virt/ohos-dbg/partdisk/media/ohos_part_pc_ptl.img（交付镜像），
#     除非你显式把那个路径当参数传进来（默认拒绝对交付镜像动手）。
set -eu

BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
TASK=$BASE/fix_aira_avc
W=$TASK/work
DELIVERY=$BASE/partdisk/media/ohos_part_pc_ptl.img
DEFAULT_HAP=$TASK/Aira-v3.7.2-x86-codecguard-signed.hap

IMG=${1:-}
shift 2>/dev/null || true
HAP=""
for _a in "$@"; do
    case "$_a" in
        --with-diag) ;;
        *) [ -z "$HAP" ] && HAP="$_a" ;;
    esac
done
HAP=${HAP:-$DEFAULT_HAP}

if [ -z "$IMG" ]; then
    echo "usage: $0 <disk-image> [hap] [--with-diag]"
    echo "  例: $0 $TASK/scratch.img"
    exit 2
fi
[ -f "$IMG" ] || { echo "ERROR: image not found: $IMG"; exit 1; }
[ -f "$HAP" ] || { echo "ERROR: hap not found: $HAP"; exit 1; }

case "$(readlink -f "$IMG")" in
    "$(readlink -f "$DELIVERY")")
        echo "REFUSING: $IMG is the delivery image."
        echo "          交付镜像必须保持原样；请先 cp --sparse 出副本再注入："
        echo "          cp --sparse $DELIVERY $TASK/scratch.img && sgdisk -e $TASK/scratch.img"
        exit 3
        ;;
esac

mkdir -p "$W"
P2_OFF_MB=513           # p2 (system) 起始偏移 = 扇区 1050624 * 512 / 1MiB
P2_LEN_MB=2048          # p2 大小
HAP_PATH=/system/app/org.aira.browser/Aira.hap
CONF_PATH=/system/etc/aira_codec_guard.conf

HAP_SIZE=$(stat -c%s "$HAP")
HAP_SHA=$(sha256sum "$HAP" | cut -d' ' -f1)
GUARD_VERSION=aira-codec-guard-v1

echo "=== image : $IMG"
echo "=== hap   : $HAP"
echo "=== hap size  : $HAP_SIZE bytes"
echo "=== hap sha256: $HAP_SHA"
echo "--- sha256 of image BEFORE: $(sha256sum "$IMG" | cut -d' ' -f1)"

CONF=$W/aira_codec_guard.conf
cat > "$CONF" <<EOF
# Aira 媒体编解码守卫（HEVC 屏蔽 + 取流参数改写）
# 生成方式：fix_aira_avc/inject.sh（幂等）
guard_version=$GUARD_VERSION
bundle=org.aira.browser
hap_path=$HAP_PATH
hap_sha256=$HAP_SHA
hap_size=$HAP_SIZE
EOF

echo "--- extracting p2 ..."
dd if="$IMG" of="$W/inject_p2.img" bs=1M skip=$P2_OFF_MB count=$P2_LEN_MB status=none

# 可选：同时把带「HEVC 屏蔽保护」判据的 ohos-diag 装进镜像（/system/bin/ohos-diag）
DIAG_SRC=/home/katax/Public/OHOS/base/startup/ohos_diag/ohos-diag
DIAG_PATH=/system/bin/ohos-diag
WITH_DIAG=0
for _a in "$@"; do
    [ "$_a" = "--with-diag" ] && WITH_DIAG=1
done

{
    echo "rm $HAP_PATH"
    echo "write $HAP $HAP_PATH"
    echo "rm $CONF_PATH"
    echo "write $CONF $CONF_PATH"
    if [ "$WITH_DIAG" = "1" ]; then
        echo "rm $DIAG_PATH"
        echo "write $DIAG_SRC $DIAG_PATH"
    fi
} | debugfs -w "$W/inject_p2.img" 2>&1 | grep -viE "^debugfs|^\s*$" | sed 's/^/    /' || true

echo "--- e2fsck ..."
e2fsck -f -y "$W/inject_p2.img" > "$W/inject_e2fsck.log" 2>&1 || true
tail -3 "$W/inject_e2fsck.log" | sed 's/^/    /'

echo "--- verifying files inside the image ---"
RC=0
for pair in "$HAP|$HAP_PATH" "$CONF|$CONF_PATH"; do
    SRC="${pair%%|*}"; DST="${pair##*|}"
    TMP="$W/_check.bin"
    rm -f "$TMP"
    debugfs -R "dump $DST $TMP" "$W/inject_p2.img" >/dev/null 2>&1 || true
    if [ ! -f "$TMP" ]; then
        echo "    MISSING in image: $DST"; RC=1; continue
    fi
    A=$(sha256sum "$SRC" | cut -d' ' -f1)
    B=$(sha256sum "$TMP" | cut -d' ' -f1)
    if [ "$A" != "$B" ]; then
        echo "    MISMATCH: $DST ($A != $B)"; RC=1
    else
        echo "    OK: $DST sha256=$A size=$(stat -c%s "$TMP")"
    fi
    rm -f "$TMP"
done
if [ "$WITH_DIAG" = "1" ]; then
    TMP="$W/_check.bin"
    rm -f "$TMP"
    debugfs -R "dump $DIAG_PATH $TMP" "$W/inject_p2.img" >/dev/null 2>&1 || true
    if [ ! -f "$TMP" ]; then
        echo "    MISSING in image: $DIAG_PATH"; RC=1
    elif [ "$(sha256sum "$DIAG_SRC" | cut -d' ' -f1)" != "$(sha256sum "$TMP" | cut -d' ' -f1)" ]; then
        echo "    MISMATCH: $DIAG_PATH"; RC=1
    else
        echo "    OK: $DIAG_PATH sha256=$(sha256sum "$TMP" | cut -d' ' -f1) size=$(stat -c%s "$TMP")"
    fi
    rm -f "$TMP"
fi
[ "$RC" = "0" ] || { echo "ERROR: verification failed"; exit 1; }

echo "--- writing p2 back ..."
dd if="$W/inject_p2.img" of="$IMG" bs=1M seek=$P2_OFF_MB count=$P2_LEN_MB conv=notrunc,fsync status=none

echo "--- sha256 of image AFTER : $(sha256sum "$IMG" | cut -d' ' -f1)"
echo "=== OK: Aira codec guard injected into $IMG (p2 only)"
