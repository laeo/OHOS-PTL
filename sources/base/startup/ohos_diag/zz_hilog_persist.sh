#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 OpenHarmony PC Image Contributors
#
# zz_hilog_persist.sh - make the hilog content that we care about survive on
#                       disk, and make the Bluetooth stack actually log.
#
# WHY
# ---
# On the real machine the diagnostic bundle contained *not a single* Bluetooth
# log line, even though bluetooth_service was running.  Two independent
# reasons:
#
#   1. hilogd keeps a *ring buffer* (a few thousand lines).  On a busy boot
#      the BT messages are pushed out of it long before anybody looks.
#   2. The Bluetooth stack logs at DEBUG level in most of its early code
#      paths, and the default global log level is INFO, so those lines never
#      even reach the buffer.
#
# WHAT
# ---
#   * raise the log level of the Bluetooth hilog *domains* to DEBUG
#       0xD000101  bluetooth frameworks (client side, inner)
#       0xD000102  bluetooth_service  (the stack itself, tag "Bluetooth")
#       0xD000105  bluetooth HDI host service + A2DP audio HAL
#       0xD000100  bluetooth (misc)
#     (only those domains - the global level is NOT changed, so the machine
#      does not drown in logs)
#   * enable hilogd's kmsg storage and switch the domain flow control off
#   * start hilogd *persistence tasks* that continuously write those domains
#     to /data/log/hilog/<name> (rotating, 4 MB x 5 files each)
#   * and, as the robust fallback, *become* a streaming collector for the
#     Bluetooth domains and for the kernel messages and write them to
#     /sys_prod (the partition that survives a power off)
#
# This service never returns on purpose: it is the log collector.
PATH=/system/bin:/vendor/bin:/bin:/usr/bin:/sbin:/usr/sbin
export PATH
LC_ALL=C
export LC_ALL

KMSG=/dev/kmsg
BT_DOMAINS="0xD000100,0xD000101,0xD000102,0xD000105"
AUDIO_DOMAINS="0xD002B87,0xD002B83,0xD002B84,0xD002B8B"
WIFI_DOMAINS="0xD001566"
BT_LOG=/sys_prod/zz_bt_hilog.log
KMSG_LOG=/sys_prod/zz_kmsg_hilog.log
# The BT *domain* filter above only catches the Bluetooth stack itself
# (0xD0001xx).  The lines that tell us whether the *switch* was thrown live
# in the application domains instead (the Settings app, the SceneBoard quick
# settings tile), and those are the ones we were missing.  A content filter
# ("hilog -e <regex>") is domain agnostic, so it catches everything that
# talks about Bluetooth, wherever it comes from.
BT_ALL_LOG=/sys_prod/zz_bt_all.log
BT_ALL_REGEX='bluetooth|BlueTooth|Bluetooth|BT_|bt_vendor|VendorInterface|HciInterface|hdi_adapter|bt_enable|bt_napi|BlueTooth'
PERSIST_REPORT=/sys_prod/zz_hilog_persist.txt

kmsg() {
    printf '<7>ZZHILOG: %s\n' "$1" > "$KMSG" 2>/dev/null
}

have() { command -v "$1" >/dev/null 2>&1; }

# --- 0. wait for hilogd ----------------------------------------------------
i=0
while [ "$i" -lt 120 ]; do
    if have hilog && timeout 5 hilog -x >/dev/null 2>&1; then
        break
    fi
    sleep 1
    i=$((i + 1))
done
if ! have hilog; then
    kmsg "hilog binary not found - nothing to do"
    exit 0
fi
kmsg "hilog is available (after ${i}s)"

# --- 1. raise the log level of the bluetooth domains -----------------------
for d in 0xD000100 0xD000101 0xD000102 0xD000105; do
    if timeout 10 hilog -b D -D "$d" >/dev/null 2>&1; then
        kmsg "domain $d log level -> DEBUG"
    else
        kmsg "could not raise the log level of domain $d"
    fi
done

# --- 2. hilogd kmsg storage + no domain flow control ------------------------
# The domain flow control drops the messages of a domain that produces too
# many lines.  With the BT domains at DEBUG level that is exactly what we do
# not want, so the flow control is switched off (it is a global switch).
timeout 10 hilog -k on >/dev/null 2>&1 && kmsg "hilogd kmsg storage enabled"
timeout 10 hilog -Q domainoff >/dev/null 2>&1 && kmsg "hilog domain flow control disabled"

# --- 3. persistence tasks (rotating files in /data/log/hilog) --------------
# the outcome of every start attempt is kept for the report
mkdir -p /data/local/tmp 2>/dev/null
: > /data/local/tmp/zz_hilog_persist_tasks.txt 2>/dev/null
start_task() {
    _name=$1; shift
    _err=$(timeout 20 hilog -w start -f "$_name" -m none -l 4M -n 5 "$@" 2>&1)
    if [ $? -eq 0 ]; then
        kmsg "persist task '$_name' started"
        echo "persist task '$_name': started" >> /data/local/tmp/zz_hilog_persist_tasks.txt
        return 0
    fi
    kmsg "persist task '$_name' could not be started: $_err"
    echo "persist task '$_name': FAILED - $_err" >> /data/local/tmp/zz_hilog_persist_tasks.txt
    return 1
}

start_task bt_stack -D "$BT_DOMAINS"
start_task audio    -D "$AUDIO_DOMAINS"
start_task wifi     -D "$WIFI_DOMAINS"
start_task kmsg     -t kmsg

# --- 4. report what is running ---------------------------------------------
mkdir -p /data/local/tmp 2>/dev/null
{
    echo "===== persist tasks (started $(date 2>/dev/null)) ====="
    echo "--- the start attempts (with their error messages) ---"
    cat /data/local/tmp/zz_hilog_persist_tasks.txt 2>/dev/null
    echo
    echo "===== hilog -w query ====="
    timeout 10 hilog -w query 2>&1
    echo
    echo "===== /data/log/hilog ====="
    ls -la /data/log/hilog 2>&1
} > /data/local/tmp/zz_hilog_persist.txt 2>/dev/null || true
# the same report on the persistent partition, so that the diagnostic
# collector finds it even when /data is not readable
cp /data/local/tmp/zz_hilog_persist.txt "$PERSIST_REPORT" 2>/dev/null || true

# --- 5. become the streaming collector -------------------------------------
# /sys_prod is the partition that survives a power off, so the Bluetooth log
# is still there after the machine was switched off.
: > "$BT_LOG" 2>/dev/null
: > "$KMSG_LOG" 2>/dev/null
: > "$BT_ALL_LOG" 2>/dev/null

kmsg "zz_hilog_persist: streaming the BT domains into $BT_LOG"
kmsg "zz_hilog_persist: streaming every BT related line into $BT_ALL_LOG"

# the kernel messages in the background (same service, same lifetime)
( while true; do
      timeout 300 hilog -t kmsg >> "$KMSG_LOG" 2>&1
      sleep 2
  done ) &

# the domain agnostic Bluetooth collector: it also catches the application
# side (Settings / SceneBoard) and the HDF host service (blue_host).
( while true; do
      timeout 300 hilog -e "$BT_ALL_REGEX" >> "$BT_ALL_LOG" 2>&1
      sleep 2
  done ) &

while true; do
    timeout 300 hilog -D "$BT_DOMAINS" >> "$BT_LOG" 2>&1
    # cap the file so that a chatty stack cannot fill the partition
    _sz=$(wc -c < "$BT_LOG" 2>/dev/null)
    case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
    if [ "$_sz" -gt 4194304 ]; then
        tail -c 1048576 "$BT_LOG" > "$BT_LOG.tmp" 2>/dev/null \
            && mv "$BT_LOG.tmp" "$BT_LOG" 2>/dev/null
    fi
    _sz=$(wc -c < "$BT_ALL_LOG" 2>/dev/null)
    case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
    if [ "$_sz" -gt 4194304 ]; then
        tail -c 1048576 "$BT_ALL_LOG" > "$BT_ALL_LOG.tmp" 2>/dev/null \
            && mv "$BT_ALL_LOG.tmp" "$BT_ALL_LOG" 2>/dev/null
    fi
    sleep 2
done
