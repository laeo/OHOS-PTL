echo "SUPPORT=$(param get const.bms.supportAppTypes 2>&1)"
echo "DEVT=$(param get const.product.devicetype 2>&1)"
echo "=== dirs exist? ==="
for d in SceneBoard com.ohos.camera com.ohos.settings com.ohos.photos; do
  if [ -d /system/app/$d ]; then echo "$d EXISTS"; else echo "$d MISSING"; fi
done
echo "=== END ==="
