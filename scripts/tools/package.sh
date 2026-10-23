#!/bin/bash
# package.sh - collect the oneVPL/VA/DRM runtime + probe + sample into a
# deterministic package tree (pkg/) and a manifest (manifest.txt) used by inject.sh.
#
# manifest line formats:
#   FILE|<part>|<local file>|<image path>|<mode octal>
#   LINK|<part>|<image path of real file>|<image path of link>|<link target>
#
# Partition choice:
#   p2 = system  : only ~23 MiB free -> keep just the probe, its launcher and
#                  the H.264 sample there.
#   p3 = vendor  : ~477 MiB free -> all the oneVPL / libva / libdrm / iHD
#                  runtime libraries (they are tens of MiB) live in
#                  /vendor/lib64, which is part of the OHOS musl namespace
#                  library search path (see /system/etc/ld-musl-namespace-x86_64.ini).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
STAGE="$HERE/stage/usr"
PKG="$HERE/pkg"
TREE=/home/katax/Public/OHOS
TREE_PROBE="$TREE/device/pc/ptl/hwdec_probe"

rm -rf "$PKG"
mkdir -p "$PKG/p2/system/bin" "$PKG/p2/system/etc/hwdec" \
         "$PKG/p3/lib64/dri" "$PKG/p3/lib64/libmfx-gen" "$PKG/p3/etc"

MAN="$HERE/manifest.txt"
: > "$MAN"

add() { # part src dst mode
    local part="$1" src="$2" dst="$3" mode="${4:-0644}"
    [ -f "$src" ] || { echo "ERROR: missing source: $src" >&2; exit 1; }
    local out="$PKG/$part$dst"
    mkdir -p "$(dirname "$out")"
    cp -f "$src" "$out"
    chmod "$mode" "$out"
    echo "FILE|$part|$out|$dst|$mode" >> "$MAN"
}

add_link() { # part dst linkname target
    echo "LINK|$1|$3|$2|$4" >> "$MAN"
}

P3=p3
# --- oneVPL dispatcher (Apache-2.0) ---
add $P3 "$STAGE/lib/libvpl.so.2.17"        "/lib64/libvpl.so.2.17"
add_link $P3 "/lib64/libvpl.so.2"   "/lib64/libvpl.so.2.17" "libvpl.so.2.17"

# --- oneVPL GPU runtime plugin ---
add $P3 "$STAGE/lib/libmfx-gen.so.1.2.17"  "/lib64/libmfx-gen.so.1.2.17"
add_link $P3 "/lib64/libmfx-gen.so.1.2" "/lib64/libmfx-gen.so.1.2.17" "libmfx-gen.so.1.2.17"
if [ -f "$STAGE/lib/libmfx-gen/enctools.so" ]; then
    add $P3 "$STAGE/lib/libmfx-gen/enctools.so" "/lib64/libmfx-gen/enctools.so"
fi

# --- libva / libva-drm ---
add $P3 "$STAGE/lib/libva.so.2.2500.0"     "/lib64/libva.so.2.2500.0"
add_link $P3 "/lib64/libva.so.2"    "/lib64/libva.so.2.2500.0" "libva.so.2.2500.0"
add $P3 "$STAGE/lib/libva-drm.so.2.2500.0" "/lib64/libva-drm.so.2.2500.0"
add_link $P3 "/lib64/libva-drm.so.2" "/lib64/libva-drm.so.2.2500.0" "libva-drm.so.2.2500.0"

# --- libdrm (upstream; the in-tree third_party/libdrm has no soname libdrm.so.2) ---
add $P3 "$STAGE/lib/libdrm.so.2.134.0"     "/lib64/libdrm.so.2.134.0"
add_link $P3 "/lib64/libdrm.so.2"   "/lib64/libdrm.so.2.134.0" "libdrm.so.2.134.0"

# --- gmmlib / igdgmm (media driver generic media driver library) ---
shopt -s nullglob
for g in "$STAGE"/lib/libigdgmm.so.*.* "$STAGE"/lib/libgmmumd.so.*.*; do
    b=$(basename "$g")
    [ -f "$g" ] || continue
    case "$b" in *.so.*.*) ;; *) continue ;; esac
    add $P3 "$g" "/lib64/$b"
    soname=$(readelf -d "$g" 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')
    [ -n "$soname" ] || soname=$(echo "$b" | sed -E 's/(\.so\.[0-9]+)\.[0-9]+$/\1/')
    add_link $P3 "/lib64/$soname" "/lib64/$b" "$b"
done
shopt -u nullglob

# --- Intel media driver VA plugin ---
for d in "$STAGE"/lib/dri/iHD_drv_video.so "$STAGE"/lib/iHD_drv_video.so; do
    [ -f "$d" ] || continue
    add $P3 "$d" "/lib64/dri/iHD_drv_video.so"
    break
done

# --- probe + launcher + sample (p2 / system) ---
add p2 "$HERE/build/hwdec_probe"            "/system/bin/hwdec_probe" "0755"
add p2 "$TREE_PROBE/hwdec_probe.sh"         "/system/bin/hwdec_probe.sh" "0755"
add p2 "$HERE/sample/moonlight.264"          "/system/etc/hwdec/sample.h264"
add p2 "$HERE/sample/foreman_p16x16.264"     "/system/etc/hwdec/sample_min.h264"

# --- init service (p3 / vendor) ---
add p3 "$TREE_PROBE/init.hwdec_probe.cfg"   "/etc/init.hwdec_probe.cfg"

echo "=== package tree:"
find "$PKG" -type f -printf '  %10s  %P\n' | sort -k2
echo "=== manifest: $MAN"
cat "$MAN"
