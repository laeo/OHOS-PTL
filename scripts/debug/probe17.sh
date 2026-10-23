D=/data/log/hiview/sys_event_db/BUNDLEMANAGER_UE
echo "=== BUNDLE_INSTALL db: scene? ==="
strings "$D/BUNDLE_INSTALL-4-MINOR-480-0.db" | grep -aic scene
echo "=== BUNDLE_INSTALL bundle names ==="
strings "$D/BUNDLE_INSTALL-4-MINOR-480-0.db" | grep -a "^com\." | sort -u | head -50
echo "=== BMS_USER_EVENT scene ==="
strings "$D/BMS_USER_EVENT-4-MINOR-585-0.db" | grep -aic scene
echo "=== BOOT_SCAN_END ==="
strings "$D/BOOT_SCAN_END-4-MINOR-542-0.db" | head -20
echo "=== find persisted exception json ==="
grep -rl "SPreInstallExceptionMgr" /data 2>/dev/null | head
echo "=== END ==="
