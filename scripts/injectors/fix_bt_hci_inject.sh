#!/bin/bash
# =============================================================================
# fix_bt_hci / inject.sh  --  inject the Bluetooth fix into a pc_ptl
#                            partition disk (ohos_part_pc_ptl.img)
#
# Usage:  bash inject.sh <image> [workdir]
#
# What it does (idempotent):
#   p2 (system)  /system/lib64/libbtstack.z.so
#       -> bluetooth host stack with the fixed HDI-adapter dlopen name
#          (hdi_wrapper.c: x86_64 asked for "libbluetooth_hdi_adapter.so",
#           a file that does not exist in any OHOS image -> the whole BT
#           stack aborted in HCI_Initialize() and the vendor HAL was never
#           dlopen()ed)
#
#   p3 (vendor)  /lib64/libbt_vendor.z.so
#       -> the BT vendor HAL (Linux AF_BLUETOOTH raw HCI transport)
#
#   p3 (vendor)  /etc/init/hdf_devhost.cfg
#       -> regenerated from vendor/ohemu/virt/hdf_config/uhdf/hdf.hcs so
#          that the blue_host service really gets caps ["NET_ADMIN","NET_RAW"].
#          Without NET_RAW the kernel refuses every HCI command on the RAW
#          channel (hci_sock.c: hci_sendmsg) and narrows SO_HCI_FILTER down
#          to events only, so no scan result would ever arrive.
#
# The script never touches the delivered image unless you point it at one;
# always test on a copy (cp --sparse).
# =============================================================================
set -euo pipefail

REPO=${REPO:-/home/katax/Public/OHOS}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=${2:-$HERE/work}

IMG=${1:?usage: inject.sh <image> [workdir]}
[ -f "$IMG" ] || { echo "ERROR: no such image: $IMG" >&2; exit 1; }
mkdir -p "$WORK"

# --- inputs -----------------------------------------------------------------
NEW_BTSTACK=$REPO/out/ptl/communication/bluetooth_service/libbtstack.z.so
NEW_VENDOR=$HERE/work/libbt_vendor.z.so
HCGEN=$REPO/out/ptl/obj/drivers/hdf_core/framework/tools/hc-gen/hc-gen
HCS_SRC=$REPO/vendor/ohemu/virt/hdf_config/uhdf/hdf.hcs

for f in "$NEW_BTSTACK" "$NEW_VENDOR" "$HCGEN" "$HCS_SRC"; do
    [ -e "$f" ] || { echo "ERROR: missing input: $f" >&2; exit 1; }
done

# --- partition geometry -----------------------------------------------------
# NOTE: sgdisk -i is read-only; the warnings about the broken backup GPT of
# this image are expected (the delivered disk was truncated at some point) and
# are not caused by this script.
part_first_sector() { sgdisk -i "$1" "$2" 2>/dev/null | grep 'First sector:' | sed 's/.*First sector: *//; s/ .*//'; }
part_size_sectors() { sgdisk -i "$1" "$2" 2>/dev/null | grep 'Partition size:' | sed 's/.*Partition size: *//; s/ .*//'; }

P2_START=$(part_first_sector 2 "$IMG")
P2_SIZE=$(part_size_sectors 2 "$IMG")
P3_START=$(part_first_sector 3 "$IMG")
P3_SIZE=$(part_size_sectors 3 "$IMG")
[ -n "$P2_START" ] && [ -n "$P2_SIZE" ] && [ -n "$P3_START" ] && [ -n "$P3_SIZE" ] || {
    echo "ERROR: could not read partition geometry" >&2; exit 1; }
echo "== partition geometry =="
echo "   p2 system : start=$P2_START sectors ($((P2_SIZE/2048)) MiB)"
echo "   p3 vendor : start=$P3_START sectors ($((P3_SIZE/2048)) MiB)"

SHA_BEFORE=$(sha256sum "$IMG" | awk '{print $1}')
echo "== image sha256 before: $SHA_BEFORE"

# --- extract ----------------------------------------------------------------
echo "== extracting partitions =="
dd if="$IMG" of="$WORK/p2_system.img" bs=512 skip="$P2_START" count="$P2_SIZE" status=none
dd if="$IMG" of="$WORK/p3_vendor.img" bs=512 skip="$P3_START" count="$P3_SIZE" status=none

# --- regenerate the HDF host service cfg ------------------------------------
echo "== regenerating hdf_devhost.cfg from $HCS_SRC =="
mkdir -p "$WORK/cfg"
"$HCGEN" -s -o "$WORK/cfg/" "$HCS_SRC"
CFG=$WORK/cfg/.cfg
[ -f "$CFG" ] || { echo "ERROR: hc-gen produced no cfg" >&2; exit 1; }
grep -q '"NET_RAW"' "$CFG" || { echo "ERROR: regenerated cfg has no NET_RAW" >&2; exit 1; }
grep -n -A 6 '"blue_host"' "$CFG" | sed 's/^/   /'

# --- inject -----------------------------------------------------------------
# Byte level idempotency: if the partition already carries exactly the files
# we are going to write, we do not touch the image at all (ext4 metadata
# would otherwise change on every run and the image sha would keep moving).
rm -f "$WORK/cur_btstack.so" "$WORK/cur_vendor.so" "$WORK/cur_cfg.cfg"
debugfs -R "dump /system/lib64/libbtstack.z.so $WORK/cur_btstack.so" "$WORK/p2_system.img" >/dev/null 2>&1 || true
debugfs -R "dump /lib64/libbt_vendor.z.so $WORK/cur_vendor.so"         "$WORK/p3_vendor.img" >/dev/null 2>&1 || true
debugfs -R "dump /etc/init/hdf_devhost.cfg $WORK/cur_cfg.cfg"         "$WORK/p3_vendor.img" >/dev/null 2>&1 || true

NEED_WRITE=1
if cmp -s "$NEW_BTSTACK" "$WORK/cur_btstack.so" \
   && cmp -s "$NEW_VENDOR"  "$WORK/cur_vendor.so" \
   && cmp -s "$CFG"         "$WORK/cur_cfg.cfg"; then
    NEED_WRITE=0
fi

if [ "$NEED_WRITE" = "0" ]; then
    echo "== image already carries the fixed files - nothing to do =="
else
echo "== injecting libbtstack.z.so into p2 =="
{
    echo "rm /system/lib64/libbtstack.z.so"
    echo "write $NEW_BTSTACK /system/lib64/libbtstack.z.so"
} | debugfs -w "$WORK/p2_system.img" >/dev/null 2>&1

echo "== injecting libbt_vendor.z.so + hdf_devhost.cfg into p3 =="
{
    echo "rm /lib64/libbt_vendor.z.so"
    echo "write $NEW_VENDOR /lib64/libbt_vendor.z.so"
    echo "rm /etc/init/hdf_devhost.cfg"
    echo "write $CFG /etc/init/hdf_devhost.cfg"
} | debugfs -w "$WORK/p3_vendor.img" >/dev/null 2>&1

# --- fsck -------------------------------------------------------------------
echo "== e2fsck =="
e2fsck -f -y "$WORK/p2_system.img"  > "$WORK/e2fsck_p2.log" 2>&1 || true
e2fsck -f -y "$WORK/p3_vendor.img"  > "$WORK/e2fsck_p3.log" 2>&1 || true
tail -2 "$WORK/e2fsck_p2.log" | sed 's/^/   p2: /'
tail -2 "$WORK/e2fsck_p3.log" | sed 's/^/   p3: /'

# --- write back -------------------------------------------------------------
echo "== writing partitions back =="
dd if="$WORK/p2_system.img" of="$IMG" bs=512 seek="$P2_START" count="$P2_SIZE" conv=notrunc status=none
dd if="$WORK/p3_vendor.img" of="$IMG" bs=512 seek="$P3_START" count="$P3_SIZE" conv=notrunc status=none
fi

# --- verify -----------------------------------------------------------------
echo "== verifying =="
dd if="$IMG" of="$WORK/verify_p2.img" bs=512 skip="$P2_START" count="$P2_SIZE" status=none
dd if="$IMG" of="$WORK/verify_p3.img" bs=512 skip="$P3_START" count="$P3_SIZE" status=none
debugfs -R "dump /system/lib64/libbtstack.z.so $WORK/verify_btstack.so" "$WORK/verify_p2.img" >/dev/null 2>&1
debugfs -R "dump /lib64/libbt_vendor.z.so $WORK/verify_vendor.so"     "$WORK/verify_p3.img" >/dev/null 2>&1
debugfs -R "dump /etc/init/hdf_devhost.cfg $WORK/verify_cfg.cfg"     "$WORK/verify_p3.img" >/dev/null 2>&1

check() { # <name> <expected> <actual>
    if cmp -s "$2" "$3"; then echo "   OK   $1  ($(stat -c %s "$3") B)"; else echo "   FAIL $1"; return 1; fi
}
rc=0
check "libbtstack.z.so"  "$NEW_BTSTACK" "$WORK/verify_btstack.so" || rc=1
check "libbt_vendor.z.so" "$NEW_VENDOR" "$WORK/verify_vendor.so"    || rc=1
check "hdf_devhost.cfg"  "$CFG"         "$WORK/verify_cfg.cfg"      || rc=1
grep -q '"NET_RAW"' "$WORK/verify_cfg.cfg" && echo "   OK   blue_host caps contain NET_RAW" || { echo "   FAIL NET_RAW"; rc=1; }

SHA_AFTER=$(sha256sum "$IMG" | awk '{print $1}')
echo "== image sha256 after : $SHA_AFTER"
if [ "$SHA_BEFORE" = "$SHA_AFTER" ]; then
    echo "   note: image unchanged (already injected?)"
else
    echo "   image changed as expected"
fi
exit $rc
