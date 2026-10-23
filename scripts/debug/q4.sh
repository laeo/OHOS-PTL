D=/data/log/hiview/sys_event_db/BUNDLEMANAGER_UE
F=$(ls -t $D/*INSTALL_EXCEPTION* 2>/dev/null | head -1)
echo "EXCFILE=$F"
strings -n 6 "$F" | grep -a "^/system/app" | sort -u
echo "=== newest persisted hilog ==="
H=$(ls -t /data/log/hilog/hilog.*.gz 2>/dev/null | head -1)
echo "HILOG=$H"
zcat "$H" 2>/dev/null | grep -a -iE "sceneboard" | grep -a -iE "fail|privilege|signature|parse|install" | head -20
echo "=== all privilege errors newest ==="
zcat "$H" 2>/dev/null | grep -a -E "not allow use privilege|signature verify failed|parse haps file failed" | head -10
echo "END_MARK"
