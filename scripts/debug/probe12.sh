DB=/data/log/hiview/sys_event_db/BUNDLEMANAGER_UE/BUNDLE_INSTALL_EXCEPTION-1-MINOR-481-0.db
echo "=== has sqlite3? ==="
which sqlite3 2>&1
echo "=== strings of exception db ==="
strings "$DB" 2>/dev/null | grep -iE "SceneBo|settings|reason|error|install" | head -40
echo "=== raw head ==="
strings "$DB" 2>/dev/null | head -60
echo "=== END ==="
