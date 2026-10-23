cd /data/log/hilog
for f in hilog.*.gz; do
  base64 "$f" | tr -d '\n' > /data/$f.b64
  echo "$f $(wc -c < /data/$f.b64)"
done
echo "=== END ==="
