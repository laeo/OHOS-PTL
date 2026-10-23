echo "== ls /sys/class/drm =="
ls /sys/class/drm/
echo "== connectors =="
for c in /sys/class/drm/*/; do
  b=$(basename $c)
  echo "[$b] status=$(cat ${c}status 2>/dev/null) enabled=$(cat ${c}enabled 2>/dev/null) dpms=$(cat ${c}dpms 2>/dev/null)"
done
echo "== debugfs dri =="
ls /sys/kernel/debug/dri/0/ 2>&1
echo "== state (head) =="
head -c 1500 /sys/kernel/debug/dri/0/state 2>&1
echo
echo "== fb count =="
head -c 400 /sys/kernel/debug/dri/0/framebuffer 2>&1
echo "== t512 wchan =="
cat /proc/493/task/512/wchan 2>/dev/null; echo
cat /proc/493/task/512/stack 2>/dev/null | head -20
echo "== DONE3 =="
