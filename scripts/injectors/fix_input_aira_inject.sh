#!/bin/bash
# fix_input_aira/inject.sh <image> [--with-aira]
#
# 把本任务的产物注入 pc_ptl 磁盘镜像的 **p2(system)** 分区：
#   1) MMI 修复库（服务端关键事件不丢 + 客户端慢消费者保护 + 延迟埋点）
#        /system/lib64/libmmi-server.z.so
#        /system/lib64/platformsdk/libmmi-client.z.so
#        /system/lib64/platformsdk/libmmi-util.z.so
#   2) （可选 --with-aira）修好「数据同步 → 自建」闪退的 Aira HAP
#        /system/app/org.aira.browser/Aira.hap
#
# 特点
#   * 幂等：重复执行结果一致（rm + write 同一份文件），镜像内文件 sha256 自校验。
#   * 不动 GPT / 不改镜像大小 / 不动 p1(ESP)、p3~p6。
#   * p2 空闲只有 ~24MiB：MMI 三个库先 rm 后 write 原地替换；Aira HAP 体积大，
#     也是先 rm 旧 HAP 释放空间再 write（路径/包名/签名都不变，不需要改 install_list.json）。
set -eu

BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
TASK=$BASE/fix_input_aira
W=$TASK/work
OUT=/home/katax/Public/OHOS/out/ptl/multimodalinput/input

IMG=${1:-}
WITH_AIRA=0
for a in "$@"; do
    [ "$a" = "--with-aira" ] && WITH_AIRA=1
done
[ -n "$IMG" ] || { echo "usage: inject.sh <image> [--with-aira]"; exit 1; }
[ -f "$IMG" ] || { echo "ERROR: image not found: $IMG"; exit 1; }

mkdir -p "$W"
P2_OFF_MB=513           # p2 (system) 起始偏移 = 扇区 1050624 * 512 / 1MiB
P2_LEN_MB=2048          # p2 大小

# 文件列表：<本地文件>|<镜像内路径>
LIST=""
add() { LIST="${LIST}$1|$2
"; }

add "$OUT/libmmi-server.z.so" "/system/lib64/libmmi-server.z.so"
add "$OUT/libmmi-client.z.so" "/system/lib64/platformsdk/libmmi-client.z.so"
add "$OUT/libmmi-util.z.so" "/system/lib64/platformsdk/libmmi-util.z.so"

AIRA_HAP="$TASK/Aira-v3.7.2-x86-selfhost-fix-signed.hap"
if [ "$WITH_AIRA" = "1" ]; then
    [ -f "$AIRA_HAP" ] || { echo "ERROR: aira hap not found: $AIRA_HAP"; exit 1; }
    add "$AIRA_HAP" "/system/app/org.aira.browser/Aira.hap"
fi

echo "=== image : $IMG"
printf '%s' "$LIST" | while IFS='|' read -r SRC DST; do
    [ -n "$SRC" ] || continue
    [ -f "$SRC" ] || { echo "ERROR: source not found: $SRC"; exit 1; }
    echo "    $SRC  ->  $DST  ($(stat -c%s "$SRC") B)"
done

echo "--- extracting p2 ..."
dd if="$IMG" of="$W/inject_p2.img" bs=1M skip=$P2_OFF_MB count=$P2_LEN_MB status=none

# 预装 Aira 需要特权扩展授权条目，否则 BMS 会以 8519888
# ("not allow use privilege extension") 拒绝预装 —— 顺带补上（幂等）。
if [ "$WITH_AIRA" = "1" ]; then
    echo "--- patching install_list_capability.json (grant privilege extension to org.aira.browser) ---"
    CAP="$W/install_list_capability.json"
    debugfs -R "dump /system/etc/app/install_list_capability.json $CAP" "$W/inject_p2.img" >/dev/null 2>&1 || true
    if [ -f "$CAP" ]; then
        python3 - "$CAP" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
apps = d.get('install_list', [])
sig = "8E93863FC32EE238060BF69A9B37E2608FFFB21F93C862DD511CBAC9F30024B5"
if not any(a.get('bundleName') == 'org.aira.browser' for a in apps):
    apps.append({
        "bundleName": "org.aira.browser",
        "runningResourcesApply": False,
        "associatedWakeUp": False,
        "app_signature": [sig],
        "allowCommonEvent": [],
        "allowAppUsePrivilegeExtension": True
    })
    d['install_list'] = apps
    json.dump(d, open(p, 'w'), indent=4)
    print("    added org.aira.browser capability entry")
else:
    print("    (capability list not found, skipped)")
PY
        {
            echo "rm /system/etc/app/install_list_capability.json"
            echo "write $CAP /system/etc/app/install_list_capability.json"
        } | debugfs -w "$W/inject_p2.img" 2>&1 | grep -viE "^debugfs|^\s*$" | sed 's/^/    /' || true
    fi
fi

echo "--- replacing files in p2 ..."
{
    printf '%s' "$LIST" | while IFS='|' read -r SRC DST; do
        [ -n "$SRC" ] || continue
        echo "rm $DST"
        echo "write $SRC $DST"
    done
} | debugfs -w "$W/inject_p2.img" 2>&1 | grep -viE "^debugfs|^\s*$" | sed 's/^/    /' || true

echo "--- e2fsck ..."
e2fsck -f -y "$W/inject_p2.img" > "$W/inject_e2fsck.log" 2>&1 || true
tail -3 "$W/inject_e2fsck.log" | sed 's/^/    /'

echo "--- verifying files inside the image ---"
RC=0
while IFS='|' read -r SRC DST; do
    [ -n "$SRC" ] || continue
    TMP="$W/_check.bin"
    rm -f "$TMP"
    debugfs -R "dump $DST $TMP" "$W/inject_p2.img" >/dev/null 2>&1 || true
    if [ ! -f "$TMP" ]; then
        echo "    MISSING in image: $DST"; RC=1; continue
    fi
    A=$(sha256sum "$SRC" | cut -d' ' -f1)
    B=$(sha256sum "$TMP" | cut -d' ' -f1)
    if [ "$A" != "$B" ]; then
        echo "    MISMATCH: $DST  ($A != $B)"; RC=1
    else
        echo "    OK: $DST  sha256=$A  size=$(stat -c%s "$TMP")"
    fi
    rm -f "$TMP"
done <<EOF
$LIST
EOF
[ "$RC" = "0" ] || { echo "ERROR: verification failed"; exit 1; }

echo "--- writing p2 back ..."
dd if="$W/inject_p2.img" of="$IMG" bs=1M seek=$P2_OFF_MB count=$P2_LEN_MB conv=notrunc,fsync status=none

echo "=== OK: injected into $IMG"
