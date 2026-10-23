DB=/data/log/hiview/sys_event_db/BUNDLEMANAGER_UE/BUNDLE_INSTALL_EXCEPTION-1-MINOR-481-0.db
ls -la "$DB"
base64 "$DB" | tr -d '\n' > /data/db.b64
wc -c /data/db.b64
echo "=== END ==="
