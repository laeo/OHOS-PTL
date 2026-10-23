#!/bin/bash
# build_grub.sh - build the OpenHarmony PC bootloader (GRUB 2.14) for pc_ptl.
#
# WHY A SELF-BUILT GRUB
# ---------------------
# Ubuntu/Debian ship GRUB 2.14 with
#     debian/patches/secure-boot/disable-efi-fallback-to-legacy.patch
# which removes the "legacy shim_lock" kernel loader fallback from
# grub-core/loader/efi/linux.c.  With shim 15.8 (which implements only the
# legacy shim_lock verifier, not SHIM_IMAGE_LOADER_GUID) the distribution
# GRUB then asks the *firmware* to load the kernel; the firmware only trusts
# its db, so a kernel that is only signed with our MOK certificate fails with
#
#     error: cannot load image.
#
# Building from pristine upstream keeps the fallback, so GRUB itself loads the
# kernel (EFI handover) after shim has verified it with the MOK - the
# firmware db never needs our certificate.
#
# On top of upstream we apply two OHOS patches (see patches/):
#   0001  keep the legacy shim_lock loader reachable (+ force knob)
#   0002  keep loaded modules writable (GRUB 2.14 .bss read-only bug)
# and we embed a .sbat section (shim >= 15 refuses binaries without it).
#
# OUTPUT (all under $WORK, default out/x86_64_virt/ohos-dbg/partdisk/grub):
#   dist/grubx64.efi          raw GRUB core (with .sbat section)
#   dist/grubx64.efi.signed   the same, Authenticode-signed with the project
#                             MOK key (this is what goes on the ESP)
#
# Usage:
#   bash device/pc/ptl/grub/build_grub.sh              # full build
#   SKIP_BUILD=1 bash device/pc/ptl/grub/build_grub.sh # reuse dist/ artifacts
#
# Environment:
#   GRUB_WORK=<dir>       work dir (default out/.../partdisk/grub)
#   JOBS=<n>              make parallelism (default: nproc, capped at 8)
#   SB_KEYS_DIR=<dir>     MOK key dir (default out/.../partdisk/sb_keys)
#   GRUB_TARBALL_URL      override the upstream tarball URL
set -euo pipefail

ROOT=/home/katax/Public/OHOS
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${GRUB_WORK:-$ROOT/out/x86_64_virt/ohos-dbg/partdisk/grub}"
SRC="$WORK/src/grub-2.14"
DIST="$WORK/dist"
LOGS="$WORK/logs"
TARBALL="$WORK/grub2_2.14.orig.tar.xz"
PATCH_DIR="$HERE/patches"
SBAT_FILE="$HERE/grub.sbat"
KEYS="${SB_KEYS_DIR:-$ROOT/out/x86_64_virt/ohos-dbg/partdisk/sb_keys}"
SB_KEY="$KEYS/ohos-uefi.key"
SB_CRT="$KEYS/ohos-uefi.crt"
JOBS="${JOBS:-$(nproc)}"
[ "$JOBS" -gt 8 ] && JOBS=8

GRUB_VERSION=2.14
GRUB_TARBALL_URL="${GRUB_TARBALL_URL:-https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/grub2/2.14-2ubuntu1/grub2_2.14.orig.tar.xz}"
GRUB_TARBALL_SHA256=bc8d3c73535b8838d8c8e2654d73edc4e6ae8c8acdb45d5df5dc9a1547446d43

# modules embedded in the core image (same list as make_partition_disk.sh)
GRUB_MODULES="part_gpt part_msdos fat ext2 normal linux search search_fs_file search_label configfile echo test all_video efi_gop font gfxterm videoinfo video_bochs video_cirrus terminal png jpeg ls cat sleep halt reboot minicmd"

mkdir -p "$WORK" "$DIST" "$LOGS"

say() { echo "[build_grub] $*"; }

# ---------------------------------------------------------------- 0. reuse?
if [ "${SKIP_BUILD:-0}" = "1" ]; then
    if [ -f "$DIST/grubx64.efi.signed" ] && [ -f "$DIST/grubx64.efi" ]; then
        say "SKIP_BUILD=1: reusing existing artifacts"
        sha256sum "$DIST/grubx64.efi" "$DIST/grubx64.efi.signed"
        exit 0
    fi
    say "SKIP_BUILD=1 but no artifacts in $DIST -> building anyway"
fi

# ---------------------------------------------------------------- 1. source
if [ ! -f "$TARBALL" ]; then
    say "downloading $GRUB_TARBALL_URL"
    curl -fL --retry 3 -o "$TARBALL.part" "$GRUB_TARBALL_URL"
    mv "$TARBALL.part" "$TARBALL"
fi
echo "$GRUB_TARBALL_SHA256  $TARBALL" | sha256sum -c - >/dev/null \
    || { echo "ERROR: tarball checksum mismatch"; exit 1; }
say "tarball ok ($(stat -c%s "$TARBALL") bytes)"

if [ ! -d "$SRC" ]; then
    say "extracting"
    mkdir -p "$WORK/src"
    tar -C "$WORK/src" -xf "$TARBALL"
fi

# ---------------------------------------------------------------- 2. patches
if [ ! -f "$SRC/.ohos-patched" ]; then
    for p in "$PATCH_DIR"/*.patch; do
        say "applying $(basename "$p")"
        ( cd "$SRC" && patch -p1 --forward --batch < "$p" ) >> "$LOGS/patch.log" 2>&1 \
            || { echo "ERROR: patch failed: $p (see $LOGS/patch.log)"; tail -20 "$LOGS/patch.log"; exit 1; }
    done
    touch "$SRC/.ohos-patched"
else
    say "patches already applied (.ohos-patched)"
fi

# --- the two properties the whole Secure Boot story depends on
grep -q "grub_cmd_linux_x86_legacy" "$SRC/grub-core/loader/efi/linux.c" \
    || { echo "ERROR: legacy shim_lock kernel loader missing from linux.c"; exit 1; }
grep -q "using legacy shim_lock protocol, falling back to legacy Linux kernel loader" \
    "$SRC/grub-core/loader/efi/linux.c" \
    || { echo "ERROR: upstream legacy shim_lock fallback is missing (Debian patch applied?)"; exit 1; }
grep -q "OHOS: keep loaded modules writable" "$SRC/grub-core/kern/dl.c" \
    || { echo "ERROR: .bss writable fix missing from kern/dl.c"; exit 1; }
say "patch invariants OK (legacy shim_lock loader present, modules writable)"

# ---------------------------------------------------------------- 3. configure
if [ ! -f "$SRC/config.status" ]; then
    say "configure (EFI platform)"
    ( cd "$SRC" && ./configure --with-platform=efi \
        --prefix="$WORK/grub-install" --disable-nls --disable-werror ) \
        > "$LOGS/configure.log" 2>&1 \
        || { echo "ERROR: configure failed (see $LOGS/configure.log)"; tail -30 "$LOGS/configure.log"; exit 1; }
fi

# ---------------------------------------------------------------- 4. make
say "make -j$JOBS (log: $LOGS/make.log)"
( cd "$SRC" && make -j"$JOBS" ) > "$LOGS/make.log" 2>&1 \
    || { echo "ERROR: make failed (see $LOGS/make.log)"; tail -40 "$LOGS/make.log"; exit 1; }
[ -x "$SRC/grub-mkimage" ] || { echo "ERROR: grub-mkimage not built"; exit 1; }

# ---------------------------------------------------------------- 5. grub-mkimage
RAW="$DIST/grubx64.efi"
say "grub-mkimage (with .sbat section)"
( cd "$SRC" && ./grub-mkimage -d grub-core -O x86_64-efi -o "$RAW" \
    -p /boot/grub -s "$SBAT_FILE" $GRUB_MODULES ) > "$LOGS/mkimage.log" 2>&1 \
    || { echo "ERROR: grub-mkimage failed (see $LOGS/mkimage.log)"; tail -20 "$LOGS/mkimage.log"; exit 1; }
[ -f "$RAW" ] || { echo "ERROR: grub-mkimage produced no output"; exit 1; }
objdump -h "$RAW" | grep -q '\.sbat' \
    || { echo "ERROR: no .sbat section in the GRUB core (shim would refuse it)"; exit 1; }
cp -f "$SBAT_FILE" "$DIST/grub.sbat"
say "raw GRUB: $(stat -c%s "$RAW") bytes, .sbat section present"

# ---------------------------------------------------------------- 6. sign (MOK)
SIGNED="$DIST/grubx64.efi.signed"
if [ -f "$SB_KEY" ] && [ -f "$SB_CRT" ]; then
    command -v sbsign >/dev/null || { echo "ERROR: sbsign not found"; exit 1; }
    say "sbsign with the project MOK key"
    sbsign --key "$SB_KEY" --cert "$SB_CRT" --output "$SIGNED" "$RAW" > "$LOGS/sbsign.log" 2>&1 \
        || { echo "ERROR: sbsign failed (see $LOGS/sbsign.log)"; exit 1; }
    sbverify --list "$SIGNED" > "$LOGS/sbverify.log" 2>&1 \
        || { echo "ERROR: sbverify failed on the signed GRUB"; cat "$LOGS/sbverify.log"; exit 1; }
    grep -q '^signature' "$LOGS/sbverify.log" \
        || { echo "ERROR: signed GRUB has no signature"; exit 1; }
    say "signed GRUB: $(stat -c%s "$SIGNED") bytes"
else
    echo "WARNING: no MOK key at $SB_KEY - producing an UNSIGNED GRUB only"
fi

# ---------------------------------------------------------------- 7. summary
{
    echo "GRUB_VERSION=$GRUB_VERSION"
    echo "GRUB_SOURCE=$GRUB_TARBALL_URL"
    echo "GRUB_SOURCE_SHA256=$GRUB_TARBALL_SHA256"
    echo "PATCHES=$(cd "$PATCH_DIR" && ls *.patch | tr '\n' ' ')"
    echo "RAW=$RAW"
    echo "RAW_BYTES=$(stat -c%s "$RAW")"
    echo "RAW_SHA256=$(sha256sum "$RAW" | cut -d' ' -f1)"
    if [ -f "$SIGNED" ]; then
        echo "SIGNED=$SIGNED"
        echo "SIGNED_BYTES=$(stat -c%s "$SIGNED")"
        echo "SIGNED_SHA256=$(sha256sum "$SIGNED" | cut -d' ' -f1)"
    fi
    echo "SBAT_FILE=$DIST/grub.sbat"
    echo "MODULES=$GRUB_MODULES"
} | tee "$DIST/build_info.txt"
say "done"
