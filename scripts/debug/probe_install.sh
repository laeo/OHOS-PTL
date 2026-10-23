echo "=== install_list SceneBoard ==="
grep -c SceneBoard /system/etc/app/install_list.json
echo "=== installed public bundles ==="
ls /data/app/el1/bundle/public | wc -l
echo "=== sceneboard installed? ==="
ls /data/app/el1/bundle/public | grep -i scene || echo NO_SCENEBOARD
echo "=== BMS scan/parse errors ==="
grep -aiE "Parse bundleDir|not allowed installed|parse dir .* not exist|install_list" /data/h3.txt | tail -20
echo "=== BMS sceneboard lines ==="
grep -ai sceneboard /data/h3.txt | tail -10
echo "=== running procs ==="
ps -A -o PID,NAME | grep -iE "scene|launcher|systemui"
echo "=== done ==="
