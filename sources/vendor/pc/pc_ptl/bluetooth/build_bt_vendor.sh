#!/bin/bash
# Build libbt_vendor.z.so for pc_ptl (x86_64 OHOS musl) -- standalone, no GN needed.
#
# Usage: bash build_bt_vendor.sh [outdir]
# Default outdir: <repo>/out/x86_64_virt/ohos-dbg/fix_bt_hci/work
set -euo pipefail

REPO=/home/katax/Public/OHOS
SRC_DIR=$REPO/vendor/pc/pc_ptl/bluetooth
CLANG=$REPO/prebuilts/clang/ohos/linux-x86_64/llvm/bin/clang
SYSROOT=$REPO/out/ptl/obj/third_party/musl/usr/include/x86_64-linux-ohos
OUT_DIR=${1:-$REPO/out/x86_64_virt/ohos-dbg/fix_bt_hci/work}
OUT=$OUT_DIR/libbt_vendor.z.so
STRIP=$REPO/prebuilts/clang/ohos/linux-x86_64/llvm/bin/llvm-strip

mkdir -p "$OUT_DIR"

RT=$REPO/prebuilts/clang/ohos/linux-x86_64/llvm/lib/clang/15.0.4/lib/x86_64-linux-ohos
MUSL_LIB=$REPO/out/ptl/obj/third_party/musl/usr/lib/x86_64-linux-ohos

"$CLANG" \
  --target=x86_64-linux-ohos \
  -O2 -g0 -Wall -Wextra -fvisibility=hidden -fPIC \
  -isystem "$SYSROOT" \
  -I "$SRC_DIR/include" \
  -B "$MUSL_LIB" \
  -L "$RT" -L "$MUSL_LIB" \
  -shared \
  "$SRC_DIR/src/bt_vendor_linux.c" \
  -lpthread \
  -o "$OUT"

"$STRIP" --strip-unneeded "$OUT"
echo "[ok] $OUT  ($(stat -c %s "$OUT") B)"
sha256sum "$OUT"
