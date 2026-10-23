cd /data/log/hilog
for f in hilog.*.gz; do
  echo "--- $f ---"
  zcat "$f" 2>/dev/null | grep -a -E "g_parseResult|ObtainOverlayType|bad profile|TransformTo|ToInnerBundleInfo|ParserAtomic|native so|ark native|moduleType|syscap failed|API_VERSION|api version|newApiVersion|compatible" | head -40
done
echo "=== SceneBoard context ==="
for f in hilog.*.gz; do
  zcat "$f" 2>/dev/null | grep -a -B3 -A3 "SceneBoard is not found" | head -30
done
echo "=== END ==="
