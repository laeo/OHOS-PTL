cd /data/log/hilog
echo "=== search all gz for scene/install error ==="
for f in hilog.*.gz; do
  echo "--- $f ---"
  zcat "$f" 2>/dev/null | grep -a -iE "SceneBoard|Install System app|PreBundleInstall|DEVICE_TYPE|not supported|syscap" | head -30
done
echo "=== END ==="
