#!/bin/sh
# Workload: repeatedly open/close the notification panel via touch injection.
D=/dev/input/event1
F=48
swipe() {
  x1=$(( $1 * F )); y1=$(( $2 * F ))
  x2=$(( $3 * F )); y2=$(( $4 * F ))
  steps=12
  sendevent $D 3 47 0
  sendevent $D 3 57 1
  sendevent $D 3 53 $x1
  sendevent $D 3 54 $y1
  sendevent $D 1 330 1
  sendevent $D 0 0 0
  i=1
  while [ $i -le $steps ]; do
    cx=$(( x1 + (x2 - x1) * i / steps ))
    cy=$(( y1 + (y2 - y1) * i / steps ))
    sendevent $D 3 53 $cx
    sendevent $D 3 54 $cy
    sendevent $D 0 0 0
    i=$(( i + 1 ))
  done
  sendevent $D 3 57 -1
  sendevent $D 1 330 0
  sendevent $D 0 0 0
}
n=0
while [ $n -lt 12 ]; do
  swipe 320 3 320 430
  sleep 1
  swipe 320 430 320 3
  sleep 1
  n=$(( n + 1 ))
done
echo WORKLOAD_DONE
