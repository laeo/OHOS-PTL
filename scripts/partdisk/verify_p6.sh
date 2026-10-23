#!/bin/bash
# verify_p6.sh - non-destructively pull the real userdata (p6) out of a QEMU
# overlay and list /data + dump /data/ohos-log/zzpslog.log.  Uses qemu-img
# convert + plain dd (NO loop, NO mount, NO root).
set -u
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/partdisk
OVL="${1:-$BASE/work/stepB_overlay.qcow2}"
W="$BASE/work"
P6_START=6555648      # sector
P6_COUNT=4227072      # sectors (2064 MiB)
P6="$W/p6_verify.raw"
RAW="$W/stepB.raw"

echo "== convert overlay -> raw (sparse) =="
rm -f "$RAW"
qemu-img convert -f qcow2 -O raw -S 1M "$OVL" "$RAW" || { echo "convert failed"; exit 1; }
echo "== carve p6 (bs=512 skip=$P6_START count=$P6_COUNT) =="
rm -f "$P6"
dd if="$RAW" of="$P6" bs=512 skip="$P6_START" count="$P6_COUNT" status=none conv=fsync

echo "== /data listing =="
debugfs -R "ls -l /data" "$P6" 2>/dev/null | head -40
echo "== /data/ohos-log listing =="
debugfs -R "ls -l /data/ohos-log" "$P6" 2>/dev/null | head -20
echo "== zzpslog.log dump =="
rm -f "$W/zzpslog_dump.log"
debugfs -R "dump /data/ohos-log/zzpslog.log $W/zzpslog_dump.log" "$P6" >/dev/null 2>&1
if [ -f "$W/zzpslog_dump.log" ]; then
    echo "zzpslog.log bytes: $(stat -c%s "$W/zzpslog_dump.log")"
    head -5 "$W/zzpslog_dump.log"
else
    echo "zzpslog.log NOT FOUND"
fi
