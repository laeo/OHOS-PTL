hilog -x > /data/h_now.txt 2>&1
wc -l /data/h_now.txt
echo "=== privilege/parse errors ==="
grep -a -E "not allow use privilege|parse haps file failed|ProcessBundleInfoByPrivilegeCapability|8519888|capability list" /data/h_now.txt | head -40
echo "=== scene ==="
grep -a -i "scene" /data/h_now.txt | grep -a -iE "bms|install|privilege|parse" | head -30
echo "=== END ==="
