echo "=== persisted hilog files ==="
ls -la /data/log/hilog 2>/dev/null
echo "=== search persisted for sceneboard ==="
grep -rl -i sceneboard /data/log 2>/dev/null | head
echo "=== search persisted for device type / syscap install ==="
grep -r -a -iE "DEVICE_TYPE_NOT_SUPPORT|not supported.*moduleName|check supportAppTypes" /data/log 2>/dev/null | head -20
echo "=== BMS_USER_EVENT db? use grep on bmsdb ==="
strings /data/service/el1/public/bms/bundle_manager_service/bmsdb.db 2>/dev/null | grep -i sceneboard | head
echo "=== dependencies in module.json ==="
grep -o '"dependencies":\[[^]]*\]' /system/app/SceneBoard/module.json 2>/dev/null | head
echo "=== END ==="
