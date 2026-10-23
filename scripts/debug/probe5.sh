echo "=== BMS db dir ==="
find /data/service -iname "*bms*" -o -iname "*bundle*" 2>/dev/null | head -20
echo "=== public bundles (full) ==="
ls /data/app/el1/bundle/public
echo "=== search scene in all data ==="
find /data -iname "*sceneboard*" 2>/dev/null | head
echo "=== BMS logs on disk ==="
ls -la /data/log 2>/dev/null | head
find /data/log -iname "*bms*" 2>/dev/null | head
echo "=== END ==="
