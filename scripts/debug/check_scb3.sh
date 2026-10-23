hilog -x > /data/h_fresh.txt 2>&1
wc -l /data/h_fresh.txt
echo "=== parse failures ==="
grep -a "parse haps file failed" /data/h_fresh.txt | tail -20
echo "=== privilege ==="
grep -a "not allow use privilege" /data/h_fresh.txt | tail -10
echo "=== capability signature ==="
grep -a "signature verify failed in capability list" /data/h_fresh.txt | tail -10
echo "=== sceneboard ==="
grep -a -B1 -A1 "com.ohos.sceneboard" /data/h_fresh.txt | grep -aiE "install|parse|privilege|capability" | tail -20
echo "=== END ==="
