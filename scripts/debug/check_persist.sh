cd /data/log/hilog
ls -la
echo "=== search all persisted for sceneboard install ==="
for f in hilog.*.gz; do
  zcat "$f" 2>/dev/null | grep -a -E "SceneBoard|sceneboard" | grep -a -iE "install|parse|privilege|capability" | head -20
done
echo "=== recent parse failures across all ==="
for f in hilog.*.gz; do
  zcat "$f" 2>/dev/null | grep -a "parse haps file failed" | tail -5
done
echo "=== END ==="
