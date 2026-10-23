ls /data/app/el1/bundle/public > /data/lst.txt 2>&1
grep -ci scene /data/lst.txt
hilog -x > /data/hh.txt 2>&1
grep -a -iE "sceneboard" /data/hh.txt | grep -a -iE "install failed|privilege|signature|parse" > /data/err.txt
wc -l /data/err.txt
head -20 /data/err.txt
