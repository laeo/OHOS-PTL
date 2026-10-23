#!/bin/sh
# Swipe up on the SceneBoard lock screen using the QEMU Virtio MultiTouch device.
# Raw ABS range is 0..32767, so raw = px * 32767 / screen_size.
# Run inside the guest:  sh /data/local/tmp/unlock_touch.sh
DEV=$(grep -B4 'Virtio MultiTouch' /proc/bus/input/devices 2>/dev/null | grep -o 'event[0-9]*' | head -1)
[ -z "$DEV" ] && DEV=event1
D=/dev/input/$DEV
echo "unlock_touch: using $D"
sendevent $D 3 47 0
sendevent $D 3 57 1
sendevent $D 3 53 16383
sendevent $D 3 54 26624
sendevent $D 1 330 1
sendevent $D 0 0 0
y=25400
while [ $y -ge 8192 ]; do
  sendevent $D 3 54 $y
  sendevent $D 0 0 0
  y=$((y-1230))
done
sendevent $D 3 54 8192
sendevent $D 0 0 0
sendevent $D 3 57 -1
sendevent $D 1 330 0
sendevent $D 0 0 0
echo UNLOCK_TOUCH_DONE
