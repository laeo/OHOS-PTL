#!/bin/bash
# Build the oneVPL hardware decode probe for OpenHarmony (musl, x86_64).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK=/home/katax/Public/OHOS/prebuilts/ohos-sdk/linux/26.0.0/native
STAGE="$HERE/stage/usr"
VPL_API="$HERE/onevpl_src/api/vpl"
OUT="$HERE/build/hwdec_probe"

mkdir -p "$(dirname "$OUT")"
"$SDK/llvm/bin/clang" \
    --target=x86_64-linux-ohos \
    --sysroot="$SDK/sysroot" \
    -fuse-ld=lld \
    -O2 -g -Wall -Wextra -Wno-unused-parameter \
    -D__MUSL__ \
    -I"$VPL_API" \
    -I"$SDK/sysroot/usr/include" \
    /home/katax/Public/OHOS/device/pc/ptl/hwdec_probe/hwdec_probe.c \
    -o "$OUT" \
    -L"$STAGE/lib" -lvpl -ldl \
    -L"$SDK/sysroot/usr/lib/x86_64-linux-ohos" -lhilog_ndk.z \
    -lm

"$SDK/llvm/bin/llvm-strip" --strip-unneeded "$OUT" || true
echo "built: $OUT"
file "$OUT"
readelf -d "$OUT" | head -12
