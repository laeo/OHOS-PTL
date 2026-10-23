echo "PARAM_SUPPORT=$(param get const.bms.supportAppTypes 2>&1)"
echo "PARAM_DEVT=$(param get const.product.devicetype 2>&1)"
echo "LIST_COUNT=$(grep -c app_dir /system/etc/app/install_list.json 2>&1)"
echo "SCENE_IN_LIST=$(grep -c SceneBoard /system/etc/app/install_list.json 2>&1)"
echo "UNINSTALL=$(cat /system/etc/app/uninstall_list.json 2>&1)"
echo "BUNDLE_COUNT=$(ls /data/app/el1/bundle/public | wc -l)"
echo "=== BMS sceneboard ==="
grep -a -i "sceneboard" /data/h4.txt | head -20
echo "=== BMS device type reject ==="
grep -a -i "not supported" /data/h4.txt | head -20
echo "=== BMS supportAppTypes ==="
grep -a -i "supportAppTypes" /data/h4.txt | head -10
echo "=== END ==="
