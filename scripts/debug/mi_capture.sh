#!/bin/bash
# Capture RS/window state for the RS-client-multi-instance experiment.
# Usage: mi_capture.sh <phase> <tag>     e.g. mi_capture.sh baseline t45
PHASE=${1:?phase}
TAG=${2:?tag}
HDC=/home/katax/.local/deveco/command-line-tools/sdk/default/openharmony/toolchains/hdc
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
O=$BASE/mi
mkdir -p "$O"

UP=$("$HDC" shell "cut -d. -f1 /proc/uptime" 2>/dev/null | tr -d '\r')
echo "$UP" > "$O/${PHASE}_${TAG}_uptime.txt"

# params
timeout 60 "$HDC" shell 'for p in persist.rosen.rsclientmultiinstance.enabled const.product.devicetype const.window.multiWindowUIType persist.sceneboard.ispcmode; do echo -n "$p = "; param get $p 2>&1; done' > "$O/${PHASE}_${TAG}_params.txt" 2>&1

# RS dumps
timeout 120 "$HDC" shell "hidumper -s RenderService -a allInfo" > "$O/${PHASE}_${TAG}_allinfo.txt" 2>&1
timeout 90  "$HDC" shell "hidumper -s RenderService -a RSTree"  > "$O/${PHASE}_${TAG}_rstree.txt"  2>&1
timeout 90  "$HDC" shell "hidumper -s RenderService -a client"  > "$O/${PHASE}_${TAG}_client.txt"  2>&1
timeout 60  "$HDC" shell "hidumper -s RenderService -a screen"  > "$O/${PHASE}_${TAG}_screen.txt"  2>&1

# snapshot_display
timeout 60 "$HDC" shell "snapshot_display -i 0 -f /data/local/tmp/mi_${PHASE}_${TAG}.jpeg; echo RC=\$?" > "$O/${PHASE}_${TAG}_snaprc.txt" 2>&1

# hilog ring dump
timeout 120 "$HDC" shell "hilog -x" > "$O/${PHASE}_${TAG}_hilog.txt" 2>/dev/null

# focused grep straight from ring (cheap)
timeout 120 "$HDC" shell "hilog -x | grep -aE 'RSNode::AddChild|RSUIContext|isMultiInstanceOpen|NO_RSUIContext|InitRSUIDirector|CreateRSUIContext|GetRSUIContext|screenNode|ScreenPattern|SetRSNode|multi-instance|multiInstance|RS multi-instance|AttachToDisplay|AddDisplayNodeToTree|RSDisplayNode' " > "$O/${PHASE}_${TAG}_grep.txt" 2>&1

# QMP screendump
python3 "$BASE/scripts/ab_shot.py" "$O/${PHASE}_${TAG}_screen.ppm" > "$O/${PHASE}_${TAG}_fbinfo.txt" 2>&1

# local derived greps from allInfo
{
  echo "===== display/node lines ====="
  grep -aE 'LOGICAL_DISPLAY_NODE|SCREEN_NODE|ChildrenIndex|allMainAndLeashSurfaces|ClientNodeTreeDump|RSUIContextToken|isMultiInstanceOpen|NO_RSUIContext|nodeName' "$O/${PHASE}_${TAG}_allinfo.txt"
} > "$O/${PHASE}_${TAG}_key.txt" 2>&1

echo "PHASE=$PHASE TAG=$TAG up=${UP}s params=[$(tr '\n' '|' < "$O/${PHASE}_${TAG}_params.txt")] fbinfo=[$(tr '\n' ' ' < "$O/${PHASE}_${TAG}_fbinfo.txt")]"
