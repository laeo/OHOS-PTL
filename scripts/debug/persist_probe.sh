echo "=== persisted hilog ==="
ls -la /data/log/hilog 2>&1
echo "=== find BMS install error ==="
cd /data/log/hilog 2>/dev/null && for f in *; do echo "--- $f ---"; done
echo "=== grep across persisted ==="
grep -r -a -l "SceneBoard" /data/log/hilog 2>/dev/null | head
echo "=== grep Install System app error ==="
grep -r -a "Install System app" /data/log/hilog 2>/dev/null | tail -20
echo "=== END ==="
