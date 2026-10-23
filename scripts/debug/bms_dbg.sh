echo "=== hilog help for buffer/level ==="
hilog -h 2>&1 | head -40
echo "=== set persistent buffer size ==="
hilog -G 16M 2>&1
echo "=== set level debug ==="
hilog -b D 2>&1
echo "=== clear ==="
hilog -r 2>&1
echo "=== BMS pid ==="
ps -A -o PID,PPID,NAME | grep -iE "foundation|BMS"
echo "=== END ==="
