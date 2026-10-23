echo "=== capability file sceneboard ==="
grep -c sceneboard /system/etc/app/install_list_capability.json
grep -A3 sceneboard /system/etc/app/install_list_capability.json
echo "=== install_list SceneBoard ==="
grep -c SceneBoard /system/etc/app/install_list.json
echo "=== exception db still has scene? ==="
for f in $(find /data/log/hiview/sys_event_db/BUNDLEMANAGER_UE -name "*INSTALL_EXCEPTION*" 2>/dev/null); do echo "FILE $f"; strings "$f" | grep -i scene | head; done
echo "=== installed count ==="
ls /data/app/el1/bundle/public | wc -l
echo "=== END ==="
