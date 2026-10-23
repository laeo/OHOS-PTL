echo "=== sceneboard installed? ==="
ls /data/app/el1/bundle/public | grep -i scene || echo NO_SCENEBOARD
echo "=== count ==="
ls /data/app/el1/bundle/public | wc -l
echo "=== procs ==="
ps -A -o PID,NAME | grep -iE "scene|launcher|systemui" || echo NONE
echo "=== install exception for sceneboard ==="
find /data/log/hiview/sys_event_db/BUNDLEMANAGER_UE -name "*INSTALL_EXCEPTION*" -exec strings {} \; 2>/dev/null | grep -i scene | head
echo "=== END ==="
