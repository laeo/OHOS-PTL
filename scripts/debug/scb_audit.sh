echo "=== bm dump sceneboard ==="
bm dump -n com.ohos.sceneboard 2>&1 | head -5
echo "=== bmsdb strings scene ==="
strings /data/service/el1/public/bms/bundle_manager_service/bmsdb.db 2>/dev/null | grep -i scene | head
echo "=== fresh hilog sceneboard ==="
hilog -x 2>/dev/null | grep -a -i "sceneboard" | tail -30
echo "=== fresh hilog install scan ==="
hilog -x 2>/dev/null | grep -a -E "OTA Install new|needInstall|ProcessSystemBundleInstall|boot install" | tail -20
echo "=== END ==="
