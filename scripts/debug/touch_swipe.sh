#!/bin/sh
# Multi-touch protocol B swipe on /dev/input/event1 (QEMU Virtio MultiTouch)
D=/dev/input/event1
# slot 0 down at y=700
sendevent $D 3 47 0     # ABS_MT_SLOT 0
sendevent $D 3 57 1     # ABS_MT_TRACKING_ID 1
sendevent $D 3 53 640   # ABS_MT_POSITION_X
sendevent $D 3 54 700   # ABS_MT_POSITION_Y
sendevent $D 1 330 1    # BTN_TOUCH down
sendevent $D 0 0 0      # SYN_REPORT
# swipe up
y=660
while [ $y -ge 120 ]; do
  sendevent $D 3 54 $y
  sendevent $D 0 0 0
  y=$((y-40))
done
# lift
sendevent $D 3 57 -1    # ABS_MT_TRACKING_ID -1
sendevent $D 1 330 0    # BTN_TOUCH up
sendevent $D 0 0 0
echo TOUCH_SWIPE_DONE
