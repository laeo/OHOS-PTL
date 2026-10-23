#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 OpenHarmony PC Image Contributors
#
# zz_perf.sh - CPU frequency policy for the PC build.
#
# Why this exists
# ---------------
# On this platform (Intel Panther Lake, family 6 model 0xCC) the kernel runs
# intel_pstate in ACTIVE mode.  In active mode the cpufreq core offers only the
# two pseudo governors "performance" and "powersave" (cpufreq.c:847 hardcodes
# that list when the driver has no .target callback), and the frequency is
# picked by the hardware HWP engine according to the EPP value.
#
# The stock configuration is EPP=balance_performance, which lets the HWP engine
# keep the cores at the 400 MHz floor for a long time after an idle period.
# Every UI interaction therefore has to wait for the hardware to ramp up, which
# is exactly the "the whole system feels sluggish" symptom.
#
# What this script does
# ---------------------
# 1. governor  -> performance  (CPUFREQ_POLICY_PERFORMANCE, so the driver
#                                  pins the HWP request to max_perf_ratio)
# 2. EPP        -> performance   (energy_performance_preference)
# 3. no_turbo   -> 0             (keep turbo available)
# 4. min_perf_pct/max_perf_pct -> 100 (no artificial ceiling)
#
# Everything is best effort: on a kernel without intel_pstate the sysfs files
# simply do not exist and the script reports that instead of failing.
#
# The result is written to /data/local/tmp/zz_perf_result.txt so it can be
# collected by ohos-diag and judged on the real device.

PATH=/system/bin:/vendor/bin:/bin:/usr/bin:/sbin:/usr/sbin
export PATH
LC_ALL=C
export LC_ALL

OUT=/data/local/tmp/zz_perf_result.txt
mkdir -p /data/local/tmp 2>/dev/null

log() { printf '%s\n' "$*" >> "$OUT" 2>/dev/null; printf '%s\n' "$*" > /dev/kmsg 2>/dev/null; }

log "=== zz_perf start $(date 2>/dev/null) ==="

# --- 1. intel_pstate global knobs -------------------------------------------
# /sys/devices/system/cpu/intel_pstate/{no_turbo,min_perf_pct,max_perf_pct}
PSTATE=/sys/devices/system/cpu/intel_pstate
if [ -d "$PSTATE" ]; then
    for kv in "no_turbo 0" "min_perf_pct 100" "max_perf_pct 100"; do
        # shellcheck disable=SC2086
        set -- $kv
        f="$PSTATE/$1"
        if [ -w "$f" ]; then
            if echo "$2" > "$f" 2>/dev/null; then
                log "ok   $f = $(cat "$f" 2>/dev/null)"
            else
                log "FAIL $f (write $2 failed)"
            fi
        else
            log "skip $f (not writable / not present)"
        fi
    done
else
    log "skip $PSTATE (intel_pstate not present)"
fi

# --- 2. per-policy governor + EPP ------------------------------------------
# Each policy is one CPU (or one core-type group); on a hybrid CPU the max
# frequency differs per group, so every policy has to be handled separately.
for d in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$d" ] || continue
    name=$(basename "$d")

    gov="$d/scaling_governor"
    if [ -w "$gov" ]; then
        if echo "performance" > "$gov" 2>/dev/null; then
            log "ok   $name governor = $(cat "$gov" 2>/dev/null)"
        else
            log "FAIL $name governor (write performance failed)"
        fi
    else
        log "skip $name governor (not writable)"
    fi

    epp="$d/energy_performance_preference"
    if [ -w "$epp" ]; then
        if echo "performance" > "$epp" 2>/dev/null; then
            log "ok   $name EPP = $(cat "$epp" 2>/dev/null)"
        else
            log "FAIL $name EPP (write performance failed)"
        fi
    fi

    # Record the state that the real machine should be judged on.
    for r in scaling_cur_freq scaling_min_freq scaling_max_freq scaling_driver; do
        [ -r "$d/$r" ] && log "info $name $r = $(cat "$d/$r" 2>/dev/null)"
    done
done

# --- 3. verify -------------------------------------------------------------
ok=0
bad=0
for d in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$d" ] || continue
    g=$(cat "$d/scaling_governor" 2>/dev/null)
    if [ "$g" = "performance" ]; then
        ok=$((ok + 1))
    else
        bad=$((bad + 1))
        log "WARN $(basename "$d") governor is '$g', expected 'performance'"
    fi
done
log "=== zz_perf done: performance=$ok other=$bad ==="
exit 0
