{
echo "=== install_list SceneBoard ==="
grep -c SceneBoard /system/etc/app/install_list.json
echo "=== capability sceneboard ==="
grep -c sceneboard /system/etc/app/install_list_capability.json
echo "=== full hilog search scene ==="
hilog -x 2>/dev/null | grep -a -i "scene" | grep -a -iE "install|scan|bundle|parse" | tail -20
echo "=== BOOT_SCAN_END content ==="
D=/data/log/hiview/sys_event_db/BUNDLEMANAGER_UE
F=$(ls -t $D/*BOOT_SCAN_END* 2>/dev/null | head -1)
strings "$F" | head -20
} > /data/res3.txt 2>&1
echo DONE12
