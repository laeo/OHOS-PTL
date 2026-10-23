#!/bin/sh
D=/data/exp3
rm -rf $D
mkdir -p $D
mkdir -p /data/local/tmp
hilog -G 32M > $D/g.txt 2>&1
hilog -b D > $D/b.txt 2>&1
hilog -r > $D/r.txt 2>&1
sleep 1
/system/bin/snapshot_display -i 0 -f /data/local/tmp/x.jpeg > $D/snap.txt 2>&1
echo "EXIT=$?" >> $D/snap.txt
sleep 1
hilog -x -D 0xC04201 > $D/hl_dms.txt 2>&1
hilog -x -D 0xC01406 > $D/hl_rs.txt 2>&1
hilog -b I > /dev/null 2>&1
wc -l $D/hl_dms.txt $D/hl_rs.txt >> $D/snap.txt 2>&1
echo DONE > $D/done.txt
echo ALL_DONE
