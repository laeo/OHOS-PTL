#!/bin/sh
echo "DRMLIST:"; ls /sys/class/drm/
echo "CONNECTORS:"
for c in /sys/class/drm/*/; do
  b=$(basename $c)
  st=$(cat ${c}status 2>/dev/null)
  en=$(cat ${c}enabled 2>/dev/null)
  dp=$(cat ${c}dpms 2>/dev/null)
  echo "  [$b] st=$st en=$en dp=$dp"
done
echo "DEBUGRIS:"
ls /sys/kernel/debug/dri/0/ 2>&1
echo "STATE:"
head -c 2000 /sys/kernel/debug/dri/0/state 2>&1
echo
echo "T512WCHAN:"
cat /proc/493/task/512/wchan 2>/dev/null
echo
echo "PROBEDONE"
