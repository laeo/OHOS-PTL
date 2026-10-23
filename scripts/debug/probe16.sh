DB=/data/log/hiview/sys_event_db/BUNDLEMANAGER_UE/BUNDLE_INSTALL_EXCEPTION-1-MINOR-481-0.db
echo "=== count of system/app paths in exception db ==="
strings "$DB" | grep -ac "^/system/app"
echo "=== all exception paths ==="
strings "$DB" | grep -a "^/system/app"
echo "=== BMS key events ==="
find /data/log/hiview/sys_event_db/BUNDLEMANAGER_UE -type f | head
echo "=== END ==="
