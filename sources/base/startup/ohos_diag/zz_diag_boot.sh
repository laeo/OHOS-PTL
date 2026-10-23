#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 OpenHarmony PC Image Contributors
# zz_diag_boot.sh - one automatic diagnostic dump ~4 minutes after boot.
#
# Started by init from the "post-init" job (see zz_diag.cfg).  Waits until the
# persistent log store (/ohoslog = p6) is really mounted, sleeps to ~240 s of
# uptime so that the desktop / audio / bt / ime stacks have finished coming up,
# then runs the full `ohos-diag`.  Nothing here may ever block the boot.
PATH=/system/bin:/vendor/bin:/bin:/usr/bin:/sbin:/usr/sbin
export PATH
LC_ALL=C
export LC_ALL

WAIT_S=${ZZDIAG_DELAY:-240}
# debug / test override: write a number into either of these files
if [ -r /data/local/tmp/zzdiag_delay ]; then
    v=$(cat /data/local/tmp/zzdiag_delay 2>/dev/null)
    case "$v" in ''|*[!0-9]*) ;; *) WAIT_S=$v ;; esac
fi
if [ -r /ohoslog/zzdiag_delay ]; then
    v=$(cat /ohoslog/zzdiag_delay 2>/dev/null)
    case "$v" in ''|*[!0-9]*) ;; *) WAIT_S=$v ;; esac
fi

kmsg() { printf '%s\n' "$1" > /dev/kmsg 2>/dev/null; }

kmsg "ZZDIAG: boot-trigger armed (delay=${WAIT_S}s)"

# give the persistent store time to appear (part_init mounts p6 -> /ohoslog)
i=0
while [ $i -lt 60 ]; do
    if [ -d /ohoslog ] && [ -w /ohoslog ]; then
        break
    fi
    sleep 1
    i=$((i + 1))
done

# sleep in slices so a slow USB disk can never wedge the service
left=$WAIT_S
while [ "$left" -gt 0 ]; do
    n=30
    [ "$left" -lt 30 ] && n=$left
    sleep "$n"
    left=$((left - n))
done

kmsg "ZZDIAG: boot-trigger firing ohos-diag"
if [ -x /system/bin/ohos-diag ]; then
    out=$(timeout 300 /system/bin/ohos-diag 2>&1)
    echo "$out" > /dev/kmsg 2>/dev/null
    kmsg "ZZDIAG: boot-dump done: $(echo "$out" | tail -n 1)"
else
    kmsg "ZZDIAG: /system/bin/ohos-diag MISSING"
fi
exit 0