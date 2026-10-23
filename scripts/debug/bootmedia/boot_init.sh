#!/bin/sh
# boot_init.sh - OpenHarmony boot-media init (runs as PID 1 before stock init).
#
# Purpose
# -------
# Boot OpenHarmony from a *single* read-only medium (ISO / Ventoy ISO) that only
# contains the per-partition raw images (system.img, vendor.img, ...).  The stock
# OHOS first-stage init expects real block devices at /dev/block/by-name/<name>;
# this script provides them by loop-mounting the .img files, then hands off to
# the stock init via /init.
#
# It is installed into the initramfs and selected with the kernel parameter:
#     rdinit=/boot_init.sh
#
# Read-only vs read-write
# -----------------------
# system / vendor are mounted read-only by OHOS  -> loop them directly (losetup -r)
# sys_prod / chip_prod / userdata are mounted rw  -> if the medium is writable
#     (partition USB, or a writable Ventoy data partition holding the images)
#     loop them in place; otherwise copy them to a tmpfs first so they can be
#     mounted read-write.  Data in the tmpfs copy is NOT persistent.
#
# Media discovery
# ---------------
# Scans removable/optical devices (and Ventoy's /dev/mapper/ventoy) for a
# filesystem that contains system.img.  Only ever mounts read-only here.

PATH=/bin
export PATH

log() {
    echo "boot_init: $*" >/dev/kmsg 2>/dev/null
    echo "boot_init: $*"
}

mount -t proc     proc     /proc 2>/dev/null
mount -t sysfs    sysfs    /sys  2>/dev/null
mount -t devtmpfs devtmpfs /dev  2>/dev/null
[ -e /dev/null ] || mknod /dev/null c 1 3
mkdir -p /dev/block/by-name /mnt/media /run

MEDIA=""
MEDIAFS=""

try_mount() {
    d="$1"; fs="$2"
    mount -t "$fs" -o ro "$d" /mnt/media 2>/dev/null || return 1
    if [ -f /mnt/media/system.img ]; then
        MEDIA="$d"; MEDIAFS="$fs"
        return 0
    fi
    umount /mnt/media 2>/dev/null
    return 1
}

find_media() {
    # /dev/sr*  : El Torito CD (plain UEFI boot of the ISO)
    # /dev/mapper/ventoy : Ventoy's device-mapper view of the ISO
    # /dev/sd*  : USB sticks / partition USB / Ventoy data partition
    # /dev/vd*  : virtio disks (QEMU)
    for d in /dev/sr0 /dev/sr1 /dev/mapper/ventoy \
             /dev/vd* /dev/sd*; do
        [ -b "$d" ] || continue
        for fs in iso9660 ext4 vfat exfat; do
            try_mount "$d" "$fs" && return 0
        done
    done
    return 1
}

log "searching for OHOS boot medium ..."
i=0
while [ $i -lt 30 ]; do
    find_media && break
    i=$((i + 1))
    sleep 1
done
if [ -z "$MEDIA" ]; then
    log "FATAL: no filesystem containing system.img found after ${i}s; dropping to shell"
    log "devices:"; ls -l /dev/sr* /dev/sd* /dev/vd* /dev/mapper 2>/dev/null
    log "filesystems:"; cat /proc/filesystems
    exec /bin/sh
fi
log "media=$MEDIA fs=$MEDIAFS"

WRITABLE=0
if touch /mnt/media/.ohos_rw_test 2>/dev/null; then
    rm -f /mnt/media/.ohos_rw_test
    WRITABLE=1
fi
log "medium writable=$WRITABLE"

mknod /dev/loop-control c 10 237 2>/dev/null
RWSTAGE=/run/rw
mkdir -p "$RWSTAGE"

attach() {
    # $1 = image file, $2 = 1 read-write / 0 read-only ; prints loop device
    f="$1"; rw="$2"
    dev="$(losetup -f 2>/dev/null)"
    [ -n "$dev" ] || return 1
    if [ "$rw" = 1 ]; then
        losetup "$dev" "$f" 2>/dev/null || return 1
    else
        losetup -r "$dev" "$f" 2>/dev/null || return 1
    fi
    printf '%s' "$dev"
}

link_part() {
    # $1 = partition name, $2 = image file, $3 = 1 if rw required
    name="$1"; img="$2"; needrw="$3"
    if [ ! -f "$img" ]; then
        log "WARN: $img not found, skip $name"
        return 1
    fi
    if [ "$needrw" = 1 ] && [ "$WRITABLE" != 1 ]; then
        cp "$img" "$RWSTAGE/$name.img" 2>/dev/null || { log "WARN: copy $img failed"; return 1; }
        img="$RWSTAGE/$name.img"
    fi
    dev="$(attach "$img" "$needrw")" || { log "WARN: losetup $img failed"; return 1; }
    ln -sf "$dev" "/dev/block/by-name/$name"
    log "$name -> $dev ($img)"
}

# system / vendor: mounted read-only by OHOS
link_part system    /mnt/media/system.img    0
link_part vendor    /mnt/media/vendor.img    0
# sys_prod / chip_prod / userdata: mounted read-write by OHOS
link_part sys_prod  /mnt/media/sys_prod.img  1
link_part chip_prod /mnt/media/chip_prod.img 1
link_part userdata  /mnt/media/userdata.img  1

log "handing off to /init"
exec /init
