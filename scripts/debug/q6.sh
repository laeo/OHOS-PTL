echo 1 > /proc/sys/kernel/printk 2>/dev/null
echo 0 > /proc/sys/kernel/printk_devkmsg 2>/dev/null
sleep 1
{
echo "SCENE=$(ls /data/app/el1/bundle/public | grep -ci scene)"
echo "TOTAL=$(ls /data/app/el1/bundle/public | wc -l)"
H=$(ls -t /data/log/hilog/hilog.*.gz 2>/dev/null | head -1)
echo "HILOG=$H"
echo "--- scene errors ---"
zcat "$H" 2>/dev/null | grep -a -i sceneboard | grep -a -iE "fail|privilege|signature|parse" | tail -8
echo "--- generic errors ---"
zcat "$H" 2>/dev/null | grep -a -E "not allow use privilege|signature verify failed|parse haps file failed" | tail -6
} > /data/res.txt 2>&1
echo DONE_RES
