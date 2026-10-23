#!/bin/sh
echo "@@@CONN"
for c in /sys/class/drm/*/; do
  b=$(basename $c)
  echo "$b status=$(cat ${c}status 2>/dev/null) enabled=$(cat ${c}enabled 2>/dev/null) dpms=$(cat ${c}dpms 2>/dev/null)"
done
echo "@@@DRIDBG"
ls /sys/kernel/debug/dri/0/ 2>/dev/null
echo "@@@STATE"
head -c 1200 /sys/kernel/debug/dri/0/state 2>/dev/null
echo ""
echo "@@@FB"
cat /sys/kernel/debug/dri/0/framebuffer 2>/dev/null | head -c 600
echo ""
echo "@@@CLIENTS"
cat /sys/kernel/debug/dri/0/clients 2>/dev/null | head -c 600
echo ""
echo "@@@HUNG"
cat /proc/493/task/512/wchan 2>/dev/null; echo ""
cat /proc/493/task/512/stack 2>/dev/null | head -25
echo "@@@PEND"
for f in /sys/kernel/debug/dri/0/*; do echo "$f"; done
echo "@@@END"
