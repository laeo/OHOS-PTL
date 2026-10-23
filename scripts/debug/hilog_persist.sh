echo "=== start hilog file writer ==="
hilog -w start 2>&1
hilog -w query 2>&1 | head
echo "=== enable debug for install ==="
hilog -b D 2>&1
echo "=== done ==="
