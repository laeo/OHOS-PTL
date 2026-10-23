#!/bin/sh
D=/data/exp4
rm -rf $D
mkdir -p $D /data/local/tmp
hilog -G 32M > $D/g.txt 2>&1
hilog -b D > $D/b.txt 2>&1
hilog -r > $D/r.txt 2>&1
sleep 1
uitest screenCap -p /data/local/tmp/u.jpeg -d 0 > $D/u.txt 2>&1
echo "UITEST_EXIT=$?" >> $D/u.txt
sleep 1
hilog -x | grep -aiE 'snapshot|permission|shell|displaynode|surfacecapture|pixelmap|GetScreen|GetDisplay|uitest' > $D/dms.txt 2>&1
hilog -b I > /dev/null 2>&1
wc -l $D/dms.txt >> $D/u.txt 2>&1
ls -la /data/local/tmp/u.jpeg >> $D/u.txt 2>&1
echo DONE > $D/done.txt
echo ALL_DONE
