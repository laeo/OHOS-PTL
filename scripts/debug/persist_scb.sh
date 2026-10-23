cd /data/log/hilog
ls -la
echo "=== SceneBoard install lines (all files) ==="
for f in $(ls -t hilog.*.gz 2>/dev/null); do
  zcat "$f" 2>/dev/null | grep -a -iE "scene" | grep -a -iE "install|parse|privilege|capability|boot" | head -20
done
echo "=== privilege / parse errors ==="
for f in $(ls -t hilog.*.gz 2>/dev/null); do
  zcat "$f" 2>/dev/null | grep -a -E "not allow use privilege|parse haps file failed|8519888|OTA Install new" | head -20
done
echo "=== END ==="
