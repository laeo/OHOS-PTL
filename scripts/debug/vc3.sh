{
echo "SCENE=$(ls /data/app/el1/bundle/public | grep -ci scene)"
echo "TOTAL=$(ls /data/app/el1/bundle/public | wc -l)"
echo "PROCS:"
ps -A -o PID,NAME | grep -iE "scene|systemui"
} > /data/vc.txt 2>&1
echo DONE_VC
