cd /data/log/hilog
F=$(ls -t hilog.*.gz 2>/dev/null | head -1)
echo "NEWEST=$F"
zcat "$F" 2>/dev/null | grep -a -iE "sceneboard|SceneBoard" | grep -a -iE "install|parse|privilege|capability|exception" | head -30
echo "=== any parse failures in newest ==="
zcat "$F" 2>/dev/null | grep -a -E "parse haps file failed|not allow use privilege|signature verify failed|OTA Install new" | head -20
echo "=== END ==="
