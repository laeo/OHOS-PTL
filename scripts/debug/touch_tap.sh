#!/bin/sh
D=/dev/input/event1
X=$1; Y=$2
XR=$((X*24)); YR=$((Y*24))
sendevent $D 3 47 0
sendevent $D 3 57 1
sendevent $D 3 53 $XR
sendevent $D 3 54 $YR
sendevent $D 1 330 1
sendevent $D 0 0 0
sleep 1
sendevent $D 3 57 -1
sendevent $D 1 330 0
sendevent $D 0 0 0
echo TAP_DONE
