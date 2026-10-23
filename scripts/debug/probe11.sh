echo "=== Install System app errors ==="
grep -a "Install System app" /data/h5.txt | head -30
echo "=== BMS error lines ==="
grep -aE "C01120/BMS|BMS_TAG|BundleMgr" /data/h5.txt | grep -aE " E | W " | head -40
echo "=== disk free ==="
df -h /data /system 2>&1
echo "=== exception file ==="
find /data -iname "*exception*" 2>/dev/null | head
grep -rl "SceneBoard" /data/service/el1/public/bms 2>/dev/null | head
echo "=== END ==="
