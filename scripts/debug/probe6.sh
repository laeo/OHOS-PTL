echo "=== install_list app_dirs ==="
grep -oE '/system/app/[^"]+' /system/etc/app/install_list.json | sed 's#/system/app/##' | sort > /data/list1.txt
cat /data/list1.txt
echo "=== installed ==="
ls /data/app/el1/bundle/public | sort > /data/list2.txt
echo "=== in list but NOT installed ==="
comm -23 /data/list1.txt /data/list2.txt
echo "=== installed but not in list ==="
comm -13 /data/list1.txt /data/list2.txt
echo "=== /system/app dirs count ==="
ls /system/app | wc -l
echo "=== END ==="
