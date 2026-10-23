#!/bin/bash
# ============================================================================
# fix_net_perf/inject.sh <image> [--mesa]
#
# Injects the Wi-Fi link layer fixes, the regulatory database and the
# measurement tooling into the pc_ptl disk image (the partdisk image, NOT the
# raw system.img).
#
#   <image> : target disk image (e.g. out/x86_64_virt/ohos-dbg/fix_net_perf/scratch.img
#             or partdisk/media/ohos_part_pc_ptl.img)
#   --mesa  : additionally inject the rebuilt Mesa 26.2.3 with the optimized
#             virgl row flip (only relevant for the QEMU test bench, the real
#             machine uses iris and never enters that code path)
#
# What is injected:
#
#   p2 (system, 513 MiB / 2048 MiB)
#     /system/lib/firmware/regulatory.db        <- regulatory database, the
#     /system/lib/firmware/regulatory.db.p7s        kernel needs it to be able
#                                                   to apply a real country
#     /system/bin/wifiprobe                     <- link layer diagnostic tool
#     /system/bin/zz_wifi_regdomain.sh          <- init helper (root) that
#     /system/etc/init/zz_wifi_regdomain.cfg       applies the country code
#     /system/lib64/libEGL.so.1.0.0             <- (--mesa) optimized flip
#
#   p3 (vendor, 2561 MiB / 512 MiB)
#     /lib64/libwifi_hal_default.z.so           <- generic nl80211 chip HAL with
#     /lib64/libwifi_driver_client.z.so            the new regulatory domain +
#                                                   power save handling
#
# The script is idempotent (rm + write of the same content) and it verifies
# every file after the injection (sha256 of the in-image copy).
# ============================================================================
set -eu

BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
TASK=$BASE/fix_net_perf
W=$TASK/work
ROOT=/home/katax/Public/OHOS

WITH_MESA=0
IMG=""
for a in "$@"; do
    case "$a" in
        --mesa) WITH_MESA=1 ;;
        -h|--help) echo "usage: $0 <partdisk image> [--mesa]"; exit 0 ;;
        *) IMG="$a" ;;
    esac
done
if [ -z "$IMG" ]; then
    echo "usage: $0 <partdisk image> [--mesa]"
    exit 1
fi
[ -f "$IMG" ] || { echo "ERROR: image not found: $IMG"; exit 1; }

# ---------------------------------------------------------------- sources
REGDB="$ROOT/device/pc/ptl/firmware/regulatory.db"
REGDB7S="$ROOT/device/pc/ptl/firmware/regulatory.db.p7s"
WIFIPROBE="$TASK/tools/wifiprobe"
REGSH="$TASK/files/zz_wifi_regdomain.sh"
REGCFG="$TASK/files/zz_wifi_regdomain.cfg"
HAL_LIB="$ROOT/out/ptl/packages/phone/vendor/lib64/libwifi_hal_default.z.so"
CLIENT_LIB="$ROOT/out/ptl/packages/phone/vendor/lib64/libwifi_driver_client.z.so"

for f in "$REGDB" "$WIFIPROBE" "$REGSH" "$REGCFG" "$HAL_LIB" "$CLIENT_LIB"; do
    [ -f "$f" ] || { echo "ERROR: missing source file: $f"; exit 1; }
done

P2_OFF_MB=513
P2_LEN_MB=2048
P3_OFF_MB=2561
P3_LEN_MB=512

mkdir -p "$W"

echo "=== image : $IMG"
echo "=== sha256 BEFORE: $(sha256sum "$IMG" | cut -d' ' -f1)"

# ------------------------------------------------------------------ p2
echo "--- extracting p2 (system) ..."
dd if="$IMG" of="$W/inject_p2.img" bs=1M skip=$P2_OFF_MB count=$P2_LEN_MB status=none

{
  echo "rm /system/lib/firmware/regulatory.db"
  echo "write $REGDB /system/lib/firmware/regulatory.db"
  echo "rm /system/lib/firmware/regulatory.db.p7s"
  echo "write $REGDB7S /system/lib/firmware/regulatory.db.p7s"
  echo "rm /system/bin/wifiprobe"
  echo "write $WIFIPROBE /system/bin/wifiprobe"
  echo "rm /system/bin/zz_wifi_regdomain.sh"
  echo "write $REGSH /system/bin/zz_wifi_regdomain.sh"
  echo "rm /system/etc/init/zz_wifi_regdomain.cfg"
  echo "write $REGCFG /system/etc/init/zz_wifi_regdomain.cfg"
} > "$W/inject_p2.dbgfs"

if [ "$WITH_MESA" = "1" ]; then
    STAGE=$BASE/mesa_build26/stage-iris
    {
      echo "rm /system/lib64/libEGL.so.1.0.0"
      echo "write $STAGE/libEGL.so.1.0.0 /system/lib64/libEGL.so.1.0.0"
      echo "rm /system/lib64/libGLESv1_CM.so.1.1.0"
      echo "write $STAGE/libGLESv1_CM.so.1.1.0 /system/lib64/libGLESv1_CM.so.1.1.0"
      echo "rm /system/lib64/libGLESv2.so.2.0.0"
      echo "write $STAGE/libGLESv2.so.2.0.0 /system/lib64/libGLESv2.so.2.0.0"
      echo "rm /system/lib64/libgbm.so.1.0.0"
      echo "write $STAGE/libgbm.so.1.0.0 /system/lib64/libgbm.so.1.0.0"
      echo "rm /system/lib64/libgallium-26.2.3.so"
      echo "write $STAGE/libgallium-26.2.3.so /system/lib64/libgallium-26.2.3.so"
    } >> "$W/inject_p2.dbgfs"
fi

debugfs -w -f "$W/inject_p2.dbgfs" "$W/inject_p2.img" 2>&1 | grep -v "^debugfs" | sed 's/^/    /'

echo "--- e2fsck p2 ..."
e2fsck -f -y "$W/inject_p2.img" > "$W/inject_p2_e2fsck.log" 2>&1 || true
tail -2 "$W/inject_p2_e2fsck.log" | sed 's/^/    /'

echo "--- writing p2 back ..."
dd if="$W/inject_p2.img" of="$IMG" bs=1M seek=$P2_OFF_MB count=$P2_LEN_MB conv=notrunc,fsync status=none

# ------------------------------------------------------------------ p3
echo "--- extracting p3 (vendor) ..."
dd if="$IMG" of="$W/inject_p3.img" bs=1M skip=$P3_OFF_MB count=$P3_LEN_MB status=none

{
  echo "rm /lib64/libwifi_hal_default.z.so"
  echo "write $HAL_LIB /lib64/libwifi_hal_default.z.so"
  echo "rm /lib64/libwifi_driver_client.z.so"
  echo "write $CLIENT_LIB /lib64/libwifi_driver_client.z.so"
} > "$W/inject_p3.dbgfs"

debugfs -w -f "$W/inject_p3.dbgfs" "$W/inject_p3.img" 2>&1 | grep -v "^debugfs" | sed 's/^/    /'

echo "--- e2fsck p3 ..."
e2fsck -f -y "$W/inject_p3.img" > "$W/inject_p3_e2fsck.log" 2>&1 || true
tail -2 "$W/inject_p3_e2fsck.log" | sed 's/^/    /'

echo "--- writing p3 back ..."
dd if="$W/inject_p3.img" of="$IMG" bs=1M seek=$P3_OFF_MB count=$P3_LEN_MB conv=notrunc,fsync status=none

# ------------------------------------------------------------------ verify
echo "--- verifying in-image content ---"
verify() { # <partition image> <path> <source file>
    debugfs -R "dump $2 $W/_check.bin" "$1" >/dev/null 2>&1 || {
        echo "    ERROR: cannot dump $2"; return 1; }
    local a b
    a=$(sha256sum "$W/_check.bin" | cut -d' ' -f1)
    b=$(sha256sum "$3" | cut -d' ' -f1)
    rm -f "$W/_check.bin"
    if [ "$a" = "$b" ]; then
        echo "    OK  $2 ($a)"
    else
        echo "    ERROR: $2 mismatch: in-image $a != source $b"; return 1
    fi
}
verify "$W/inject_p2.img" /system/lib/firmware/regulatory.db "$REGDB"
verify "$W/inject_p2.img" /system/lib/firmware/regulatory.db.p7s "$REGDB7S"
verify "$W/inject_p2.img" /system/bin/wifiprobe "$WIFIPROBE"
verify "$W/inject_p2.img" /system/bin/zz_wifi_regdomain.sh "$REGSH"
verify "$W/inject_p2.img" /system/etc/init/zz_wifi_regdomain.cfg "$REGCFG"
verify "$W/inject_p3.img" /lib64/libwifi_hal_default.z.so "$HAL_LIB"
verify "$W/inject_p3.img" /lib64/libwifi_driver_client.z.so "$CLIENT_LIB"

echo "=== sha256 AFTER : $(sha256sum "$IMG" | cut -d' ' -f1)"
echo "=== OK"
