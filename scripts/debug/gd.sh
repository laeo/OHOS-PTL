echo "=== drm status ==="
cat /sys/class/drm/card0-Virtio-1/status 2>&1
cat /sys/class/drm/card0-Virtio-1/enabled 2>&1
cat /sys/class/drm/card0-Virtio-1/modes 2>&1
echo "=== fb ==="
ls -l /dev/fb* /dev/dri/ 2>&1
echo "=== dri debug ==="
ls /sys/kernel/debug/dri/ 2>&1
cat /sys/kernel/debug/dri/0/name 2>&1
echo "=== composer procs ==="
ps -A -o pid,comm 2>/dev/null | grep -iE "composer|render|sceneboard|wmserver"
echo "=== hdf_devhost stack ==="
cat /proc/493/task/512/stat 2>&1
echo "=== gpu node ==="
ls -l /dev/dri/renderD128 2>&1
echo "=== env ==="
getprop persist.sceneboard.ispcmode 2>&1
getprop const.product.has_buildin_screen 2>&1
param get const.product.has_buildin_screen 2>&1
echo "=== DONE ==="
