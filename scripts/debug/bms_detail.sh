F=$(ls -t /data/log/hilog/hilog.001.*.gz)
echo "FILE=$F"
zcat "$F" 2>/dev/null | grep -a "C01120/BMS" > /data/bms1.txt
wc -l /data/bms1.txt
echo "=== BMS lines 21:47:02 to 21:47:04 ==="
grep -a -E "21:47:0[234]" /data/bms1.txt | grep -a -viE "GetOdid|not found|ImplicitQuery|disabled caller|incorrect" | head -60
echo "=== APP_LOGE-ish around install ==="
grep -a -iE "parse|profile|invalid|failed|not support|deviceType" /data/bms1.txt | grep -a -iE "21:47:0[0-5]" | head -60
echo "=== END ==="
