D=/data/log/hiview/sys_event_db/BUNDLEMANAGER_UE
F=$(ls -t $D/*INSTALL_EXCEPTION* 2>/dev/null | head -1)
{
echo "FILE=$F"
strings -n 6 "$F" | grep -a "^/system/app" | sort -u
} > /data/exc.txt 2>&1
echo DONE_EXC
