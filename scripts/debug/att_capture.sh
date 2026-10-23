#!/bin/bash
# Capture a timeline sample for the SceneBoard attach experiment.
# Usage: att_capture.sh <tag>
TAG=${1:?tag}
HDC=/home/katax/.local/deveco/command-line-tools/sdk/default/openharmony/toolchains/hdc
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
O=$BASE/att
mkdir -p "$O"

UP=$("$HDC" shell "cut -d. -f1 /proc/uptime" 2>/dev/null | tr -d '\r')
echo "$UP" > "$O/${TAG}_uptime.txt"

# 1. RS allInfo (display/leash tree, client tree)
timeout 90 "$HDC" shell "hidumper -s RenderService -a allInfo" > "$O/${TAG}_allinfo.txt" 2>&1
# 2. RS screen power
timeout 60 "$HDC" shell "hidumper -s RenderService -a screen" > "$O/${TAG}_screen.txt" 2>&1
# 3. snapshot_display exit code
timeout 60 "$HDC" shell "snapshot_display -i 0 -f /data/local/tmp/${TAG}.jpeg; echo RC=\$?" > "$O/${TAG}_snaprc.txt" 2>&1
# 4. hilog ring dump
timeout 90 "$HDC" shell "hilog -x" > "$O/${TAG}_hilog.txt" 2>/dev/null
# 5. focused hilog grep
timeout 90 "$HDC" shell "hilog -x | grep -aE 'AttachToDisplay|AttachToWindowContainer|attach to display|attach to the tree|SCBScreen|SCBScreen-Temp|screenInfo_.id|SetDisplayNodeScreenId|SetDisplayNodeRSScreenId|OneScreenConnect|OnScreenChangeForPC|OnScreenChangeDefault|GetOrCreatePhysicalScreenSession|renderSession|ConnectToRenderService|GetScreenInfoById|SendRequest|screen_session|ScreenPowerState|AttachToWindowScene|AddDisplayNodeToTree|SetWindowContainer|ScreenSession'" > "$O/${TAG}_grep.txt" 2>&1
# 6. QMP screendump + extrema
python3 "$BASE/scripts/ab_shot.py" "$BASE/att/${TAG}_screen.ppm" > "$O/${TAG}_fbinfo.txt" 2>&1

echo "TAG=$TAG up=${UP}s fbinfo=$(tr '\n' ' ' < "$O/${TAG}_fbinfo.txt")"
