#!/bin/sh
D=/data/exp2
rm -rf $D
mkdir -p $D
mkdir -p /data/local/tmp
{
  echo "=== id ==="; id
  echo "=== scontext ==="; cat /proc/self/attr/current
  echo "=== uptime ==="; cat /proc/uptime
  echo "=== params ==="
  for p in const.product.devicetype const.window.multiWindowUIType \
           const.security.developermode.state const.product.has_buildin_screen \
           persist.sceneboard.ispcmode const.build.characteristics; do
    echo -n "$p = "; param get $p 2>&1
  done
  echo "=== power-shell help timeout ==="
  power-shell timeout -o 3600000 2>&1
  echo "=== power-shell setmode ==="
  power-shell setmode 602 2>&1
} > $D/id.txt 2>&1

hilog -r > $D/hilog_clear.txt 2>&1
sleep 1

{
  echo "=== snapshot default (no -f) ==="; /system/bin/snapshot_display; echo "EXIT=$?"
  sleep 1
  echo "=== snapshot jpeg -> snapA.jpeg ==="; /system/bin/snapshot_display -i 0 -f /data/local/tmp/snapA.jpeg; echo "EXIT=$?"
  sleep 1
  echo "=== snapshot png -> snapB.png ==="; /system/bin/snapshot_display -i 0 -f /data/local/tmp/snapB.png -t png; echo "EXIT=$?"
  sleep 1
  echo "=== snapshot w/h ==="; /system/bin/snapshot_display -i 0 -f /data/local/tmp/snapC.jpeg -w 1280 -h 800; echo "EXIT=$?"
  sleep 1
  echo "=== ls tmp ==="; ls -la /data/local/tmp/
} > $D/snap.txt 2>&1

cp -f /data/local/tmp/snapA.jpeg $D/ 2>/dev/null
cp -f /data/local/tmp/snapB.png $D/ 2>/dev/null
cp -f /data/local/tmp/snapC.jpeg $D/ 2>/dev/null
cp -f /data/local/tmp/*.jpeg $D/ 2>/dev/null
cp -f /data/local/tmp/*.png $D/ 2>/dev/null

sleep 2
hilog -x > $D/hl.txt 2>&1

hidumper -ls > $D/sa_list.txt 2>&1
hidumper -s 4607 -a "-a" > $D/ssm_all.txt 2>&1
hidumper -s 4608 -a "-a" > $D/rs_all.txt 2>&1

{
  echo "=== drm connectors ==="
  for d in /sys/class/drm/*/; do
    echo "$d status=$(cat ${d}status 2>/dev/null) enabled=$(cat ${d}enabled 2>/dev/null) dpms=$(cat ${d}dpms 2>/dev/null) modes=$(cat ${d}modes 2>/dev/null | head -1)"
  done
  echo "=== dri clients ==="
  head -c 800 /sys/kernel/debug/dri/0/clients 2>&1
  echo ""
  echo "=== dri framebuffer ==="
  head -c 800 /sys/kernel/debug/dri/0/framebuffer 2>&1
} > $D/drm.txt 2>&1

ls -la $D/ > $D/ls.txt 2>&1
echo DONE > $D/done.txt
echo ALL_DONE
