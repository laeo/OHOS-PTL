#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 OpenHarmony PC Image Contributors
#
# zz_dmesg_boot.sh - capture the FULL kernel ring buffer as early as possible.
#
# WHY
# ---
# The diagnostic bundle used to contain a `dmesg` dump that was taken ~1000 s
# after boot, i.e. only the *tail* of the kernel ring buffer.  Every message
# the kernel emitted while probing the hardware (SOF/HDA, btintel, iwlwifi,
# xe) was long gone - and those are exactly the messages that explain
# "no audio card", "bluetooth does not open" and "wifi is slow".
#
# WHAT
# ---
# init starts this service with start-mode "boot", i.e. right after the
# pre-init job has mounted /system, /vendor, /sys_prod and /data and *before*
# post-fs / post-fs-data / the normal-mode services (samgr, appspawn, audio,
# bluetooth, wifi ...).  That is the earliest point at which /system exists and
# therefore the earliest point at which the ring buffer can be dumped.
#
# The complete ring buffer is written to
#   /sys_prod/dmesg_boot.log          primary: separate ext4 partition (p4),
#                                     survives poweroff AND power loss
#   /data/dmesg_boot.log              survives a reboot
#   /data/local/tmp/dmesg_boot.log    volatile but always present
#   /ohoslog/ptl-log/dmesg_boot.log   when the persistent log store exists
#
# Snapshots are additionally taken at +15 s, +60 s, +180 s and +300 s so that
# (a) the early messages are never lost to a ring-buffer wrap and (b) the
# state at a later time can be compared against the boot-time state.
#
# The script must never wedge the boot: every step is bounded and every
# failure is non-fatal.
PATH=/system/bin:/vendor/bin:/bin:/usr/bin:/sbin:/usr/sbin
export PATH
LC_ALL=C
export LC_ALL

KMSG=/dev/kmsg
MAX_BYTES=4194304          # 4 MiB per snapshot

kmsg() {
    printf '<7>ZZDMESG: %s\n' "$1" > "$KMSG" 2>/dev/null
}

uptime_s() {
    cut -d' ' -f1 /proc/uptime 2>/dev/null
}

# --- the set of directories we try to write to -------------------------------
# /sys_prod  : separate ext4 partition, rw, survives poweroff  (primary)
# /data      : userdata, rw, wiped on poweroff
# /ohoslog   : persistent log store (only in the DATA=tmpfs boot mode)
DIRS="/sys_prod /data /ohoslog/ptl-log /data/local/tmp"

wait_writable() {
    _d=$1
    _i=0
    while [ "$_i" -lt 30 ]; do
        [ -d "$_d" ] && [ -w "$_d" ] && return 0
        sleep 1
        _i=$((_i + 1))
    done
    return 1
}

# snapshot <label>
#   writes dmesg_boot_<label>.log + an index entry into every writable dir
snapshot() {
    _label=$1
    _up=$(uptime_s)
    [ -n "$_up" ] || _up=0
    for _d in $DIRS; do
        wait_writable "$_d" || continue
        # /data/local/tmp may not exist yet at boot stage (post-fs-data has
        # not run) - try to create it, but never fail because of it.
        [ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null
        [ -d "$_d" ] || continue
        _f="$_d/dmesg_boot_${_label}.log"
        {
            echo "===== ZZDMESG snapshot: $_label  (uptime=${_up}s) ====="
            echo "===== cmdline: $(cat /proc/cmdline 2>/dev/null) ====="
            echo "===== log_buf_len: $(cat /proc/sys/kernel/log_buf_len 2>/dev/null) ====="
            echo "===== dmesg_restrict: $(cat /proc/sys/kernel/dmesg_restrict 2>/dev/null) ====="
            echo
            dmesg 2>/dev/null | head -c "$MAX_BYTES"
        } > "$_f" 2>/dev/null
        _sz=$(wc -c < "$_f" 2>/dev/null)
        # index entry
        {
            echo "snapshot=$_label uptime_s=$_up bytes=${_sz:-0} file=dmesg_boot_${_label}.log"
        } >> "$_d/dmesg_boot_index.txt" 2>/dev/null
    done
    kmsg "snapshot $_label at uptime=${_up}s"
}

# --- 0. announce ------------------------------------------------------------
kmsg "zz_dmesg_boot starting (uptime=$(uptime_s)s)"

# --- 1. the EARLIEST possible dump -----------------------------------------
# This is the important one: it still contains the initcall-time probe
# messages of every driver.
snapshot t0

# The "interesting" early messages, extracted once so that a human does not
# have to grep 4 MiB of kernel log by hand.
for _d in $DIRS; do
    [ -d "$_d" ] && [ -w "$_d" ] || continue
    {
        echo "===== early kernel messages by subsystem ====="
        echo
        echo "--- SOF / HDA / ALSA (audio) ---"
        dmesg 2>/dev/null | grep -aiE 'sof|hda|alc269|snd|asoc|audio|ehdaudio' | head -300
        echo
        echo "--- Bluetooth (btintel / hci / usb) ---"
        dmesg 2>/dev/null | grep -aiE 'bluetooth|btintel|btusb|hci|ibt-' | head -200
        echo
        echo "--- Wi-Fi (iwlwifi / cfg80211 / mac80211) ---"
        dmesg 2>/dev/null | grep -aiE 'iwlwifi|cfg80211|mac80211|regulatory|wlan' | head -200
        echo
        echo "--- GPU / display (xe / i915 / drm) ---"
        dmesg 2>/dev/null | grep -aiE '\bxe\b|i915|drm|gpu' | head -200
        echo
        echo "--- probe failures / deferred probe / errors ---"
        dmesg 2>/dev/null | grep -aiE 'probe|defer|-ENODEV|-EPROBE|fail' | head -300
    } > "$_d/dmesg_boot_subsystems.log" 2>/dev/null
done
kmsg "subsystem extract written"

# --- 2. keep snapshots so nothing is lost ----------------------------------
# 15 s, 60 s, 180 s, 300 s.  Each snapshot is a complete ring buffer, so the
# earliest one always contains the boot messages even if the buffer wraps.
sleep 15
snapshot t15
sleep 45
snapshot t60
sleep 120
snapshot t180
sleep 120
snapshot t300

# --- 3. index / metadata ----------------------------------------------------
for _d in $DIRS; do
    [ -d "$_d" ] && [ -w "$_d" ] || continue
    {
        echo "===== ZZDMESG boot log index ====="
        echo "captured by : /system/bin/zz_dmesg_boot.sh (init service, start-mode=boot)"
        echo "final uptime: $(uptime_s)s"
        echo "cmdline     : $(cat /proc/cmdline 2>/dev/null)"
        echo "log_buf_len : $(cat /proc/sys/kernel/log_buf_len 2>/dev/null)"
        echo "dmesg_restrict: $(cat /proc/sys/kernel/dmesg_restrict 2>/dev/null)"
        echo
        echo "--- files ---"
        ls -la "$_d"/dmesg_boot_* 2>/dev/null
        echo
        echo "--- snapshots ---"
        cat "$_d/dmesg_boot_index.txt" 2>/dev/null
        echo
        echo "--- modules loaded at capture time ---"
        cat /proc/modules 2>/dev/null
    } > "$_d/dmesg_boot_meta.txt" 2>/dev/null
done

kmsg "zz_dmesg_boot done"
exit 0
