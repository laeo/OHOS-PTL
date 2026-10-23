cd /data/log/hilog
echo "=== files ==="
ls -la
echo "=== search newest for To applicationInfo/innerModuleInfo failed ==="
for f in $(ls -t hilog.*.gz 2>/dev/null | head -3); do
  echo "--- $f ---"
  zcat "$f" 2>/dev/null | grep -a -E "To applicationInfo failed|To innerModuleInfo failed|g_parseResult|bundle name or module name is invalid|bad profile|TransformTo|ParserAtomic|StartWindow|startWindowIcon|iconId" | head -40
done
echo "=== search SceneBoard parse ==="
for f in $(ls -t hilog.*.gz 2>/dev/null | head -3); do
  zcat "$f" 2>/dev/null | grep -a -B2 -A6 "SceneBoard" | head -50
done
echo "=== END ==="
