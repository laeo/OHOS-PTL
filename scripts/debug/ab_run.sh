#!/bin/bash
# A/B boot + capture orchestrator.  Usage: ab_run.sh <A|B>
# Boots QEMU (serial->file, hdc on tcp 5555), keeps awake, and captures:
#   hilog dumps, RS hidumper (RSTree/client/surface), snapshot_display,
#   QMP screendump, params -- at early/25/45/60/90/120s guest uptime.
LABEL=${1:?usage: ab_run.sh A|B}
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
HDC=/home/katax/.local/deveco/command-line-tools/sdk/default/openharmony/toolchains/hdc
LOG=$BASE/ab_${LABEL}_run.log
: > "$LOG"
log(){ echo "$(date +%T) $*" | tee -a "$LOG"; }

log "=== ab_run $LABEL start ==="

# --- start QEMU (background, lossless serial->file) ---
rm -f "$BASE/run/qmp.sock" "$BASE/run/ser.sock"
nohup setsid bash "$BASE/scripts/launch_hdc_filelog.sh" > "$BASE/ab_${LABEL}_qemu.log" 2>&1 < /dev/null &
QPID=$!
echo "$QPID" > "$BASE/ab_${LABEL}_qemu.pid"
log "qemu started pid=$QPID"

# --- keep-awake (QMP, opens/closes each time) ---
nohup python3 "$BASE/scripts/ab_wake.py" 1200 2.0 > "$BASE/ab_${LABEL}_wake.log" 2>&1 < /dev/null &
WPID=$!
echo "$WPID" > "$BASE/ab_${LABEL}_wake.pid"
log "wake started pid=$WPID"

# --- wait for hdc ---
"$HDC" kill >/dev/null 2>&1
CONNECTED=no
for i in $(seq 1 180); do
  "$HDC" tconn 127.0.0.1:5555 >/dev/null 2>&1
  if "$HDC" shell "echo HDCREADY" 2>/dev/null | grep -q HDCREADY; then CONNECTED=yes; break; fi
  sleep 1
done
log "hdc connected=$CONNECTED after ${i}s"
UP=$("$HDC" shell "cut -d. -f1 /proc/uptime" 2>/dev/null | tr -d '\r')
log "guest uptime at hdc connect: ${UP}s"

# --- anti-suspend + persist logs immediately ---
"$HDC" shell "hilog -w start"        >> "$LOG" 2>&1
"$HDC" shell "power-shell timeout -o 3600000" >> "$LOG" 2>&1
"$HDC" shell "power-shell setmode 602"        >> "$LOG" 2>&1
"$HDC" shell "power-shell wakeup"             >> "$LOG" 2>&1

# --- capture function ---
capture(){
  TAG=$1
  log "--- capture $TAG ---"
  timeout 30 "$HDC" shell "cut -d. -f1 /proc/uptime" 2>/dev/null | tr -d '\r' > "$BASE/ab_${LABEL}_${TAG}_uptime.txt"
  timeout 60 "$HDC" shell "param get const.product.devicetype; param get const.window.multiWindowUIType" > "$BASE/ab_${LABEL}_${TAG}_params.txt" 2>&1
  timeout 90 "$HDC" shell "hidumper -s RenderService -a RSTree"   > "$BASE/ab_${LABEL}_${TAG}_rstree.txt"  2>&1
  timeout 90 "$HDC" shell "hidumper -s RenderService -a client"   > "$BASE/ab_${LABEL}_${TAG}_client.txt"  2>&1
  timeout 90 "$HDC" shell "hidumper -s RenderService -a surface"  > "$BASE/ab_${LABEL}_${TAG}_surface.txt" 2>&1
  timeout 120 "$HDC" shell "hilog -x" > "$BASE/ab_${LABEL}_hl_${TAG}.txt" 2>/dev/null
  timeout 90 "$HDC" shell "snapshot_display -i 0 -f /data/local/tmp/shot_${LABEL}_${TAG}.jpeg; echo RC=\$?" > "$BASE/ab_${LABEL}_${TAG}_snaprc.txt" 2>&1
  timeout 60 "$HDC" shell "hilog -x | grep -aE 'Root node request first frame|RSSurfaceNode::Create|RSDisplayNode::|RSRenderPipelineAgent|RegisterRenderNode|ClientNodeTreeDump|allMainAndLeashSurfaces|OnRemoteDied|CreateNodeAndSurface|SetRSSurfaceNode'" > "$BASE/ab_${LABEL}_grep_${TAG}.txt" 2>&1
  python3 "$BASE/scripts/ab_shot.py" "$BASE/ab_${LABEL}_${TAG}_screen.ppm" > "$BASE/ab_${LABEL}_${TAG}_screen.txt" 2>&1
  log "capture $TAG done $(tr '\n' ' ' < "$BASE/ab_${LABEL}_${TAG}_screen.txt" 2>/dev/null)"
}

# early capture right after connect
capture early

# scheduled captures at guest uptimes
for T in 25 45 60 90 120; do
  for i in $(seq 1 25); do
    U=$("$HDC" shell "cut -d. -f1 /proc/uptime" 2>/dev/null | tr -d '\r')
    case "$U" in ''|*[!0-9]*) ;; *) [ "$U" -ge "$T" ] && break ;; esac
    sleep 2
  done
  capture "t${T}"
done

log "=== ab_run $LABEL done; qemu $QPID still running ==="
