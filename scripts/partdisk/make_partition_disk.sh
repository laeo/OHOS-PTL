#!/bin/bash
# make_partition_disk.sh - build a dd-able UEFI/GPT disk for Intel PTL (pc_ptl)
# using *real* GPT partitions instead of one big partition holding .img files.
#
# Layout:
#   p1  ESP         512 MiB  FAT32 (ef00)  GRUB standalone + bzImage + ramdisk
#   p2  system      2048 MiB (8300)       raw system.img
#   p3  vendor       512 MiB (8300)       raw vendor.img
#   p4  sys_prod      64 MiB (8300)       raw sys_prod.img
#   p5  chip_prod     64 MiB (8300)       raw chip_prod.img
#   p6  userdata    img+16MiB (8300)      raw userdata.img, resized to fill
#
# The .img files are written straight into their partitions with dd (no loop,
# no mount).  GPT partition names are system/vendor/sys_prod/chip_prod/userdata.
#
# Boot: GRUB -> bzImage + ramdisk (stock OHOS init + firmware + part_init).
#   part_init (tiny, no loop) waits for the real GPT partitions and creates
#   /dev/block/by-name/* symlinks, then execs the *stock* /init, which mounts
#   the real partitions.  See part_init.c for why this is necessary on x86.
#
# Nothing is written to /tmp; all products live under OUTDIR.
set -e

ROOT=/home/katax/Public/OHOS
IMAGES="${IMAGES:-$ROOT/out/ptl/packages/phone/images}"
HARDWARE="${HARDWARE:-pc_ptl}"
OUTDIR="${OUTDIR:-$ROOT/out/x86_64_virt/ohos-dbg/partdisk/media}"
NAME="${NAME:-ohos_part_pc_ptl.img}"
VOLID="${VOLID:-ESP}"
FW_DIR="${FW_DIR:-$ROOT/device/pc/ptl/firmware}"
PART_INIT_SRC="${PART_INIT_SRC:-$ROOT/out/x86_64_virt/ohos-dbg/partdisk/part_init.c}"
# ACPI SSDT override (pc_ptl BIOS ships a broken SSDT "I2C_DEVT" -> AE_AML_INTERNAL
# -> the I2C-HID touchpad (TOPS0102 27C6:0F9A) never appears as an ACPI device).
# CONFIG_ACPI_TABLE_UPGRADE reads kernel/firmware/acpi/*.aml from the *raw* head of
# the initramfs; our table keeps HONOR/I2C_DEVT ids but oem_revision 0x2000 > 0x1000,
# so acpi_table_initrd_override() replaces the bad physical SSDT.  Source of truth:
# the exact override Ubuntu uses on the same laptop (/lib/firmware/acpi/SSDT27_TPD0.aml).
ACPI_OVERRIDE_SRC="${ACPI_OVERRIDE_SRC:-$ROOT/out/x86_64_virt/ohos-dbg/partdisk/acpi_override/SSDT27_TPD0.aml}"
# /data (p6) size = size(userdata.img) + USR_EXTRA_MIB.  The stock userdata.img
# is 2048 MiB; 14336 MiB extra yields a 16 GiB /data (matches the shipped
# ohos_part_pc_ptl.img, which was grown in place to 16 GiB).  Override with the
# USR_EXTRA_MIB env var if a different /data size is wanted.
USR_EXTRA_MIB="${USR_EXTRA_MIB:-14336}"
# SMALL_IMAGE=1 (default): the GPT still declares p6 (userdata) as P6_MIB
# (= size(userdata.img)+USR_EXTRA_MIB = 16 GiB), but the ext4 filesystem written
# into p6 keeps its stock size (P6_EXT4_MIB) and the image file is truncated
# right after it.  On first boot OHOS init runs `resize2fs -f` on /data
# (fstab_mount.c:960) and grows the fs to the whole p6 partition, so the
# delivered image is ~5.2 GiB while /data ends up 16 GiB on the target disk.
# The target disk must be >= p6 end (~16.1 GiB); dd_and_verify.sh runs
# `sgdisk -e` afterwards to move the backup GPT to the end of the real disk.
# Set SMALL_IMAGE=0 to get the legacy full-size image (ext4 == p6 == 16 GiB).
SMALL_IMAGE="${SMALL_IMAGE:-1}"
MIB=1048576

DISK="$OUTDIR/$NAME"
WORK="$OUTDIR/work"
RAMDISK="$OUTDIR/ramdisk_bootmedia.img"
BUILD_ID_FILE="$OUTDIR/ohos_build_id"

# ------------------------------------------------------------------ Secure Boot
# SECURE_BOOT=1 (DEFAULT) builds a disk that boots with UEFI Secure Boot ENABLED:
#
#   firmware db (Microsoft UEFI CA 2011)
#       -> ::/EFI/BOOT/BOOTX64.EFI   = shimx64.efi, Microsoft-signed (shim-signed pkg)
#       -> ::/EFI/BOOT/mmx64.efi      = MokManager (user enrols our cert into the MOK)
#       -> ::/EFI/BOOT/grubx64.efi    = GRUB, signed with OUR key  (MOK-trusted)
#       -> ::/boot/bzImage            = kernel, signed with OUR key
#
# ::/EFI/ubuntu/grubx64.efi gets a second copy of the signed GRUB because that is
# shim's compiled-in fallback loader path (belt and braces alongside ::/EFI/BOOT).
#
# The user must enrol our certificate into the MOK exactly once (see
# README_SECURE_BOOT.md); from then on this is the default, SB-on path.
#
# SECURE_BOOT=0 reproduces the previous layout exactly (one unsigned
# ::/EFI/BOOT/BOOTX64.EFI, unsigned kernel) as a way out if a machine refuses
# to enrol or boot the MOK.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECURE_BOOT="${SECURE_BOOT:-1}"
SB_KEYS_DIR="${SB_KEYS_DIR:-$SCRIPT_DIR/sb_keys}"
GEN_SB_KEYS="${GEN_SB_KEYS:-$SCRIPT_DIR/gen_sb_keys.sh}"
SB_LOG="$OUTDIR/sbverify.log"
# Microsoft-signed shim; auto-detected below.  Override SHIM_SRC to point at one.
SHIM_SRC="${SHIM_SRC:-}"
MOKMGR_SRC="${MOKMGR_SRC:-/usr/lib/shim/mmx64.efi}"

# ------------------------------------------------------------------ bootloader
# GRUB_SOURCE=ours (DEFAULT): use the SELF-BUILT GRUB 2.14
#   (device/pc/ptl/grub/build_grub.sh -> pristine upstream 2.14 + the OHOS
#   patches + a .sbat section, signed with the project MOK key).
#
#   This is REQUIRED for Secure Boot: the distribution GRUB (Ubuntu/Debian
#   2.14) has the "legacy shim_lock" kernel loader fallback removed by
#   debian/patches/secure-boot/disable-efi-fallback-to-legacy.patch, so it
#   asks the *firmware* to load the kernel.  The firmware only trusts its db,
#   so a kernel signed with our MOK only certificate fails with
#   "error: cannot load image.".  Our GRUB keeps the fallback, i.e. GRUB
#   loads the kernel itself (EFI handover) after shim verified it with the
#   MOK - the firmware db never needs our certificate.
#
# GRUB_SOURCE=system: fall back to the host grub-mkimage (Ubuntu).  Only for
#   A/B comparison / debugging - do NOT ship this for Secure Boot.
GRUB_SOURCE="${GRUB_SOURCE:-ours}"
GRUB_REPO_DIR="${GRUB_REPO_DIR:-$ROOT/device/pc/ptl/grub}"
GRUB_WORK="${GRUB_WORK:-$ROOT/out/x86_64_virt/ohos-dbg/partdisk/grub}"
GRUB_DIST="${GRUB_DIST:-$GRUB_WORK/dist}"

mkdir -p "$OUTDIR" "$WORK"
for f in bzImage ramdisk.img system.img vendor.img sys_prod.img chip_prod.img userdata.img; do
    [ -f "$IMAGES/$f" ] || { echo "ERROR: missing $IMAGES/$f"; exit 1; }
done
[ -f "$PART_INIT_SRC" ] || { echo "ERROR: missing $PART_INIT_SRC"; exit 1; }

echo "== make_partition_disk =="
echo "IMAGES=$IMAGES HARDWARE=$HARDWARE OUTDIR=$OUTDIR NAME=$NAME"

# ---------------------------------------------------------------- kernel modules
# MODULES_STAGE (optional): directory with freshly built *.ko + load_order.txt
# (see fix_xehpd/build_modules_and_stage.sh).  The modules are spliced into a
# private copy of system.img at /system/lib/modules, where the OHOS init service
# zz_drmmod.sh loads them at boot (boot_init in the kernel built-in initramfs is
# not used for modules on this product).  This is how a rebuilt kernel reaches
# the real machine.  Without it the existing modules in $IMAGES/system.img are
# left untouched.
#
# The kernel build now stages the board's curated module closure automatically
# (kernel/linux/build/kernel.mk -> ohos_stage_modules.sh -> <OBJ>/modules_stage);
# pick that up when MODULES_STAGE is not given explicitly.
KERNEL_VERSION="${KERNEL_VERSION:-linux-7.2}"
AUTO_MODULES_STAGE="$ROOT/out/KERNEL_OBJ/kernel/OBJ/$KERNEL_VERSION/modules_stage"
# In ESP_ONLY mode only p1 (the ESP) is rewritten; p2/system.img is left alone,
# so splicing modules into a copy of system.img would be pure waste (2 GB copy
# + debugfs + e2fsck).  Skip it.
if [ "${ESP_ONLY:-0}" = "1" ]; then
    MODULES_STAGE=""
    echo "== ESP_ONLY: skipping kernel-module splice (p2/system is not rewritten) =="
elif [ -z "${MODULES_STAGE:-}" ] && [ -f "$AUTO_MODULES_STAGE/load_order.txt" ]; then
    MODULES_STAGE="$AUTO_MODULES_STAGE"
    echo "== auto-detected kernel modules staged by the build: $MODULES_STAGE =="
fi
SYSTEM_IMG="$IMAGES/system.img"
if [ -n "${MODULES_STAGE:-}" ]; then
    [ -d "$MODULES_STAGE" ] || { echo "ERROR: MODULES_STAGE=$MODULES_STAGE is not a directory"; exit 1; }
    [ -f "$MODULES_STAGE/load_order.txt" ] || { echo "ERROR: $MODULES_STAGE/load_order.txt missing"; exit 1; }
    echo "== splicing modules from $MODULES_STAGE into a system.img copy =="
    SYSTEM_IMG="$WORK/system_mod.img"
    cp --sparse=always -f "$IMAGES/system.img" "$SYSTEM_IMG"
    {
        for ko in "$MODULES_STAGE"/*.ko; do
            b=$(basename "$ko")
            echo "rm /system/lib/modules/$b"
            echo "write $ko /system/lib/modules/$b"
            echo "sif /system/lib/modules/$b mode 0100644"
            echo "sif /system/lib/modules/$b uid 0"
            echo "sif /system/lib/modules/$b gid 0"
        done
        echo "rm /system/lib/modules/load_order.txt"
        echo "write $MODULES_STAGE/load_order.txt /system/lib/modules/load_order.txt"
        echo "sif /system/lib/modules/load_order.txt mode 0100644"
        echo "sif /system/lib/modules/load_order.txt uid 0"
        echo "sif /system/lib/modules/load_order.txt gid 0"
        # drop DRM modules present in the image but not shipped by the new stage
        for old in i915.ko drm_display_helper.ko ttm.ko drm_buddy.ko drm_gpusvm_helper.ko \
                   drm_exec.ko drm_gpuvm.ko gpu-sched.ko drm_suballoc_helper.ko drm_ttm_helper.ko xe.ko; do
            [ -e "$MODULES_STAGE/$old" ] || echo "rm /system/lib/modules/$old"
        done
    } | debugfs -w "$SYSTEM_IMG" >> "$OUTDIR/modules_inject.log" 2>&1 || true
    e2fsck -f -y "$SYSTEM_IMG" >> "$OUTDIR/modules_inject.log" 2>&1 || true
    echo "system image with modules: $(stat -c%s "$SYSTEM_IMG") bytes sha=$(sha256sum "$SYSTEM_IMG" | cut -d' ' -f1)"
fi

# ---------------------------------------------------------------- sizes
sz_of() { stat -c %s "$IMAGES/$1.img"; }
SZ_SYSTEM=$(sz_of system)
SZ_VENDOR=$(sz_of vendor)
SZ_SYSPROD=$(sz_of sys_prod)
SZ_CHIPPROD=$(sz_of chip_prod)
SZ_USERDATA=$(sz_of userdata)
MIB_CEIL() { echo $(( ($1 + MIB - 1) / MIB )); }
P2_MIB=$(MIB_CEIL "$SZ_SYSTEM")
P3_MIB=$(MIB_CEIL "$SZ_VENDOR")
P4_MIB=$(MIB_CEIL "$SZ_SYSPROD")
P5_MIB=$(MIB_CEIL "$SZ_CHIPPROD")
P6_MIB=$(( $(MIB_CEIL "$SZ_USERDATA") + USR_EXTRA_MIB ))
# ext4 size actually written into p6.  In SMALL_IMAGE mode it stays at the stock
# userdata.img size; the GPT still declares P6_MIB so first boot grows it.
P6_EXT4_MIB="${P6_EXT4_MIB:-$(MIB_CEIL "$SZ_USERDATA")}"
echo "sizes(MiB): p2=$P2_MIB p3=$P3_MIB p4=$P4_MIB p5=$P5_MIB p6_declare=$P6_MIB p6_ext4=$P6_EXT4_MIB SMALL_IMAGE=$SMALL_IMAGE"

# ---------------------------------------------------------------- part_init + ramdisk
echo "== compiling static part_init =="
gcc -static -O2 -Wall -o "$OUTDIR/part_init" "$PART_INIT_SRC"
echo "part_init: $(stat -c%s "$OUTDIR/part_init") bytes sha=$(sha256sum "$OUTDIR/part_init" | cut -d' ' -f1)"

echo "== building custom initramfs (stock init + firmware + part_init) =="
EX="$WORK/initramfs_extra"
rm -rf "$EX"; mkdir -p "$EX"

# --- build-time assertion helpers ---------------------------------------------
# The ramdisk is the ONLY place the built-in SOF PCI driver can find its
# firmware (it probes in the initcall phase, before /system is mounted), so a
# missing file here means "no sof-hda-dsp card on the real machine" and must
# fail the build instead of silently shipping a broken image.
CPIO_LIST="$SCRIPT_DIR/tools/cpio_list.py"
SOF_REQUIRED_FILES="lib/firmware/intel/sof-ipc4/ptl/sof-ptl.ri
lib/firmware/intel/sof-ipc4/ptl/sof-ptl-openmodules.ri
lib/firmware/intel/sof-ipc4-tplg/sof-hda-generic-4ch.tplg
lib/firmware/intel/sof-ipc4-tplg/sof-ptl-rt722-l0-rt1320-l23.tplg"
SOF_MIN_TPLG=10

assert_ramdisk_has_sof() {
    local ramdisk="$1"
    local lst="$WORK/ramdisk_listing.txt"
    local missing=0 f n
    if [ ! -f "$CPIO_LIST" ]; then
        echo "ERROR: missing cpio lister $CPIO_LIST"; exit 1
    fi
    if ! python3 "$CPIO_LIST" "$ramdisk" > "$lst" 2>"$WORK/ramdisk_listing.err"; then
        echo "ERROR: cannot list ramdisk $ramdisk"; exit 1
    fi
    for f in $SOF_REQUIRED_FILES; do
        if ! grep -qx "$f" "$lst"; then
            echo "ERROR: ramdisk is missing $f"
            missing=1
        fi
    done
    n=$(grep -c '^lib/firmware/intel/sof-ipc4-tplg/.*\.tplg$' "$lst" || true)
    if [ "$n" -lt "$SOF_MIN_TPLG" ]; then
        echo "ERROR: ramdisk has only $n SOF topologies in lib/firmware/intel/sof-ipc4-tplg (need >= $SOF_MIN_TPLG)"
        missing=1
    fi
    if [ "$missing" != "0" ]; then
        echo "--- ramdisk listing (firmware) ---"
        grep '^lib/firmware' "$lst" | head -40
        echo "ERROR: SOF firmware incomplete in the ramdisk - build aborted"
        exit 1
    fi
    echo "ramdisk assertion OK: SOF fw + $n topologies present under lib/firmware/intel/"
}

cp "$OUTDIR/part_init" "$EX/part_init"; chmod 0755 "$EX/part_init"
if [ -d "$FW_DIR" ]; then
    mkdir -p "$EX/lib/firmware"; cp -a "$FW_DIR/." "$EX/lib/firmware/"; rm -f "$EX/lib/firmware/BUILD.gn"
fi

# --- SOF / IPC4 firmware: explicit staging + build-time assertion --------------
# The in-tree SOF IPC4 driver (sound/soc/sof/intel/pci-ptl.c:42-53) asks the
# firmware loader for
#     intel/sof-ipc4/ptl/sof-ptl.ri
#     intel/sof-ipc4/ptl/sof-ptl-openmodules.ri   (split release, ipc4-loader.c:296)
#     intel/sof-ipc4-tplg/<topology>.tplg
# The kernel search roots are the cmdline `firmware_class.path`
# (/system/lib/firmware) and then /lib/firmware
# (drivers/base/firmware_loader/main.c:471-478), so the ramdisk has to carry
# them as lib/firmware/intel/... - the `intel/` prefix is part of the path.
# The SOF PCI driver is built-in (CONFIG_SND_SOC_SOF_INTEL_PTL=y) and probes in
# the initcall phase, i.e. *before* /system is mounted: the initrd is the only
# place the firmware can come from at that moment.
SOF_FW_SUBDIRS="intel/sof-ipc4/ptl intel/sof-ipc4-tplg"
for d in $SOF_FW_SUBDIRS; do
    if [ ! -d "$FW_DIR/$d" ]; then
        echo "ERROR: missing SOF firmware dir $FW_DIR/$d"
        echo "       (need sof-ptl.ri / sof-ptl-openmodules.ri / *.tplg there)"
        exit 1
    fi
    mkdir -p "$EX/lib/firmware/$d"
    cp -a "$FW_DIR/$d/." "$EX/lib/firmware/$d/"
done
( cd "$EX" && find . -type f -print | sed 's|^\./||' | cpio -o -H newc --quiet ) > "$WORK/extra.cpio"
zcat "$IMAGES/ramdisk.img" > "$WORK/base.cpio"

# ACPI override must be a *raw, uncompressed* newc cpio in front of the gzip'd
# main initramfs (classic Intel "early initrd" layout).  acpi_table_upgrade()
# scans the raw initrd with find_cpio_data() before populate_rootfs() runs, so a
# compressed archive (or a cpio appended after the gzip) would NOT be found.
[ -f "$ACPI_OVERRIDE_SRC" ] || { echo "ERROR: missing ACPI override $ACPI_OVERRIDE_SRC"; exit 1; }
rm -rf "$WORK/acpi_ov_tree"; mkdir -p "$WORK/acpi_ov_tree/kernel/firmware/acpi"
cp "$ACPI_OVERRIDE_SRC" "$WORK/acpi_ov_tree/kernel/firmware/acpi/SSDT27_TPD0.aml"
( cd "$WORK/acpi_ov_tree" && find kernel -type f -print | cpio -o -H newc --quiet ) > "$WORK/acpi_override.cpio"
cat "$WORK/acpi_ov_tree/kernel/firmware/acpi/SSDT27_TPD0.aml" | \
    cmp -s - "$ACPI_OVERRIDE_SRC" || { echo "ERROR: ACPI override copy mismatch"; exit 1; }
cat "$WORK/base.cpio" "$WORK/extra.cpio" | gzip -9 > "$WORK/main_ramdisk.gz"
cat "$WORK/acpi_override.cpio" "$WORK/main_ramdisk.gz" > "$RAMDISK"
echo "ramdisk: $RAMDISK ($(stat -c%s "$RAMDISK") bytes; head=+$(stat -c%s "$WORK/acpi_override.cpio")B ACPI cpio)"
# head must be a raw newc cpio (starts with '070701'), not gzip
[ "$(head -c6 "$RAMDISK")" = "070701" ] || { echo "ERROR: ramdisk does not start with raw cpio"; exit 1; }
grep -a -q 'kernel/firmware/acpi/SSDT27_TPD0.aml' "$RAMDISK" || { echo "ERROR: ACPI table not in ramdisk head"; exit 1; }
# build-time assertion: the SOF firmware must be in the ramdisk
assert_ramdisk_has_sof "$RAMDISK"

# ---------------------------------------------------------------- build id + grub.cfg
# '\$' must reach grub.cfg literally, otherwise GRUB expands $0x.. as a positional
# variable and memmap=1M$0x7e000000 becomes memmap=1M (deletes/renumbers RAM).
# The memmap value is carried in a shell variable, so the '\$' survives the
# (unquoted) heredoc expansion below and reaches grub.cfg as a single backslash.
CMDLINE_RAMOOPS="memmap=1M\\\$0x7e000000 ramoops.mem_address=0x7e000000 ramoops.mem_size=0x100000 ramoops.console_size=0x80000"

# Kept on EVERY diagnostic entry (task requirement):
#   panic=-1            -> on panic do NOT reboot, hang (screen keeps last output)
#   nmi_watchdog=0      -> disable hard-lockup detector (watchdog_hardlockup_user_enabled=0)
#   softlockup_panic=0  -> soft lockups only warn, never panic->reboot
#   quiet + loglevel=4  -> keep the console terse but let KERN_ERR and below
#                          through: COMPKMSG uses <3>, so it still prints on
#                          tty0, while the info/debug flood is suppressed.
#   keep_bootcon/console=tty0 (NO ttyS0: the real PTL box has no serial)
CMDLINE_FREEZE="panic=-1 nmi_watchdog=0 softlockup_panic=0 quiet loglevel=4 console=tty0 earlycon=efifb keep_bootcon rdinit=/part_init root=/dev/ram0 rw firmware_class.path=/system/lib/firmware"
# xe display/idle workarounds (Arch/Intel reports: xe randomly freezes / goes
# black with PSR/SAGV enabled on PTL).  intel_idle.max_cstate=1 avoids deep
# C-state stalls while bringing the display up.  The previous
# "drm_kms_helper.poll=0" is deliberately REMOVED: it disables the DRM output
# poll work, which can leave eDP parked at connector_status=unknown - that is
# exactly the intermittent no-display case now handled in DiscoveryDisplay().
# printk.devkmsg=on disables the per-/dev/kmsg-fd userspace ratelimit
# (printk.c devkmsg_write -> ___ratelimit, default 10 msgs / 5 s).  Without it
# the COMPKMSG burst during DRM discovery silently drops SESSION/DRV lines.
# i8042.dumbkbd=1: the built-in PS/2 keyboard on this HONOR/PTL EC is detected as
# "AT Translated Set 2 keyboard" but only delivers scancodes when the driver does
# NOT try to drive the controller/LEDs (Ubuntu on the same laptop boots with it).
CMDLINE_KEEP="log_buf_len=4M sysrq_always_enabled=1 split_lock_detect=off xe.enable_psr=0 xe.enable_sagv=0 intel_idle.max_cstate=1 printk.devkmsg=on i8042.dumbkbd=1"

# Split the mount list so the "[D] DATA=tmpfs" entry can drop ONLY the data
# token while keeping everything else identical to [2].
CMDLINE_MOUNT_HEAD="sn=0123456789 hardware=${HARDWARE}"
CMDLINE_MOUNT_HEAD="$CMDLINE_MOUNT_HEAD ohos.required_mount.system=/dev/block/by-name/system@/usr@ext4@ro,barrier=1@wait,required"
CMDLINE_MOUNT_HEAD="$CMDLINE_MOUNT_HEAD ohos.required_mount.vendor=/dev/block/by-name/vendor@/vendor@ext4@ro,barrier=1@wait,required"
CMDLINE_MOUNT_HEAD="$CMDLINE_MOUNT_HEAD ohos.required_mount.sys_prod=/dev/block/by-name/sys_prod@/sys_prod@ext4@rw,barrier=1@wait,required"
CMDLINE_MOUNT_HEAD="$CMDLINE_MOUNT_HEAD ohos.required_mount.chip_prod=/dev/block/by-name/chip_prod@/chip_prod@ext4@rw,barrier=1@wait,required"
# NOTE: "required" is essential.  Without it, init's first-stage required pass
# skips this entry (fstab_mount.c CheckRequiredAndMount), and /data used to be
# mounted only as a side effect of "mount_fstab_sp /vendor/etc/fstab.<hw>" in
# pre-init.  Since the [D] tmpfs variant must remove the /data line from the
# vendor fstab (shared by all entries), the baseline entries now mount /data
# from the cmdline instead, so they must carry the "required" flag.
CMDLINE_MOUNT_DATA="ohos.required_mount.data=/dev/block/by-name/userdata@/data@ext4@nosuid,nodev,noatime,barrier=1,data=ordered,noauto_da_alloc@wait,required,reservedsize=104857600"
# Keep a non-required token LAST: LoadFstabFromCommandLine only sets isDone for
# tokens followed by a space, so a required_mount as the very last token of the
# whole cmdline would be parsed but discarded.
CMDLINE_MOUNT_TAIL="ohos.boot.hardware=${HARDWARE}"

CMDLINE_MOUNT="${CMDLINE_MOUNT_HEAD} ${CMDLINE_MOUNT_DATA} ${CMDLINE_MOUNT_TAIL}"
# [D]: /data becomes tmpfs (part_init mounts it), the real userdata is only
# used as a persistent log store at /ohoslog. "ptl.data=tmpfs" is a harmless
# unknown token used as a marker/selector.
CMDLINE_MOUNT_TMPFS="${CMDLINE_MOUNT_HEAD} ptl.data=tmpfs ${CMDLINE_MOUNT_TAIL}"

CMDLINE_COMMON="${CMDLINE_KEEP} ${CMDLINE_FREEZE} ${CMDLINE_MOUNT}"
CMDLINE_COMMON_TMPFS="${CMDLINE_KEEP} ${CMDLINE_FREEZE} ${CMDLINE_MOUNT_TMPFS}"
CMDLINE_BASELINE="${CMDLINE_RAMOOPS} ${CMDLINE_COMMON}"

# GRUB is built with grub-mkimage (NOT grub-mkstandalone): the config is a normal
# file on the ESP (/boot/grub/grub.cfg), so users can edit it on Ubuntu without
# re-dd'ing the whole disk.  Modules below are embedded so the external config
# only needs to run commands, not load modules from disk.
GRUB_MODULES="part_gpt part_msdos fat ext2 normal linux search search_fs_file search_label configfile echo test all_video efi_gop font gfxterm videoinfo video_bochs video_cirrus terminal png jpeg ls cat sleep halt reboot minicmd"

GRUB_CFG="$WORK/grub.cfg"
cat > "$GRUB_CFG" <<EOF
insmod part_gpt
insmod part_msdos
insmod fat
insmod ext2
insmod linux
insmod normal
insmod search
insmod search_fs_file
insmod search_label
search --no-floppy --file --set=root /boot/ramdisk_bootmedia.img
set timeout=2
set default=0

# fix_desktop_bt_grub: simplified menu.  Two entries only:
#   [0] DEFAULT persistent /data (normal boot)
#   [1] DEBUG   verbose console (same cmdline + ignore_loglevel loglevel=8)
# All previous diagnostic and alternative-/data entries were removed.
# /data is ALWAYS the persistent p6 ext4 now.
menuentry "OpenHarmony PC (persistent /data)  DEFAULT" {
    linux /boot/bzImage ${CMDLINE_COMMON}
    initrd /boot/ramdisk_bootmedia.img
}

menuentry "OpenHarmony PC (debug: verbose console)" {
    linux /boot/bzImage ${CMDLINE_COMMON} ignore_loglevel loglevel=8
    initrd /boot/ramdisk_bootmedia.img
}
EOF

BUILD_TIME_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILD_TIME_LOCAL="$(date '+%Y-%m-%d %H:%M:%S %z')"
GRUB_SHA256="$(sha256sum "$GRUB_CFG" | cut -d' ' -f1)"
BUILD_ID="$(date -u +%Y%m%d-%H%M%S)-$(printf '%s' "$GRUB_SHA256" | cut -c1-12)"
cat > "$BUILD_ID_FILE" <<EOF
BUILD_ID=$BUILD_ID
BUILD_TIME_UTC=$BUILD_TIME_UTC
BUILD_TIME_LOCAL=$BUILD_TIME_LOCAL
HARDWARE=$HARDWARE
GRUB_CFG_SHA256=$GRUB_SHA256
BUILD_SCRIPT=make_partition_disk.sh
IMAGES=$IMAGES
EOF
echo "BUILD_ID=$BUILD_ID"

# ---------------------------------------------------------------- stamp system.img
if [ "${ESP_ONLY:-0}" != "1" ]; then
    echo "== stamping /system/etc/ohos_build_id into system.img =="
    {
        echo "rm /system/etc/ohos_build_id"
        echo "write $BUILD_ID_FILE /system/etc/ohos_build_id"
        echo "sif /system/etc/ohos_build_id mode 0100644"
        echo "sif /system/etc/ohos_build_id uid 0"
        echo "sif /system/etc/ohos_build_id gid 0"
    } | debugfs -w "$SYSTEM_IMG" > "$OUTDIR/buildid_debugfs.log" 2>&1 || true
    BID="$WORK/ohos_build_id.from_img"; rm -f "$BID"
    debugfs -R "dump /system/etc/ohos_build_id $BID" "$SYSTEM_IMG" >/dev/null 2>&1
    cmp -s "$BUILD_ID_FILE" "$BID" || { echo "ERROR: build-id write failed"; exit 1; }
    e2fsck -f -y "$SYSTEM_IMG" > "$OUTDIR/buildid_e2fsck.log" 2>&1 || true
    echo "build-id verified in system.img"
fi

# ---------------------------------------------------------------- userdata (resize to fill)
UD="$WORK/userdata_fill.img"
if [ "${ESP_ONLY:-0}" != "1" ]; then
    rm -f "$UD"
    if [ "$SMALL_IMAGE" = "1" ]; then
        echo "== preparing userdata (SMALL: keep stock ${P6_EXT4_MIB} MiB ext4; GPT declares ${P6_MIB} MiB; init resize2fs grows on first boot) =="
        cp --sparse=always "$IMAGES/userdata.img" "$UD"
        e2fsck -f -p "$UD" > "$OUTDIR/userdata_e2fsck_pre.log" 2>&1 || true
    else
        echo "== preparing userdata (${P6_MIB} MiB, img + ${USR_EXTRA_MIB} MiB, resize2fs) =="
        cp --sparse=always "$IMAGES/userdata.img" "$UD"
        truncate -s "$(( P6_MIB * MIB ))" "$UD"
        e2fsck -f -p "$UD" > "$OUTDIR/userdata_e2fsck_pre.log" 2>&1 || true
        resize2fs "$UD" > "$OUTDIR/userdata_resize.log" 2>&1
        e2fsck -f -p "$UD" > "$OUTDIR/userdata_e2fsck_post.log" 2>&1 || true
    fi
    echo "userdata_fill: $(stat -c%s "$UD") bytes"
fi

# ---------------------------------------------------------------- ESP (FAT32 + GRUB)
echo "== building ESP (FAT32 + GRUB, config EXTERNAL at /boot/grub/grub.cfg) =="
BOOTX="$WORK/BOOTX64.EFI"
# SBAT metadata for the GRUB core.
#
# shim (>= 15.x, e.g. Ubuntu's shim 15.8) refuses to load a second stage that
# has NO .sbat PE section:
#     pe.c:348:verify_sbat_section() No .sbat section data
#     -> EFI_SECURITY_VIOLATION  ("SBAT is mandatory for binaries loaded by shim")
# So the GRUB we ship must carry an .sbat section.  The generation number must be
# >= the one listed in the firmware's "sbat" variable (shim compares
# component_generation < sbat_var_generation -> revoked), so we declare a
# deliberately high generation.  Format (6 CSV columns, see shim's pe.c):
#     component,generation,vendor_name,vendor_package,vendor_version,vendor_url
SBAT_FILE="$WORK/grub.sbat"
cat > "$SBAT_FILE" <<EOF
sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
grub,${SBAT_GENERATION:-100},OpenHarmony GRUB,grub,1,https://www.ohos.org/
EOF

# --------------------------------------------------------- Secure Boot signing
GRUB_EFI=""                        # what actually lands at the loader path
KERNEL="$IMAGES/bzImage"           # what actually lands at /boot/bzImage
BOOTLOADER_NAME="BOOTX64.EFI"     # ::/EFI/BOOT/ file the firmware starts
: > "$SB_LOG"

# sb_verify <file> <label> -- append sbverify --list to $SB_LOG, succeed iff the
# image carries at least one Authenticode signature.
sb_verify() {
    local f="$1" lbl="$2" out
    out="$(sbverify --list "$f" 2>&1)" || true
    { echo "===== $lbl"; echo "file: $f"; echo "$out"; echo; } >> "$SB_LOG"
    printf '%s' "$out" | grep -q '^signature' \
        || { echo "ERROR: $lbl has NO Secure Boot signature: $f"; return 1; }
    echo "  sbverify OK: $lbl"
}

if [ "$SECURE_BOOT" = "1" ]; then
    command -v sbsign  >/dev/null || { echo "ERROR: sbsign not found"; exit 1; }
    command -v sbverify>/dev/null || { echo "ERROR: sbverify not found"; exit 1; }
    bash "$GEN_SB_KEYS" > "$OUTDIR/gen_sb_keys.log" 2>&1 \
        || { echo "ERROR: gen_sb_keys.sh failed"; cat "$OUTDIR/gen_sb_keys.log"; exit 1; }
    SB_KEY="$SB_KEYS_DIR/ohos-uefi.key"
    SB_CRT="$SB_KEYS_DIR/ohos-uefi.crt"
    for f in "$SB_KEY" "$SB_CRT"; do
        [ -f "$f" ] || { echo "ERROR: missing SB key material: $f"; exit 1; }
    done

    # ---- pick the Microsoft-signed shim (Debian ships several variants; only
    # shimx64.efi.signed* carry the Microsoft Corporation UEFI CA 2011 chain).
    if [ -z "$SHIM_SRC" ]; then
        for c in /usr/lib/shim/shimx64.efi.signed \
                 /usr/lib/shim/shimx64.efi.signed.latest \
                 /usr/lib/shim/shimx64.nx.efi.signed.latest \
                 /usr/lib/shim/shimx64.efi.dualsigned; do
            [ -f "$c" ] || continue
            if sbverify --list "$c" 2>/dev/null | grep -q "Microsoft Corporation UEFI CA"; then
                SHIM_SRC="$c"; break
            fi
        done
    fi
    [ -n "$SHIM_SRC" ] && [ -f "$SHIM_SRC" ] \
        || { echo "ERROR: no Microsoft-signed shim found (install the 'shim-signed' package, or set SHIM_SRC=)"; exit 1; }
    [ -f "$MOKMGR_SRC" ] \
        || { echo "ERROR: MokManager missing: $MOKMGR_SRC"; exit 1; }
    echo "Secure Boot: shim=$SHIM_SRC mokmanager=$MOKMGR_SRC"
else
    echo "Secure Boot: DISABLED (SECURE_BOOT=0) - unsigned loader, unsigned kernel"
    { echo "===== SECURE_BOOT=0: no signatures built (expected)"; } >> "$SB_LOG"
fi

# ---------------------------------------------------------------- bootloader
# The bootloader is the self-built GRUB 2.14 (upstream + the OHOS patches +
# .sbat section).  See device/pc/ptl/grub/README.md for the rationale.
if [ "$GRUB_SOURCE" = "ours" ]; then
    echo "== bootloader: self-built GRUB 2.14 ($GRUB_REPO_DIR/build_grub.sh) =="
    [ -f "$GRUB_REPO_DIR/build_grub.sh" ] \
        || { echo "ERROR: missing $GRUB_REPO_DIR/build_grub.sh"; exit 1; }
    bash "$GRUB_REPO_DIR/build_grub.sh" > "$OUTDIR/build_grub.log" 2>&1 \
        || { echo "ERROR: build_grub.sh failed (see $OUTDIR/build_grub.log)";
             tail -30 "$OUTDIR/build_grub.log"; exit 1; }
    GRUB_RAW="$GRUB_DIST/grubx64.efi"
    GRUB_PRESIGNED="$GRUB_DIST/grubx64.efi.signed"
    [ -f "$GRUB_RAW" ] || { echo "ERROR: $GRUB_RAW missing after build"; exit 1; }
    cp -f "$GRUB_RAW" "$BOOTX"
    echo "BOOTX64.EFI (self-built GRUB core): $(stat -c%s "$BOOTX") bytes (external-config GRUB, no embedded menu)"
else
    echo "== bootloader: host grub-mkimage (GRUB_SOURCE=system) =="
    # -p /boot/grub: embedded prefix; at boot GRUB loads (\$root)/boot/grub/grub.cfg,
    # which is the editable normal file on the ESP (not embedded in the EFI binary).
    # -s <file>: embed the SBAT metadata as a .sbat section (mandatory for shim).
    grub-mkimage -O x86_64-efi -o "$BOOTX" -p /boot/grub -s "$SBAT_FILE" $GRUB_MODULES \
        > "$OUTDIR/grub-mkimage.log" 2>&1
    [ -f "$BOOTX" ] || { echo "ERROR: grub-mkimage failed"; cat "$OUTDIR/grub-mkimage.log"; exit 1; }
    echo "BOOTX64.EFI (host GRUB core): $(stat -c%s "$BOOTX") bytes (external-config GRUB, no embedded menu)"
fi
if ! objdump -h "$BOOTX" 2>/dev/null | grep -q '\.sbat'; then
    echo "ERROR: GRUB has no .sbat section (shim would refuse to load it)"; exit 1
fi
echo "GRUB .sbat section: OK ($(stat -c%s "$SBAT_FILE") bytes of metadata)"

if [ "$SECURE_BOOT" = "1" ]; then
    if [ "$GRUB_SOURCE" = "ours" ]; then
        # build_grub.sh already signed the core with the very same MOK key
        GRUB_SIG="$GRUB_PRESIGNED"
        [ -f "$GRUB_SIG" ] || { echo "ERROR: signed GRUB missing: $GRUB_SIG"; exit 1; }
    else
        GRUB_SIG="$WORK/grubx64.efi.signed"
        rm -f "$GRUB_SIG"
        sbsign --key "$SB_KEY" --cert "$SB_CRT" --output "$GRUB_SIG"   "$BOOTX"            >> "$SB_LOG" 2>&1
        [ -f "$GRUB_SIG" ] || { echo "ERROR: sbsign failed for GRUB (see $SB_LOG)"; exit 1; }
    fi
    KERNEL_SIG="$WORK/bzImage.signed"
    rm -f "$KERNEL_SIG"
    sbsign --key "$SB_KEY" --cert "$SB_CRT" --output "$KERNEL_SIG" "$IMAGES/bzImage"  >> "$SB_LOG" 2>&1
    [ -f "$KERNEL_SIG" ] || { echo "ERROR: sbsign failed for bzImage (see $SB_LOG)"; exit 1; }

    # ---- build-time self check: every image on the trust path must verify
    sb_verify "$SHIM_SRC"     "shim (firmware db -> shim)"  || exit 1
    sb_verify "$GRUB_SIG"     "grubx64.efi (MOK -> grub)"  || exit 1
    sb_verify "$KERNEL_SIG"   "bzImage (grub -> kernel)"   || exit 1
    echo "  GRUB  signed: $(stat -c%s "$GRUB_SIG") bytes (raw $(( $(stat -c%s "$BOOTX") )))"
    echo "  kernel signed: $(stat -c%s "$KERNEL_SIG") bytes (raw $(stat -c%s "$IMAGES/bzImage"))"
    GRUB_EFI="$GRUB_SIG"
    KERNEL="$KERNEL_SIG"
    BOOTLOADER_NAME="BOOTX64.EFI"
    echo "  signature log: $SB_LOG"
else
    GRUB_EFI="$BOOTX"
fi

ESP_IMG="$WORK/esp.img"
rm -f "$ESP_IMG"
dd if=/dev/zero of="$ESP_IMG" bs=1M count=512 status=none
mkfs.vfat -F32 -n "${VOLID:0:11}" "$ESP_IMG" >/dev/null
mmd -i "$ESP_IMG" ::/EFI; mmd -i "$ESP_IMG" ::/EFI/BOOT
mmd -i "$ESP_IMG" ::/boot; mmd -i "$ESP_IMG" ::/boot/grub
mcopy -o -i "$ESP_IMG" "$GRUB_EFI" "::/EFI/BOOT/$BOOTLOADER_NAME"
if [ "$SECURE_BOOT" = "1" ]; then
    # shim's normal 2nd stage + its own fallback path, plus MokManager for
    # the one-time MOK enrolment.
    mcopy -o -i "$ESP_IMG" "$GRUB_EFI"   ::/EFI/BOOT/grubx64.efi
    mcopy -o -i "$ESP_IMG" "$SHIM_SRC"   ::/EFI/BOOT/BOOTX64.EFI
    mcopy -o -i "$ESP_IMG" "$MOKMGR_SRC" ::/EFI/BOOT/mmx64.efi
    mmd -i "$ESP_IMG" ::/EFI/ubuntu
    mcopy -o -i "$ESP_IMG" "$GRUB_EFI"   ::/EFI/ubuntu/grubx64.efi
fi
mcopy -o -i "$ESP_IMG" "$KERNEL" ::/boot/bzImage
mcopy -o -i "$ESP_IMG" "$RAMDISK" ::/boot/ramdisk_bootmedia.img
mcopy -o -i "$ESP_IMG" "$GRUB_CFG" ::/boot/grub/grub.cfg
mcopy -o -i "$ESP_IMG" "$BUILD_ID_FILE" ::/ohos_build_id
echo "esp.img: $(stat -c%s "$ESP_IMG") bytes"

# ---------------------------------------------------------------- assemble GPT disk
if [ "${ESP_ONLY:-0}" = "1" ] && [ -f "$DISK" ]; then
    echo "== ESP_ONLY: rewriting only p1 (keep existing partitions) =="
    P1S=$(sgdisk -p "$DISK" | awk '$1==1{print $2}')
    [ -n "$P1S" ] || { echo "ERROR: cannot find p1"; exit 1; }
    dd if="$ESP_IMG" of="$DISK" bs=512 seek="$P1S" conv=notrunc,fsync status=none
else
    echo "== assembling GPT disk =="
    # total = 1MiB (GPT head) + p1..p6 + 2MiB tail (backup GPT/alignment)
    TOTAL_MIB=$(( 1 + 512 + P2_MIB + P3_MIB + P4_MIB + P5_MIB + P6_MIB + 2 ))
    rm -f "$DISK"
    truncate -s "${TOTAL_MIB}M" "$DISK"
    sgdisk --zap-all "$DISK" >/dev/null 2>&1
    sgdisk \
        -n 1:2048:+512M      -t 1:ef00 -c 1:"${VOLID:0:11}" \
        -n 2:0:+${P2_MIB}M   -t 2:8300 -c 2:system \
        -n 3:0:+${P3_MIB}M   -t 3:8300 -c 3:vendor \
        -n 4:0:+${P4_MIB}M   -t 4:8300 -c 4:sys_prod \
        -n 5:0:+${P5_MIB}M   -t 5:8300 -c 5:chip_prod \
        -n 6:0:+${P6_MIB}M   -t 6:8300 -c 6:userdata \
        "$DISK" >/dev/null 2>&1
    sgdisk -p "$DISK" > "$OUTDIR/disk_layout.txt"
    P1S=$(awk '$1==1{print $2}' "$OUTDIR/disk_layout.txt")
    P2S=$(awk '$1==2{print $2}' "$OUTDIR/disk_layout.txt")
    P3S=$(awk '$1==3{print $2}' "$OUTDIR/disk_layout.txt")
    P4S=$(awk '$1==4{print $2}' "$OUTDIR/disk_layout.txt")
    P5S=$(awk '$1==5{print $2}' "$OUTDIR/disk_layout.txt")
    P6S=$(awk '$1==6{print $2}' "$OUTDIR/disk_layout.txt")
    for v in P1S P2S P3S P4S P5S P6S; do
        eval "[ -n \"\$$v\" ]" || { echo "ERROR: cannot parse partition table"; cat "$OUTDIR/disk_layout.txt"; exit 1; }
    done
    echo "p1=$P1S p2=$P2S p3=$P3S p4=$P4S p5=$P5S p6=$P6S"

    echo "== dd real images into partitions (this takes a bit) =="
    dd if="$ESP_IMG"                       of="$DISK" bs=512 seek="$P1S" conv=notrunc,fsync status=none
    dd if="$SYSTEM_IMG"                    of="$DISK" bs=512 seek="$P2S" conv=notrunc,fsync status=none
    dd if="$IMAGES/vendor.img"             of="$DISK" bs=512 seek="$P3S" conv=notrunc,fsync status=none
    dd if="$IMAGES/sys_prod.img"           of="$DISK" bs=512 seek="$P4S" conv=notrunc,fsync status=none
    dd if="$IMAGES/chip_prod.img"          of="$DISK" bs=512 seek="$P5S" conv=notrunc,fsync status=none
    dd if="$UD"                            of="$DISK" bs=512 seek="$P6S" conv=notrunc,fsync status=none
    sync
    # SMALL_IMAGE: keep only the primary GPT + p1..p5 + the small p6 ext4.
    # The GPT still declares p6 as P6_MIB (16 GiB); the backup GPT is dropped on
    # purpose (it points past the file end).  dd_and_verify.sh runs `sgdisk -e`
    # on the target disk, and OHOS init grows the ext4 to P6_MIB on first boot.
    if [ "$SMALL_IMAGE" = "1" ]; then
        TRUNC_BYTES=$(( P6S * 512 + P6_EXT4_MIB * MIB ))
        echo "== SMALL_IMAGE: truncating $DISK to $TRUNC_BYTES bytes (p6 start + ${P6_EXT4_MIB} MiB) =="
        truncate -s "$TRUNC_BYTES" "$DISK"
        sync
    fi
fi

# ---------------------------------------------------------------- assertions
echo "== self checks =="
DISK_BYTES="$(stat -c%s "$DISK")"
P1_SIG="$(dd if="$DISK" bs=512 skip=1 count=1 status=none | head -c8)"
[ "$P1_SIG" = "EFI PART" ] || { echo "ERROR: primary GPT missing"; exit 1; }
if [ "$SMALL_IMAGE" = "1" ]; then
    echo "disk_bytes=$DISK_BYTES primary_gpt_sig='$P1_SIG' (SMALL_IMAGE: backup GPT intentionally absent)"
else
    LAST_SIG="$(dd if="$DISK" bs=512 skip=$(( DISK_BYTES/512 - 1 )) count=1 status=none | head -c8)"
    echo "disk_bytes=$DISK_BYTES last_sector_sig='$LAST_SIG'"
    [ "$LAST_SIG" = "EFI PART" ] || { echo "ERROR: backup GPT missing at end of image"; exit 1; }
fi

sgdisk -p "$DISK" > "$OUTDIR/disk_layout.txt"
P6E=$(awk '$1==6{print $3}' "$OUTDIR/disk_layout.txt")
P6END_BYTES=$(( (P6E + 1) * 512 ))
if [ "$SMALL_IMAGE" = "1" ]; then
    # p6 is intentionally declared larger than the file; verify the *ext4* fits.
    P6S2=$(awk '$1==6{print $2}' "$OUTDIR/disk_layout.txt")
    EXT4_END_BYTES=$(( P6S2 * 512 + P6_EXT4_MIB * MIB ))
    [ "$DISK_BYTES" -ge "$EXT4_END_BYTES" ] || { echo "ERROR: disk smaller than p6 ext4"; exit 1; }
else
    [ "$DISK_BYTES" -ge "$P6END_BYTES" ] || { echo "ERROR: disk truncated (p6 end beyond file)"; exit 1; }
fi

# each partition must be >= its filesystem
declare -A FS_IMG=([system]="$SYSTEM_IMG" [vendor]="$IMAGES/vendor.img" \
                   [sys_prod]="$IMAGES/sys_prod.img" [chip_prod]="$IMAGES/chip_prod.img")
declare -A PARTNUM=([system]=2 [vendor]=3 [sys_prod]=4 [chip_prod]=5 [userdata]=6)
for part in system vendor sys_prod chip_prod userdata; do
    n=${PARTNUM[$part]}
    sect=$(awk -v n="$n" '$1==n{print $3-$2+1}' "$OUTDIR/disk_layout.txt")
    pbytes=$(( sect * 512 ))
    if [ "$part" = "userdata" ]; then
        # In ESP_ONLY mode $UD is never prepared; fall back to the stock image so
        # the size check still has something to read dumpe2fs from.
        if [ -f "$UD" ]; then src="$UD"; else src="$IMAGES/userdata.img"; fi
    else src="${FS_IMG[$part]}"; fi
    fsbytes=$(dumpe2fs -h "$src" 2>/dev/null | awk -F: '/^Block count/{gsub(/ /,"",$2);bc=$2} /^Block size/{gsub(/ /,"",$2);bs=$2} END{print bc*bs}')
    [ -n "$fsbytes" ] || { echo "ERROR: cannot read fs size of $src"; exit 1; }
    echo "p$n $part: part_bytes=$pbytes fs_bytes=$fsbytes margin=$((pbytes-fsbytes))"
    [ "$pbytes" -ge "$fsbytes" ] || { echo "ERROR: partition $part smaller than its fs"; exit 1; }
done

# build-id readbacks
# NOTE: in ESP_ONLY mode only p1 is rewritten; the existing system.img keeps
# its own (older) stamp, so skip the system.img readback then.
if [ "${ESP_ONLY:-0}" != "1" ]; then
    BID2="$WORK/ohos_build_id.from_system"; rm -f "$BID2"
    debugfs -R "dump /system/etc/ohos_build_id $BID2" "$SYSTEM_IMG" >/dev/null 2>&1
    cmp -s "$BUILD_ID_FILE" "$BID2" || { echo "ERROR: build-id not in system.img"; exit 1; }
fi
BID3="$WORK/ohos_build_id.from_esp"; rm -f "$BID3"
mcopy -o -i "$ESP_IMG" ::/ohos_build_id "$BID3" >/dev/null 2>&1
cmp -s "$BUILD_ID_FILE" "$BID3" || { echo "ERROR: build-id not in ESP"; exit 1; }
# --- fix_desktop_bt_grub: simplified menu = exactly 2 entries, [0] persistent /data is default
grep -q '^set default=0' "$GRUB_CFG" || { echo "ERROR: [0] is not the default entry"; exit 1; }
grep -q '^set timeout=2' "$GRUB_CFG" || { echo "ERROR: timeout is not 2"; exit 1; }
[ "$(grep -c '^menuentry ' "$GRUB_CFG")" = "2" ] || { echo "ERROR: expected exactly 2 menu entries"; exit 1; }
grep -q '^menuentry "OpenHarmony PC (persistent /data)' "$GRUB_CFG" || { echo "ERROR: persistent entry missing"; exit 1; }
grep -q '^menuentry "OpenHarmony PC (debug: verbose console)' "$GRUB_CFG" || { echo "ERROR: debug entry missing"; exit 1; }
# no tmpfs / ramoops / old diagnostic entries may remain
grep -Eq '^[[:space:]]*linux .*ptl.data=tmpfs' "$GRUB_CFG" && { echo "ERROR: tmpfs /data entry must be removed"; exit 1; } || true
grep -Eq '^[[:space:]]*linux .*ramoops' "$GRUB_CFG" && { echo "ERROR: ramoops entry must be removed"; exit 1; } || true
grep -Eq '^[[:space:]]*linux .*memmap=1M' "$GRUB_CFG" && { echo "ERROR: memmap entry must be removed"; exit 1; } || true
grep -Eq '^[[:space:]]*linux .*initcall_debug' "$GRUB_CFG" && { echo "ERROR: initcall_debug entry must be removed"; exit 1; } || true
grep -Eq '^[[:space:]]*linux .*mce=off' "$GRUB_CFG" && { echo "ERROR: mce=off entry must be removed"; exit 1; } || true
grep -Eq '^[[:space:]]*linux .*pci=noaer' "$GRUB_CFG" && { echo "ERROR: pci=noaer entry must be removed"; exit 1; } || true
# persistent entry MUST mount /data from cmdline (no tmpfs)
awk '/^menuentry "OpenHarmony PC \(persistent/{f=1} f{print} f&&/^}/{exit}' "$GRUB_CFG" > "$WORK/entry_persist.txt"
grep -q 'ohos.required_mount.data=' "$WORK/entry_persist.txt" || { echo "ERROR: persistent entry missing required_mount.data"; exit 1; }
grep -q 'ohos.required_mount.system=' "$WORK/entry_persist.txt" || { echo "ERROR: persistent entry missing system mount"; exit 1; }
# --- freeze params must be on every entry
grep -q 'panic=-1' "$GRUB_CFG" || { echo "ERROR: panic=-1 missing from grub.cfg"; exit 1; }
grep -q 'nmi_watchdog=0' "$GRUB_CFG" || { echo "ERROR: nmi_watchdog=0 missing from grub.cfg"; exit 1; }
grep -q 'softlockup_panic=0' "$GRUB_CFG" || { echo "ERROR: softlockup_panic=0 missing from grub.cfg"; exit 1; }
grep -q 'ignore_loglevel' "$GRUB_CFG" || { echo "ERROR: ignore_loglevel missing from grub.cfg"; exit 1; }
grep -q 'console=tty0' "$GRUB_CFG" || { echo "ERROR: console=tty0 missing from grub.cfg"; exit 1; }
# --- poll=0 must be GONE; xe workarounds + terse-but-COMPKMSG-visible console
grep -q 'drm_kms_helper.poll=0' "$GRUB_CFG" && { echo "ERROR: drm_kms_helper.poll=0 must be removed"; exit 1; } || true
grep -q 'xe.enable_psr=0' "$GRUB_CFG" || { echo "ERROR: xe.enable_psr=0 missing from grub.cfg"; exit 1; }
grep -q 'xe.enable_sagv=0' "$GRUB_CFG" || { echo "ERROR: xe.enable_sagv=0 missing from grub.cfg"; exit 1; }
grep -q 'printk.devkmsg=on' "$GRUB_CFG" || { echo "ERROR: printk.devkmsg=on missing from grub.cfg"; exit 1; }
grep -q 'i8042.dumbkbd=1' "$GRUB_CFG" || { echo "ERROR: i8042.dumbkbd=1 missing from grub.cfg"; exit 1; }
grep -q 'loglevel=4' "$GRUB_CFG" || { echo "ERROR: loglevel=4 missing from grub.cfg"; exit 1; }
grep -q 'quiet' "$GRUB_CFG" || { echo "ERROR: quiet missing from grub.cfg"; exit 1; }
# --- if modules were spliced, verify they are really in the image and load_order
if [ -n "${MODULES_STAGE:-}" ]; then
    debugfs -R "cat /system/lib/modules/load_order.txt" "$SYSTEM_IMG" 2>/dev/null | grep -qx 'xe.ko' \
        || { echo "ERROR: xe.ko missing from load_order in $SYSTEM_IMG"; exit 1; }
    debugfs -R "cat /system/lib/modules/load_order.txt" "$SYSTEM_IMG" 2>/dev/null | grep -qx 'i915.ko' \
        && { echo "ERROR: i915.ko still in load_order"; exit 1; } || true
    for ko in "$MODULES_STAGE"/*.ko; do
        b=$(basename "$ko")
        debugfs -R "stat /system/lib/modules/$b" "$SYSTEM_IMG" >/dev/null 2>&1 \
            || { echo "ERROR: $b not in system image"; exit 1; }
    done
    echo "module splice checks OK (load_order has xe.ko, no i915.ko)"
fi
grep -q 'rdinit=/part_init' "$GRUB_CFG" || { echo "ERROR: rdinit=/part_init missing from grub.cfg"; exit 1; }
grep -q 'console=ttyS0' "$GRUB_CFG" && { echo "ERROR: console=ttyS0 must not be present"; exit 1; } || true
# --- config must be EXTERNAL: not embedded in BOOTX64.EFI, present on ESP
if grep -aq 'NoRAMOOPS' "$BOOTX"; then
    echo "ERROR: BOOTX64.EFI embeds the menu (config must stay external)"; exit 1
fi
mcopy -o -i "$ESP_IMG" ::/boot/grub/grub.cfg "$WORK/grub_from_esp.cfg" >/dev/null 2>&1
cmp -s "$GRUB_CFG" "$WORK/grub_from_esp.cfg" || { echo "ERROR: ESP grub.cfg != generated grub.cfg"; exit 1; }
# --- Secure Boot: every artifact must be present on the ESP *and* still verify
#     after the FAT round-trip (mcopy does not corrupt, but assert anyway).
if [ "$SECURE_BOOT" = "1" ]; then
    # NOTE: existence must be probed with mcopy, not mdir -- mdir prints the
    # FAT 8.3 short name ("BOOTX64"), never the VFAT long name ("BOOTX64.EFI"),
    # so a grep on the long name always fails.
    esp_exists() {
        local p="$1" t="$WORK/.esp_exists.bin"
        rm -f "$t"
        mcopy -o -i "$ESP_IMG" "$p" "$t" >/dev/null 2>&1 || { rm -f "$t"; return 1; }
        rm -f "$t"; return 0
    }
    for p in ::/EFI/BOOT/BOOTX64.EFI ::/EFI/BOOT/grubx64.efi ::/EFI/BOOT/mmx64.efi \
             ::/EFI/ubuntu/grubx64.efi ::/boot/bzImage; do
        esp_exists "$p" || { echo "ERROR: $p missing from ESP"; exit 1; }
    done
    echo "  ESP secure-boot files present (shim + grub x2 + MokManager + signed kernel)"
    for p in ::/EFI/BOOT/BOOTX64.EFI ::/EFI/BOOT/grubx64.efi ::/EFI/ubuntu/grubx64.efi ::/boot/bzImage; do
        mcopy -o -i "$ESP_IMG" "$p" "$WORK/esp_pull.bin" >/dev/null 2>&1 \
            || { echo "ERROR: cannot read back $p"; exit 1; }
        sb_verify "$WORK/esp_pull.bin" "on-ESP $p" || exit 1
    done
    # shim and grub must be different files (i.e. shim really took the fallback slot)
    mcopy -o -i "$ESP_IMG" ::/EFI/BOOT/BOOTX64.EFI "$WORK/esp_shim.bin" >/dev/null 2>&1
    mcopy -o -i "$ESP_IMG" ::/EFI/BOOT/grubx64.efi "$WORK/esp_grub.bin" >/dev/null 2>&1
    cmp -s "$WORK/esp_shim.bin" "$WORK/esp_grub.bin" \
        && { echo "ERROR: ::/EFI/BOOT/BOOTX64.EFI is not shim"; exit 1; } || true
    # and the kernel on the ESP must carry a PE stub (sbsign output), not the raw kernel
    mcopy -o -i "$ESP_IMG" ::/boot/bzImage "$WORK/esp_kern.bin" >/dev/null 2>&1
    [ "$(head -c2 "$WORK/esp_kern.bin")" = "MZ" ] \
        || { echo "ERROR: ESP kernel is not a signed PE image"; exit 1; }
    echo "  on-ESP signature round-trip verified (sbverify x4, kernel has PE header)"
else
    echo "  SECURE_BOOT=0: unsigned single-loader ESP (legacy layout)"
fi
echo "build-id + grub esc + diag-entries + external-config checks OK"

DISK_SHA="$(sha256sum "$DISK" | cut -d' ' -f1)"
{
echo "BUILD_ID=$BUILD_ID"
echo "HARDWARE=$HARDWARE"
echo "DISK=$DISK"
echo "DISK_BYTES=$DISK_BYTES"
echo "DISK_SHA256=$DISK_SHA"
echo "RAMDISK=$RAMDISK"
echo "RAMDISK_SHA256=$(sha256sum "$RAMDISK" | cut -d' ' -f1)"
echo "PART_INIT=$OUTDIR/part_init"
echo "PART_INIT_SHA256=$(sha256sum "$OUTDIR/part_init" | cut -d' ' -f1)"
echo "P2_MIB=$P2_MIB P3_MIB=$P3_MIB P4_MIB=$P4_MIB P5_MIB=$P5_MIB P6_MIB=$P6_MIB"
echo "SECURE_BOOT=$SECURE_BOOT"
echo "GRUB_SOURCE=$GRUB_SOURCE"
if [ "$GRUB_SOURCE" = "ours" ] && [ -f "$GRUB_DIST/build_info.txt" ]; then
    grep -E '^(GRUB_VERSION|RAW_SHA256|SIGNED_SHA256|PATCHES)=' "$GRUB_DIST/build_info.txt" \
        | sed -e 's/^GRUB_VERSION=/GRUB_VERSION=/' \
              -e 's/^RAW_SHA256=/GRUB_RAW_SHA256=/' \
              -e 's/^SIGNED_SHA256=/GRUB_SIGNED_SHA256=/' \
              -e 's/^PATCHES=/GRUB_PATCHES=/'
fi
echo "ESP_LOADER=$BOOTLOADER_NAME"
if [ "$SECURE_BOOT" = "1" ]; then
    echo "SB_KEY=$SB_KEY"
    echo "SB_CERT=$SB_CRT"
    echo "SB_CERT_DER=$SB_KEYS_DIR/ohos-uefi.cer"
    echo "SB_CERT_SHA256=$(openssl x509 -in "$SB_CRT" -noout -fingerprint -sha256 | sed 's/.*= *//; s/://g' | tr 'A-Z' 'a-z')"
    echo "MOK_IMPORT_CMD=sudo mokutil --import $SB_KEYS_DIR/ohos-uefi.cer"
    echo "SHIM=$SHIM_SRC"
    echo "MOKMANAGER=$MOKMGR_SRC"
fi
} | tee "$OUTDIR/FINAL_SUMMARY.txt"
echo "== done =="
