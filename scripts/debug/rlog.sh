#!/bin/sh
hilog -x > /data/hl2.txt 2>&1
echo "TOTAL:"; wc -l /data/hl2.txt
echo "=== SCENEBOARD/SESSION ==="
grep -aiE "sceneboard|SceneSession|session_manager|SceneBoard|RootScene|WindowScene" /data/hl2.txt | tail -40
echo "=== RS DRAW ==="
grep -aiE "C01406|C01407|C01408" /data/hl2.txt | grep -aiE "Draw|ProcessNode|processNode|frame|Commit|Layer|SurfaceNode|RCD|Composer" | tail -40
echo "=== END ==="
