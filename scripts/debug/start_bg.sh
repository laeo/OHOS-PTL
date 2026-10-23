#!/bin/bash
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
rm -f "$BASE/run/ser.sock" "$BASE/run/qmp.sock"
exec setsid bash "$BASE/scripts/launch_diag_sock.sh" >> "$BASE/qemu-snap.log" 2>&1 < /dev/null
