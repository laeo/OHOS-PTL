#!/bin/bash
# make_boot_media.sh - build a self-contained OpenHarmony boot ISO (option A)
#
# The produced ISO contains GRUB (UEFI), the kernel, a *custom initramfs* and the
# raw partition images.  The custom initramfs (boot_init.sh) loop-mounts the
# images and hands them to the stock OHOS init via /dev/block/by-name/*.
#
# It boots in two ways:
#   1. plain UEFI:  write the ISO to a USB (dd) or mount it as a CD and boot it
#   2. Ventoy:      copy the ISO onto a Ventoy USB stick and select it in the menu
#
# Usage:
#   IMAGES=<dir> HARDWARE=virt OUTDIR=<dir> bash make_boot_media.sh
#
# Defaults: IMAGES=out/x86_64_virt/packages/phone/images  HARDWARE=virt
#
# NOTE: nothing is written to /tmp.  All work happens under OUTDIR.

set -e

ROOT=/home/katax/Public/OHOS
IMAGES="${IMAGES:-$ROOT/out/x86_64_virt/packages/phone/images}"
HARDWARE="${HARDWARE:-virt}"
OUTDIR="${OUTDIR:-$ROOT/out/x86_64_virt/ohos-dbg/bootmedia_$HARDWARE}"
VOLID="${VOLID:-OHOSBOOT}"
USERDATA_SIZE_MB="${USERDATA_SIZE_MB:-1536}"
# GPU/WiFi/BT firmware staged into the *custom initramfs* as a real /lib/firmware
# tree (the kernel firmware loader only searches /lib/firmware*).  This is the
# "early window": it is reachable as soon as the initramfs is unpacked, before
# the system image is switched to root.  system.img:/system/lib/firmware stays
# the "runtime window" (reachable via /lib -> /system/lib after SwitchRoot).
INITRAMFS_FW_DIR="${INITRAMFS_FW_DIR:-$ROOT/device/pc/ptl/firmware}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOOT_INIT_SRC="$SCRIPT_DIR/bootmedia/boot_init.c"
BOOT_INIT="$OUTDIR/boot_init"

mkdir -p "$OUTDIR"
# 清掉上一次的产物，避免同一个 OUTDIR 里堆积/混入旧文件（只删本脚本生成的文件，不动别的）
rm -rf "$OUTDIR/isoroot" "$OUTDIR/initramfs_extra" 2>/dev/null
rm -f "$OUTDIR"/*.iso "$OUTDIR"/*.img "$OUTDIR"/*.cpio "$OUTDIR/boot_init" 2>/dev/null
ISOROOT="$OUTDIR/isoroot"
CUSTOM_RAMDISK="$OUTDIR/ramdisk_bootmedia.img"
USERDATA_IMG="$OUTDIR/userdata_bootmedia.img"

echo "== make_boot_media =="
echo "IMAGES=$IMAGES"
echo "HARDWARE=$HARDWARE"
echo "OUTDIR=$OUTDIR"

for f in bzImage ramdisk.img system.img vendor.img sys_prod.img chip_prod.img; do
    [ -f "$IMAGES/$f" ] || { echo "ERROR: missing $IMAGES/$f"; exit 1; }
done
[ -f "$BOOT_INIT_SRC" ] || { echo "ERROR: missing $BOOT_INIT_SRC"; exit 1; }

# ---------------------------------------------------------------- custom initramfs
# The stock ramdisk's toybox applets are linked against libcrypto_openssl.z.so
# which is NOT shipped in the ramdisk, so shell tooling cannot be used before
# switch_root.  We therefore use a small statically linked C program.
echo "== compiling static boot_init =="
gcc -static -O2 -Wall -o "$BOOT_INIT" "$BOOT_INIT_SRC"
echo "boot_init: $BOOT_INIT ($(stat -c%s "$BOOT_INIT") bytes)"

# The stock ramdisk is a single newc cpio (gzip).  We append a second cpio archive
# containing /boot_init; the kernel's initramfs unpacker merges concatenated
# archives (later entries win).  rdinit=/boot_init selects it.
echo "== building custom initramfs =="
WORK="$OUTDIR/initramfs_extra"
rm -rf "$WORK"; mkdir -p "$WORK"
cp "$BOOT_INIT" "$WORK/boot_init"
chmod 0755 "$WORK/boot_init"
# --- early-window firmware: real /lib/firmware/** inside the initramfs --------
# The kernel's firmware loader (drivers/base/firmware_loader/main.c) only looks
# for /lib/firmware[/updates][/<release>]/<name>, resolved against the init
# namespace root (init_task.fs).  Before SwitchRoot that root is this initramfs,
# so staging the files here guarantees they are found in the early window no
# matter when a driver asks (and no matter whether system.img is mounted yet).
if [ -d "$INITRAMFS_FW_DIR" ]; then
    echo "== staging firmware into initramfs from $INITRAMFS_FW_DIR =="
    mkdir -p "$WORK/lib/firmware"
    cp -a "$INITRAMFS_FW_DIR/." "$WORK/lib/firmware/"
    rm -f "$WORK/lib/firmware/BUILD.gn"
    find "$WORK/lib/firmware" -type f | sed "s|^$WORK/||" | sort
else
    echo "WARN: INITRAMFS_FW_DIR=$INITRAMFS_FW_DIR not found, skip initramfs firmware"
fi
( cd "$WORK" && find . -type f -print | sed 's|^\./||' | cpio -o -H newc --quiet ) > "$OUTDIR/extra.cpio"
zcat "$IMAGES/ramdisk.img" > "$OUTDIR/base.cpio"
cat "$OUTDIR/base.cpio" "$OUTDIR/extra.cpio" | gzip -9 > "$CUSTOM_RAMDISK"
echo "custom ramdisk: $CUSTOM_RAMDISK ($(stat -c%s "$CUSTOM_RAMDISK") bytes)"

# ---------------------------------------------------------------- writable userdata
if [ ! -f "$USERDATA_IMG" ]; then
    echo "== creating ${USERDATA_SIZE_MB}M userdata image =="
    dd if=/dev/zero of="$USERDATA_IMG" bs=1M count="$USERDATA_SIZE_MB" status=none
    # Match the feature set of the stock userdata.img: in particular the
    # 'encrypt' feature is required by OHOS fscrypt; 'orphan_file' and
    # 'metadata_csum_seed' are new mke2fs defaults the stock image does not use.
    mke2fs -q -F -t ext4 -b 4096 -I 256 \
        -O encrypt,^orphan_file,^metadata_csum_seed -L userdata "$USERDATA_IMG"
fi

# ---------------------------------------------------------------- iso root
echo "== assembling iso root =="
rm -rf "$ISOROOT"; mkdir -p "$ISOROOT/boot/grub"

# Shared kernel parameters -------------------------------------------------
# Base console output.  earlycon=efifb gives an early console on the firmware
# GOP framebuffer (before any DRM driver); keep_bootcon (entry C) prevents the
# early console from being torn down at console handoff.
# NOTE: no ignore_loglevel/loglevel=7 here anymore.  On a 3072x1920 panel every
# printed line is expensive (slow efifb/fbcon) and floods the log; the default
# entries therefore use quiet+loglevel=3 (see CMDLINE_QUIET).
#
# WARNING: do NOT add "console=ttyS0,115200" here.
#   It was originally added only to get QEMU serial logs.  On the real PTL
#   laptop there is no usable serial port, but the 8250 driver still creates
#   ttyS0 and registers it as a console, so printk then writes to a phantom
#   UART.  That makes output extremely slow / stalls right after
#   "Serial: 8250/16550 driver, 4 ports, IRQ sharing enabled".
#   QEMU has a real 16550, so the problem never showed up there; the host
#   Ubuntu cmdline likewise has no console=ttyS0, which is why it is fine.
#   Need a QEMU serial log?  At the GRUB menu press 'e' and temporarily append
#   console=ttyS0,115200 to the linux line, then Ctrl-X.
CMDLINE_BOOT="console=tty0 earlycon=efifb"
# Default (A/B/D/E/F): quiet/fast boot.  quiet alone sets console loglevel 4;
# the explicit loglevel=3 keeps only warnings/errors.  This targets console
# *noise/speed*, NOT the early-PCI-enumeration hang - for that use E/F.
CMDLINE_QUIET="quiet loglevel=3"
# Persistent logging / hang diagnosis (compiled into the kernel as well):
#   panic=10                       reboot 10s after a panic -> the next boot
#                                  can read the pstore/EFI dump.
#   softlockup_panic=1             a soft-locked CPU panics instead of freezing.
#   nmi_watchdog=panic,1           enable the hard-lockup detector AND panic on it.
#   sysrq_always_enabled=1         Alt+SysRq+c / /proc/sysrq-trigger always works.
#   log_buf_len=4M                 enlarge the kernel printk ring buffer (default
#                                  is ~128-512KiB and is grown per CPU).  Without
#                                  it the early WARN and the boot-time service
#                                  logs are flushed out long before a late panic
#                                  (the PTL reboot happens after minutes), so the
#                                  cause is gone by the time pstore snapshots the
#                                  tail.  4M keeps the last few minutes alive.
#                                  Printed on every menu entry (via CMDLINE_LOG).
CMDLINE_LOG="log_buf_len=4M panic=10 softlockup_panic=1 nmi_watchdog=panic,1 sysrq_always_enabled=1"
# Standard kernel parameter that adds a *high-priority* firmware search root
# (drivers/base/firmware_loader/main.c: fw_path_para is tried before the default
# /lib/firmware* entries).  Point it at the real directory on the system image
# so the loader finds the firmware via the literal path, independent of the
# /lib -> /system/lib symlink.  Before SwitchRoot this path does not exist yet
# (the loader then falls through to the default /lib/firmware, which the
# initramfs provides).  After SwitchRoot /system/lib/firmware exists -> hit.
CMDLINE_FW="firmware_class.path=/system/lib/firmware"

# ---------------------------------------------------------------- ramoops (persistent DRAM console)
# The kernel keeps writing its console log into a small reserved DRAM region
# while it runs.  That region survives a *warm* reset (reset without power
# loss), so after the machine hangs and resets itself -- or after the user
# presses Alt+SysRq+C / triggers a reboot -- the previous boot's console log is
# readable on the *next* boot as:
#     /sys/fs/pstore/console-ramoops-0      (previous boot's console tail)
#     /sys/fs/pstore/dmesg-ramoops-0        (oops/panic snapshot, if any)
# and boot_init also prints them automatically to the screen/serial.
#
#   memmap=nn$ss  mark nn bytes at physical ss as E820_TYPE_RESERVED so the
#                 page allocator never hands that RAM to anyone else;
#   ramoops.*     point the ramoops driver at the very same region
#                 (mem_size/console_size must be powers of two; console_size>0
#                 is mandatory to record the console at all).
#
# Region: 1 MiB @ 0x7e000000.  This sits inside the real PTL e820 System RAM
# window (0x70000000-0x807fffff) *and* inside QEMU's low RAM, with a clean
# margin below the top of low memory.  (The earlier 0x7f000000 choice would end
# at 0x7fffffff, and QEMU marks 0x7ffdf000-0x7fffffff device-reserved, so we
# moved down 16 MiB to keep the whole reservation inside System RAM.)
#
# !!! THE '$' MUST STAY ESCAPED AS '\$' IN grub.cfg !!!
# GRUB's script parser treats an unescaped '$0...' as a positional variable, so
# `memmap=1M$0x....` is silently expanded to `memmap=1M` before the kernel sees
# it (verified on GRUB 2.14: `echo 1M$0x.....` prints `1Mx.....`).  With no
# separator after the size, parse_memmap_one() (arch/x86/kernel/e820.c) takes the
# else-branch: e820__range_remove(mem_size, ULLONG_MAX - mem_size, E820_TYPE_RAM),
# i.e. it DELETES every System RAM range above 1 MiB.  The kernel is then left
# with no memory for its boot page tables and panics with
#     "alloc_low_pages: can not alloc memory"   (last_pfn collapses to 0x9f)
# during setup_arch().  That is exactly what killed the old [L] entry.  The
# single-quoted bash string below therefore keeps the backslash literal so
# grub.cfg contains `memmap=1M\$0x7e000000`, which GRUB turns back into a real
# '$' for the kernel.  Set RAMOOPS="" to disable the channel entirely.
if [ -z "${RAMOOPS+x}" ]; then
    RAMOOPS='memmap=1M\$0x7e000000 ramoops.mem_address=0x7e000000 ramoops.mem_size=0x100000 ramoops.console_size=0x80000'
fi
CMDLINE_RAMOOPS="$RAMOOPS"

# The mount handoff to the stock OHOS init (unchanged from the previous ISO).
CMDLINE_MOUNT="rdinit=/boot_init root=/dev/ram0 rw sn=0123456789 hardware=${HARDWARE} ohos.boot.hardware=${HARDWARE} ohos.required_mount.system=/dev/block/by-name/system@/usr@ext4@ro,barrier=1@wait,required ohos.required_mount.vendor=/dev/block/by-name/vendor@/vendor@ext4@ro,barrier=1@wait,required ohos.required_mount.sys_prod=/dev/block/by-name/sys_prod@/sys_prod@ext4@rw,barrier=1@wait,required ohos.required_mount.chip_prod=/dev/block/by-name/chip_prod@/chip_prod@ext4@rw,barrier=1@wait,required ohos.required_mount.data=/dev/block/by-name/userdata@/data@ext4@nosuid,nodev,noatime,barrier=1,data=ordered,noauto_da_alloc@wait,reservedsize=104857600"

# ------------------------------------------------------------------ extra log channels
# Optional, all off by default.  The kernel cannot write to a file/U-disk path:
# console= only picks a *console device*.  These are the real persistent/remote
# channels.  Set the matching environment variable before running this script.
#
#   NETCONSOLE=<host-ip>/<prefix>@<gateway>,<port>@<local-nic-mac>
#       e.g. NETCONSOLE="192.168.1.50/24@192.168.1.1,6666@a0:b1:c2:d3:e4:f5"
#       (local-nic-mac = the *laptop* NIC MAC; the netdev must already be up,
#        so this only captures logs after PCI+driver init -- use it for
#        later-phase hangs, not for an early PCI-enumeration hang).
#       Receiver:  nc -u -l -p 6666    (or  socat -u UDP-RECV:6666 -)
#
#   PSTORE_BLKDEV=/dev/<dev>       dedicated *raw* partition or stick (writes
#       overwrite it, so never point it at a filesystem/Ventoy partition).
#       Requires CONFIG_PSTORE_BLK=y in the kernel; captures the console
#       continuously and survives a power cycle.  Also needs the block device
#       to exist -> again *after* PCI enumeration.
#
# NOTE: the persistent-DRAM ram console channel is now always compiled into the
# kernel command line (see CMDLINE_RAMOOPS below).  It was removed once because
# the 1 MiB @0x7f000000 reservation made the kernel panic very early
# ("alloc_low_pages: can not alloc memory"); the real cause was the '$' in
# `memmap=1M$0x7f000000` being eaten by the GRUB script parser, not the address.
EXTRA_LOG=""
[ -n "${NETCONSOLE:-}" ]    && EXTRA_LOG="$EXTRA_LOG netconsole=${NETCONSOLE}"
[ -n "${PSTORE_BLKDEV:-}" ] && EXTRA_LOG="$EXTRA_LOG pstore_blk.blkdev=${PSTORE_BLKDEV} pstore_blk.kmsg_size=64 pstore_blk.console_size=64"
[ -n "$EXTRA_LOG" ] && echo "extra kernel params:${EXTRA_LOG}"

# Recommended order when the machine stops early (see PC_ON_PTL_BOOT_MEDIA.md):
#   [1] normal boot            - quiet/fast boot, everyday use.
#   [2] verbose log            - keep_bootcon loglevel=7: the definitive
#       "did it hang or just stop drawing?" test (early console never torn down).
#   [3] verbose + initcall_debug - pin down *which* initcall hangs.  Prints
#       "calling <fn>" / "<fn> returned" pairs; the last "+xxxxx" line left on
#       screen names the culprit.  VERY slow (every initcall is timed/printed).
#   [4] verbose + skip ACPI thermal - initcall_blacklist=acpi_thermal_init:
#       verify whether the hang point is exactly that driver.
#   Manual dump at any hang: Alt+SysRq+C (sysrq_always_enabled=1).
#   Tip: no rebuild needed for a one-off test - at the GRUB menu press 'e' and
#        append   keep_bootcon loglevel=7   to the linux line, then Ctrl-X.
cat > "$ISOROOT/boot/grub/grub.cfg" <<EOF
set timeout=15
set default=0

menuentry "OpenHarmony 7.0 PC - normal boot [1]" {
    linux /boot/bzImage ${CMDLINE_BOOT} ${CMDLINE_QUIET} ${CMDLINE_LOG} ${CMDLINE_FW}${EXTRA_LOG} ${CMDLINE_RAMOOPS} split_lock_detect=off ${CMDLINE_MOUNT}
    initrd /boot/ramdisk_bootmedia.img
}

menuentry "OpenHarmony 7.0 PC - verbose log (keep_bootcon) [2]" {
    linux /boot/bzImage ${CMDLINE_BOOT} keep_bootcon loglevel=7 ${CMDLINE_LOG} ${CMDLINE_FW}${EXTRA_LOG} ${CMDLINE_RAMOOPS} split_lock_detect=off ${CMDLINE_MOUNT}
    initrd /boot/ramdisk_bootmedia.img
}

menuentry "OpenHarmony 7.0 PC - verbose + initcall_debug (find the hanging initcall) [3] - SLOW" {
    linux /boot/bzImage ${CMDLINE_BOOT} keep_bootcon loglevel=7 initcall_debug ${CMDLINE_LOG} ${CMDLINE_FW}${EXTRA_LOG} ${CMDLINE_RAMOOPS} split_lock_detect=off ${CMDLINE_MOUNT}
    initrd /boot/ramdisk_bootmedia.img
}

menuentry "OpenHarmony 7.0 PC - verbose + skip ACPI thermal (initcall_blacklist) [4]" {
    linux /boot/bzImage ${CMDLINE_BOOT} keep_bootcon loglevel=7 initcall_blacklist=acpi_thermal_init ${CMDLINE_LOG} ${CMDLINE_FW}${EXTRA_LOG} ${CMDLINE_RAMOOPS} split_lock_detect=off ${CMDLINE_MOUNT}
    initrd /boot/ramdisk_bootmedia.img
}
EOF

# ---------------------------------------------------------------- build ID
# Stamp a small, self-describing build ID into system.img *before* the ISO is
# packed, so a running guest can tell exactly which image/ISO it booted.  The id
# is dynamic (never hard-coded): UTC timestamp + short sha256 of the just-written
# grub.cfg (which itself folds in HARDWARE and every kernel cmdline).  zz_pslog.sh
# prints this file as the first line of every pstore snapshot -> "ZZPSLOG:
# build_id: ...".
echo "== stamping build id into system.img =="
BUILD_TIME_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILD_TIME_LOCAL="$(date '+%Y-%m-%d %H:%M:%S %z')"
GRUB_CFG="$ISOROOT/boot/grub/grub.cfg"
GRUB_SHA256="$(sha256sum "$GRUB_CFG" | cut -d' ' -f1)"
BUILD_ID="$(date -u +%Y%m%d-%H%M%S)-$(printf '%s' "$GRUB_SHA256" | cut -c1-12)"
BUILD_ID_FILE="$OUTDIR/ohos_build_id"
cat > "$BUILD_ID_FILE" <<EOF
BUILD_ID=$BUILD_ID
BUILD_TIME_UTC=$BUILD_TIME_UTC
BUILD_TIME_LOCAL=$BUILD_TIME_LOCAL
HARDWARE=$HARDWARE
GRUB_CFG_SHA256=$GRUB_SHA256
BUILD_SCRIPT=make_boot_media.sh
IMAGES=$IMAGES
EOF
cat "$BUILD_ID_FILE"
# debugfs cannot overwrite an existing file: rm first ("not found" on the first
# run is expected and does not stop debugfs from executing the write).
{
    echo "rm /system/etc/ohos_build_id"
    echo "write $BUILD_ID_FILE /system/etc/ohos_build_id"
    echo "sif /system/etc/ohos_build_id mode 0100644"
    echo "sif /system/etc/ohos_build_id uid 0"
    echo "sif /system/etc/ohos_build_id gid 0"
} | debugfs -w "$IMAGES/system.img" > "$OUTDIR/buildid_debugfs.log" 2>&1 || true
if ! debugfs -R 'stat /system/etc/ohos_build_id' "$IMAGES/system.img" 2>/dev/null | grep -q 'Inode:'; then
    echo "ERROR: failed to stamp /system/etc/ohos_build_id"
    cat "$OUTDIR/buildid_debugfs.log"; exit 1
fi
# PROOF #1 (before fsck): the file was not merely present but has EXACTLY the
# bytes we meant to write.  A silent debugfs failure ("Ext2 file already
# exists") would leave a stale file behind; only a content compare catches it.
BID_FROM_IMG="$OUTDIR/ohos_build_id.from_img"
rm -f "$BID_FROM_IMG"
debugfs -R "dump /system/etc/ohos_build_id $BID_FROM_IMG" "$IMAGES/system.img" >/dev/null 2>&1
if ! cmp -s "$BUILD_ID_FILE" "$BID_FROM_IMG"; then
    echo "ERROR: /system/etc/ohos_build_id content mismatch (stale/debugfs write failed)"
    echo "--- intended ---"; cat "$BUILD_ID_FILE"; echo "--- in image ---"; cat "$BID_FROM_IMG" 2>&1
    exit 1
fi
echo "build-id content verified against image (pre-fsck): $(cat "$BID_FROM_IMG" | head -1)"
# e2fsck is mandatory after a debugfs write to keep the filesystem consistent.
echo "== e2fsck system.img after build-id write (this can take ~1 min) =="
FSCK_T0="$(date +%s)"
set +e
e2fsck -f -y "$IMAGES/system.img" > "$OUTDIR/buildid_e2fsck.log" 2>&1
FSCK_RC=$?
set -e
FSCK_DT="$(( $(date +%s) - FSCK_T0 ))"
echo "e2fsck rc=$FSCK_RC elapsed=${FSCK_DT}s (log: $OUTDIR/buildid_e2fsck.log)"
# e2fsck returns a bitmask; >=4 means errors remain uncorrected -> abort.
if [ "$FSCK_RC" -ge 4 ]; then
    echo "ERROR: e2fsck rc=$FSCK_RC"; tail -30 "$OUTDIR/buildid_e2fsck.log"; exit 1
fi
# PROOF #2 (after fsck): re-dump and compare once more; then hash it.  Also
# verify the FUSED zz_pslog.sh (build_id + kernel-fragment version) really is the
# one inside the image -- that is what the on-device pstore snapshot runs.
BID_FROM_IMG="$OUTDIR/ohos_build_id.from_img"
rm -f "$BID_FROM_IMG"
debugfs -R "dump /system/etc/ohos_build_id $BID_FROM_IMG" "$IMAGES/system.img" >/dev/null 2>&1
if ! cmp -s "$BUILD_ID_FILE" "$BID_FROM_IMG"; then
    echo "ERROR: /system/etc/ohos_build_id mismatch after e2fsck"; exit 1
fi
BUILD_ID_SHA="$(sha256sum "$BUILD_ID_FILE" | cut -d' ' -f1)"
BUILD_ID_IMG_SHA="$(sha256sum "$BID_FROM_IMG" | cut -d' ' -f1)"
ZZP_FROM_IMG="$OUTDIR/zz_pslog.from_img.sh"
rm -f "$ZZP_FROM_IMG"
debugfs -R "dump /system/bin/zz_pslog.sh $ZZP_FROM_IMG" "$IMAGES/system.img" >/dev/null 2>&1
for kw in 'build_id:' 'dmesg (xe/drm/fw)' 'drm state' 'modules -----'; do
    if ! grep -q -- "$kw" "$ZZP_FROM_IMG" 2>/dev/null; then
        echo "ERROR: system.img /system/bin/zz_pslog.sh is missing marker '$kw'"
        echo "       (the image does not carry the fused build_id+kernel-fragment script)"; exit 1
    fi
done
ZZP_IMG_SHA="$(sha256sum "$ZZP_FROM_IMG" | cut -d' ' -f1)"
echo "build_id stamped: BUILD_ID=$BUILD_ID"
echo "ohos_build_id sha256: $BUILD_ID_SHA (local) / $BUILD_ID_IMG_SHA (in image)"
echo "zz_pslog.sh   sha256: $ZZP_IMG_SHA (in image); markers build_id/dmesg/drm/modules present"

cp "$IMAGES/bzImage"       "$ISOROOT/boot/bzImage"
cp "$CUSTOM_RAMDISK"       "$ISOROOT/boot/ramdisk_bootmedia.img"
# hardlink the big images (same filesystem) to avoid duplicating GBs of data
ln -f "$IMAGES/system.img"    "$ISOROOT/system.img"
ln -f "$IMAGES/vendor.img"    "$ISOROOT/vendor.img"
ln -f "$IMAGES/sys_prod.img"  "$ISOROOT/sys_prod.img"
ln -f "$IMAGES/chip_prod.img" "$ISOROOT/chip_prod.img"
ln -f "$USERDATA_IMG"         "$ISOROOT/userdata.img"
# Carry the build id on the medium root too, so boot_init's early BOOT MARKER
# (which reads "$g_media_dir/ohos_build_id") records the real BUILD_ID instead
# of "unknown" (zz_pslog.sh already reads /system/etc/ohos_build_id).
cp "$BUILD_ID_FILE" "$ISOROOT/ohos_build_id"
echo "built by make_boot_media.sh hardware=$HARDWARE" > "$ISOROOT/.ohos_boot_media"

# ---------------------------------------------------------------- ISO
echo "== creating ISO =="
ISO="$OUTDIR/ohos-pc-${HARDWARE}.iso"
rm -f "$ISO"
grub-mkrescue -o "$ISO" "$ISOROOT" -- -volid "$VOLID" >/dev/null 2>"$OUTDIR/grub-mkrescue.err" || {
    echo "grub-mkrescue failed:"; cat "$OUTDIR/grub-mkrescue.err"; exit 1;
}
echo "ISO: $ISO ($(stat -c%s "$ISO") bytes)"
# Final, copy-pasteable summary: the id stamped into the image plus its sha256,
# and the ISO's own size/sha256.  Compare the on-device `ZZPSLOG: build_id: ...`
# line against BUILD_ID below: equal => the guest booted exactly this ISO.
ISO_SHA="$(sha256sum "$ISO" | cut -d' ' -f1)"
echo "---------------- FINAL SUMMARY ----------------"
echo "BUILD_ID=$BUILD_ID"
echo "BUILD_ID_SHA256=$BUILD_ID_SHA"
echo "BUILD_ID_IMG_SHA256=$BUILD_ID_IMG_SHA"
echo "ZZ_PSLOG_IMG_SHA256=$ZZP_IMG_SHA"
echo "ISO=$ISO"
echo "ISO_BYTES=$(stat -c%s "$ISO")"
echo "ISO_SHA256=$ISO_SHA"
echo "== done =="
