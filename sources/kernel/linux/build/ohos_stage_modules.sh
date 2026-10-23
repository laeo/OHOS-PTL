#!/bin/bash
# Copyright (c) 2024 Huawei Device Co., Ltd.
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# ohos_stage_modules.sh - stage a curated, dependency-ordered set of kernel
# modules ("*.ko" + "load_order.txt") for installation into
# /system/lib/modules, from the *whole* freshly built module tree.
#
# The OHOS `linux_kernel` target historically only ran `make bzImage`, so
# `=m` drivers were never built and the image shipped a hand-picked handful of
# .ko.  This script closes the loop: kernel.mk runs a top-level `make modules`
# (which produces a correct Module.symvers), then calls this script to pick the
# modules that this board actually needs (given by a per-device manifest), to
# resolve their full dependency closure with depmod/modprobe and to emit a load
# order that the in-image loader (zz_drmmod.sh) can insmod without modprobe.
#
# Usage:
#   ohos_stage_modules.sh <OBJ_DIR> <STAGE_DIR> <MANIFEST>
#
#   OBJ_DIR   kernel object dir (has include/config/kernel.release + *.ko)
#   STAGE_DIR output dir; gets the stripped closure + load_order.txt
#   MANIFEST  one root module per line (name or name.ko, '#' comments).
#             Prefix a line with '?' to mark it optional (missing -> warn only).
#
# Nothing is written outside STAGE_DIR.
set -e

OBJ=${1:?usage: ohos_stage_modules.sh <OBJ_DIR> <STAGE_DIR> <MANIFEST>}
STAGE=${2:?}
MANIFEST=${3:?}

[ -d "$OBJ" ] || { echo "[modules] ERROR: OBJ_DIR '$OBJ' not found" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "[modules] ERROR: manifest '$MANIFEST' not found" >&2; exit 1; }

KREL=$(cat "$OBJ/include/config/kernel.release")
DEPMOD=$(command -v depmod || echo /usr/sbin/depmod)
MODPROBE=$(command -v modprobe || echo /usr/sbin/modprobe)
if [ -n "${CLANG_HOST_TOOLCHAIN:-}" ] && [ -x "$CLANG_HOST_TOOLCHAIN/llvm-strip" ]; then
    STRIP="$CLANG_HOST_TOOLCHAIN/llvm-strip"
elif command -v llvm-strip >/dev/null 2>&1; then
    STRIP=$(command -v llvm-strip)
else
    STRIP=$(command -v strip)
fi

echo "[modules] OBJ=$OBJ STAGE=$STAGE KREL=$KREL"
echo "[modules] depmod=$DEPMOD modprobe=$MODPROBE strip=$STRIP"

rm -rf "$STAGE"
mkdir -p "$STAGE"
TREE="$STAGE/.depmod/lib/modules/$KREL"
mkdir -p "$TREE"

# Index every built module by basename and expose it to depmod through a flat
# symlink tree (mirrors what the in-image /system/lib/modules looks like).
declare -A KOPATH
count=0
while IFS= read -r -d '' ko; do
    b=$(basename "$ko")
    if [ -n "${KOPATH[$b]:-}" ]; then
        echo "[modules] WARN: duplicate basename '$b' (${KOPATH[$b]}); keeping first" >&2
        continue
    fi
    KOPATH[$b]="$ko"
    ln -sf "$ko" "$TREE/$b"
    count=$((count + 1))
done < <(find "$OBJ" -name '*.ko' -print0)
echo "[modules] $count modules indexed from $OBJ"

if [ "$count" -eq 0 ]; then
    echo "[modules] ERROR: no .ko under $OBJ - did 'make modules' run?" >&2
    exit 1
fi

# Make depmod aware of built-in modules too (avoids spurious "missing" deps).
for f in modules.builtin modules.builtin.modinfo modules.order; do
    [ -f "$OBJ/$f" ] && cp -f "$OBJ/$f" "$TREE/$f"
done

"$DEPMOD" -b "$STAGE/.depmod" "$KREL"

CLOSURE="$STAGE/.closure"
: > "$CLOSURE"
missing=0
while IFS= read -r raw; do
    case "$raw" in ''|\#*) continue ;; esac
    opt=0
    case "$raw" in
        \?*) opt=1; raw=${raw#\?} ;;
    esac
    name=${raw##*/}
    name=${name%.ko}
    deps=$("$MODPROBE" -d "$STAGE/.depmod" -S "$KREL" --show-depends "$name" 2>/dev/null || true)
    if [ -z "$deps" ]; then
        if [ "$opt" = "1" ]; then
            echo "[modules] WARN: optional module '$name' not present, skipped" >&2
        else
            echo "[modules] ERROR: manifest module '$name' not found in the build" >&2
            missing=1
        fi
        continue
    fi
    printf '%s\n' "$deps" | sed -n 's#^insmod [^ ]*/\([^/ ]*\.ko\).*#\1#p' >> "$CLOSURE"
done < "$MANIFEST"

# de-duplicate while preserving first-seen (dependency) order
awk '!seen[$0]++' "$CLOSURE" > "$STAGE/load_order.txt"
cp -f "$STAGE/load_order.txt" "$STAGE/modules_needed.txt"

# Copy + strip the closure.
while IFS= read -r b; do
    [ -n "$b" ] || continue
    src=${KOPATH[$b]:-}
    if [ -z "$src" ]; then
        echo "[modules] ERROR: no source path for closure module $b" >&2
        missing=1
        continue
    fi
    cp -f "$src" "$STAGE/$b"
    "$STRIP" --strip-debug "$STAGE/$b" 2>/dev/null \
        || "$STRIP" -g "$STAGE/$b" 2>/dev/null \
        || true
done < "$STAGE/load_order.txt"

rm -rf "$STAGE/.depmod" "$CLOSURE"

echo "[modules] load_order.txt:"
sed 's/^/  /' "$STAGE/load_order.txt"

if [ "$missing" != "0" ]; then
    echo "[modules] ERROR: staging incomplete (missing manifest roots)" >&2
    exit 1
fi
echo "[modules] staged $(wc -l < "$STAGE/load_order.txt") modules into $STAGE"
