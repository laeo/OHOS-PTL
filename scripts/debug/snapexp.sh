#!/bin/sh
O=/data/local/tmp/exp
mkdir -p $O
{
  echo "=== id ==="; id
  echo "=== scontext ==="; cat /proc/self/attr/current
  echo "=== uptime ==="; cat /proc/uptime
  echo "=== date ==="; date
  echo "=== params ==="
  for p in const.product.devicetype const.window.multiWindowUIType \
           const.security.developermode.state const.product.has_buildin_screen \
           persist.sceneboard.ispcmode const.build.characteristics; do
    echo -n "$p = "; param get $p 2>&1
  done
} > $O/id.txt 2>&1

hilog -r > $O/hilog_clear.txt 2>&1
sleep 1

{
  echo "=== snapshot default (no -f) ==="; /system/bin/snapshot_display 2>&1; echo "EXIT=$?"
  sleep 1
  echo "=== snapshot jpeg -> snapA.jpeg ==="; /system/bin/snapshot_display -i 0 -f $O/snapA.jpeg; echo "EXIT=$?"
  sleep 1
  echo "=== snapshot png -> snapB.png ==="; /system/bin/snapshot_display -i 0 -f $O/snapB.png -t png; echo "EXIT=$?"
  sleep 1
  echo "=== snapshot w/ w/h ==="; /system/bin/snapshot_display -i 0 -f $O/snapC.jpeg -w 1280 -h 800; echo "EXIT=$?"
  echo "=== ls ==="; ls -la $O
} > $O/snap.txt 2>&1

sleep 3
hilog -x > $O/hl.txt 2>&1
wc -l $O/hl.txt > $O/hl_wc.txt 2>&1

hidumper -ls > $O/sa_list.txt 2>&1
hidumper -s 4608 -a "-a" > $O/rs_all.txt 2>&1
hidumper -s 4608 > $O/rs_all2.txt 2>&1
hidumper -s 4607 > $O/ssm_all.txt 2>&1

{
  echo "=== drm connectors ==="
  for d in /sys/class/drm/*/; do
    echo "$d status=$(cat ${d}status 2>/dev/null) enabled=$(cat ${d}enabled 2>/dev/null) dpms=$(cat ${d}dpms 2>/dev/null) modes=$(cat ${d}modes 2>/dev/null | head -1)"
  done
  echo "=== dri debugfs ==="
  ls /sys/kernel/debug/dri/0/ 2>&1
  echo "=== dri state ==="
  head -c 2000 /sys/kernel/debug/dri/0/state 2>&1
  echo ""
  echo "=== dri fb ==="
  head -c 800 /sys/kernel/debug/dri/0/framebuffer 2>&1
  echo ""
  echo "=== dri clients ==="
  head -c 800 /sys/kernel/debug/dri/0/clients 2>&1
} > $O/drm.txt 2>&1

echo DONE > $O/done.txt
echo "ALL_DONE"
