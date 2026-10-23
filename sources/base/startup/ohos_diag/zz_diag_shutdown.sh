#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 OpenHarmony PC Image Contributors
# zz_diag_shutdown.sh - diagnostic dump triggered by init's "reboot" job.
#
# WHY THIS EXISTS: every shutdown path of the PTL box goes through
#   PowerMgr -> DoRebootExt() -> param ohos.startup.powerctrl="reboot,<cmd>"
#   -> begetd -> reboot plugin
# and every one of those handlers calls `DoJobNow("reboot")` *before* the actual
# reboot/poweroff syscall:
#     base/startup/init/services/modules/reboot/reboot.c:198  (shutdown)
#     base/startup/init/services/modules/reboot/reboot.c:301  (reboot/other)
#     base/startup/init/services/modules/reboot/reboot.c:164  (panic)
# Declaring a job literally named "reboot" in zz_diag.cfg is therefore the
# supported, source-confirmed hook - no binary patching, works for the UI
# power menu, `reboot`, `poweroff` and kernel panic alike.
#
# The dump runs in "quick" mode (short per-command timeouts, no full hilog) so
# it finishes in well under the shutdown window; a watchdog backstop guarantees
# we never hold up the reboot.
PATH=/system/bin:/vendor/bin:/bin:/usr/bin:/sbin:/usr/sbin
export PATH
LC_ALL=C
export LC_ALL

kmsg() { printf '%s\n' "$1" > /dev/kmsg 2>/dev/null; }

reason=""
for p in persist.sys.boot.reason persist.sys.poweroff.reason persist.dfx.eventtype; do
    v=$(param get "$p" 2>/dev/null)
    [ -n "$v" ] && reason="$reason $p=$v"
done
kmsg "ZZDIAG: shutdown-hook firing (reason:$reason)"

# hard backstop: if this script somehow hangs, kill it and continue the reboot
(
    sleep 120
    kmsg "ZZDIAG: shutdown-dump watchdog fired, giving up"
) &
WD=$!

if [ -x /system/bin/ohos-diag ]; then
    out=$(timeout 100 /system/bin/ohos-diag quick 2>&1)
    kmsg "ZZDIAG: shutdown-dump done: $(echo "$out" | tail -n 1)"
else
    kmsg "ZZDIAG: /system/bin/ohos-diag MISSING (shutdown dump skipped)"
fi

kill $WD 2>/dev/null
exit 0