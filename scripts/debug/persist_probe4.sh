cd /data/log/hilog
for f in hilog.001.*.gz hilog.002.*.gz; do
  echo "===== $f ====="
  zcat "$f" 2>/dev/null | grep -a -n "SceneBoard" | head -40
done
echo "=== full lines just before SceneBoard failure (time 21:47:02-04) ==="
for f in hilog.*.gz; do
  zcat "$f" 2>/dev/null | grep -a -E "21:47:0[0-5]" | grep -a -iE "BMS|install|profile|scene|parse|syscap|signature|provision" | head -80
done
echo "=== END ==="
