D=/data/log/hiview/sys_event_db/BUNDLEMANAGER_UE
for f in "$D/BUNDLE_INSTALL_EXCEPTION-1-MINOR-481-0.db" "$D/BUNDLE_INSTALL-4-MINOR-480-0.db" "$D/BOOT_SCAN_END-4-MINOR-542-0.db" "$D/BOOT_SCAN_START-4-MINOR-395-0.db"; do
  n=$(basename "$f")
  base64 "$f" | tr -d '\n' > /data/$n.b64
  echo "$n $(wc -c < /data/$n.b64)"
done
echo "=== END ==="
