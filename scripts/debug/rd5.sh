{
for f in /data/log/hilog/hilog.*.gz; do
  echo "=== $f ==="
  zcat "$f" 2>/dev/null | grep -a -iE "sceneboard|SceneBoard" | head -25
done
} > /data/res6.txt 2>&1
echo DONE_RD5
