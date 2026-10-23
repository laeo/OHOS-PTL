#!/bin/bash
HDC=/home/katax/.local/deveco/command-line-tools/sdk/default/openharmony/toolchains/hdc
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
LOG=$BASE/exp_override.log
: > $LOG
"$HDC" kill 2>/dev/null
for i in $(seq 1 120); do
  if "$HDC" list targets 2>/dev/null | grep -q 5555; then break; fi
  "$HDC" tconn 127.0.0.1:5555 >/dev/null 2>&1
  sleep 1
done
echo "$(date +%T) connected uptime=$("$HDC" shell cut -d. -f1 /proc/uptime 2>/dev/null | tr -d '\r')" >> $LOG
"$HDC" shell "power-shell timeout -o 3600000" >> $LOG 2>&1
"$HDC" shell "power-shell setmode 602" >> $LOG 2>&1
for k in $(seq 1 60); do
  UP=$("$HDC" shell "cut -d. -f1 /proc/uptime" 2>/dev/null | tr -d '\r')
  SP=$("$HDC" shell "hidumper -s RenderService -a screen 2>/dev/null | grep -a 'screen\[0\]'" 2>/dev/null | tr -d '\r')
  D=$("$HDC" shell 'for p in /proc/[0-9]*; do for t in $p/task/*; do st=$(cat $t/stat 2>/dev/null|cut -d" " -f3); [ "$st" = D ] && { echo -n "$(cat $t/comm) "; }; done; done 2>/dev/null' 2>/dev/null | tr -d '\r')
  echo "$(date +%T) up=${UP}s SP=[$SP] D=[$D]" >> $LOG
  "$HDC" shell "power-shell wakeup" >/dev/null 2>&1
  sleep 5
done
