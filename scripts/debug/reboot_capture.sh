echo "=== enable persistent hilog writer ==="
hilog -w start 2>&1
hilog -w query 2>&1 | head -5
echo "=== set debug ==="
hilog -b D 2>&1
echo "=== reboot ==="
sync
reboot
echo "=== done ==="
