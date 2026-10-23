DB=/data/log/hiview/sys_event_db/BUNDLEMANAGER_UE/BUNDLE_INSTALL_EXCEPTION-1-MINOR-481-0.db
OFF=$(grep -abo "SceneBoard" "$DB" | head -1 | cut -d: -f1)
echo "OFF=$OFF"
if [ -n "$OFF" ]; then
  START=$((OFF-16))
  dd if="$DB" bs=1 skip=$START count=160 2>/dev/null | od -A d -t x1 -v
fi
echo "=== all error codes (search little-endian pattern) ==="
strings -n 3 "$DB" | grep -aE "^/system/app" | head -40
echo "=== END ==="
