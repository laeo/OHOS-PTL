#!/bin/sh
D=/dev/input/event1
sendevent $D 3 47 0
sendevent $D 3 57 1
sendevent $D 3 53 7422
sendevent $D 3 54 2594
sendevent $D 1 330 1
sendevent $D 0 0 0
sleep 0.08
sendevent $D 3 57 -1
sendevent $D 1 330 0
sendevent $D 0 0 0
echo TAP_DONE
