{
echo "SCENE=$(ls /data/app/el1/bundle/public | grep -ci scene)"
ls /data/log/hilog/ 2>/dev/null
for f in /data/log/hilog/hilog.*.gz; do
  echo "--- $f ---"
  zcat "$f" 2>/dev/null | grep -a -iE "scene|SceneBoard" | grep -a -iE "install|parse|privilege|capability|scan|bundle" | head -15
done
} > /data/res4.txt 2>&1
echo DONE_RD
