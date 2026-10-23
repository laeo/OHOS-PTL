echo "=== drm connectors ==="
ls /sys/class/drm/
for c in /sys/class/drm/*/; do
  echo "--- $c"
  cat ${c}status 2>/dev/null
  cat ${c}enabled 2>/dev/null
  head -c 200 ${c}modes 2>/dev/null
done
echo "=== t512 state ==="
cat /proc/493/task/512/wchan 2>/dev/null; echo
echo "=== dmesg virtio/drm err ==="
dmesg 2>/dev/null | grep -iE "virtio_gpu|virtio-gpu|drm|scanout|EDID|connector" | grep -viE "initialized|features|scanouts:|cap sets" | tail -25
echo "=== hilog display host ==="
grep -aiE "display_composer|HdfDisplay|HdiDrm|ComposerHost|drm_connector|drm_mode|SetDisplay|CreateComposer|VSync|vblank|GetDisplay|Present" /data/hl.txt | grep -avE "C02510|C04201" | tail -40
echo "=== DONE2 ==="
