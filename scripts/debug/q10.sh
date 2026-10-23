{
echo "=== public bundles (all) ==="
ls /data/app/el1/bundle/public
echo "=== any sceneboard anywhere ==="
find /data -iname "*sceneboard*" 2>/dev/null | head
echo "=== bm dump ==="
bm dump -n com.ohos.sceneboard 2>&1 | head -3
echo "=== bmsdb grep ==="
strings /data/service/el1/public/bms/bundle_manager_service/bmsdb.db 2>/dev/null | grep -o "com.ohos.sceneboard" | head -2
} > /data/res2.txt 2>&1
echo DONE10
