echo "SCENE_COUNT=$(ls /data/app/el1/bundle/public | grep -ci scene)"
echo "TOTAL=$(ls /data/app/el1/bundle/public | wc -l)"
echo "PROCS:"
ps -A -o PID,NAME | grep -iE "scene|systemui|launcher"
echo "EXCEPTION_FILES:"
ls /data/log/hiview/sys_event_db/BUNDLEMANAGER_UE/ 2>/dev/null
echo "END_MARK"
