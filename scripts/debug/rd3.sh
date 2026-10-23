{
echo "SCENE=$(ls /data/app/el1/bundle/public | grep -ci scene)"
echo "TOTAL=$(ls /data/app/el1/bundle/public | wc -l)"
echo "HILOGDIR:"
ls /data/log/hilog/ 2>/dev/null
} > /data/res5.txt 2>&1
echo DONE_RD3
