#!/bin/sh
# Scale px -> device raw. Observed: raw 640 -> 26.67px implies max ~30720.
D=/dev/input/event1
xraw=15360   # 640px * 24
sendevent $D 3 47 0
sendevent $D 3 57 1
sendevent $D 3 53 $xraw
sendevent $D 3 54 29952   # 780px
sendevent $D 1 330 1
sendevent $D 0 0 0
y=29491
while [ $y -ge 3840 ]; do
  sendevent $D 3 54 $y
  sendevent $D 0 0 0
  y=$((y-1280))
done
sendevent $D 3 57 -1
sendevent $D 1 330 0
sendevent $D 0 0 0
echo SWIPE2_DONE
