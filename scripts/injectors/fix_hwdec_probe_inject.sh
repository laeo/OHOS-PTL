#!/bin/bash
# fix_hwdec_probe/inject.sh <disk-image>
#
# Injects the oneVPL hardware video decode stack into the pc_ptl disk image:
#
#   p2 (system) : /system/bin/hwdec_probe, /system/bin/hwdec_probe.sh,
#                  /system/etc/hwdec/sample.h264 (+ sample_min.h264)
#   p3 (vendor) : /vendor/lib64/{libvpl,libmfx-gen,libva,libva-drm,libdrm,igdgmm},
#                  /vendor/lib64/dri/iHD_drv_video.so,
#                  /vendor/etc/init.hwdec_probe.cfg and a patched
#                  /vendor/etc/init.pc_ptl.cfg (imports the new cfg and starts
#                  the probe in the "boot" job, i.e. after /dev/dri is chmod'ed).
#
# Properties
#   * idempotent: re-running produces the same image content (rm+write, sha256 verified)
#   * does not touch the GPT, does not resize any partition
#   * does NOT modify the delivered image unless you pass it explicitly
#
# Usage:  inject.sh <image>            # e.g. partdisk/media/ohos_part_pc_ptl.img
set -eu

BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
TASK=$BASE/fix_hwdec_probe
W=$TASK/work

IMG=${1:-}
[ -n "$IMG" ] || { echo "usage: inject.sh <disk-image>"; exit 1; }
[ -f "$IMG" ] || { echo "ERROR: image not found: $IMG"; exit 1; }

MAN="$TASK/manifest.txt"
[ -f "$MAN" ] || { echo "ERROR: manifest missing ($MAN) - run package.sh first"; exit 1; }

mkdir -p "$W"
P2_OFF_MB=513      # p2 (system)  = sector 1050624 * 512 = 513 MiB
P2_LEN_MB=2048
P3_OFF_MB=2561     # p3 (vendor)  = sector 5244928 * 512 = 2561 MiB
P3_LEN_MB=512

echo "=== image : $IMG"
echo "=== extracting p2/p3 ..."
dd if="$IMG" of="$W/inject_p2.img" bs=1M skip=$P2_OFF_MB count=$P2_LEN_MB status=none
dd if="$IMG" of="$W/inject_p3.img" bs=1M skip=$P3_OFF_MB count=$P3_LEN_MB status=none

# ---------------------------------------------------------------- p2 (system)
{
    grep '^FILE|p2|' "$MAN" | while IFS='|' read -r _ _ SRC DST MODE; do
        d=$(dirname "$DST")
        [ "$d" = "/" ] || echo "mkdir $d"
    done | sort -u
    grep '^FILE|p2|' "$MAN" | while IFS='|' read -r _ _ SRC DST MODE; do
        echo "rm $DST"
        echo "write $SRC $DST"
    done
} > "$W/p2_cmds.txt"
{
    grep '^FILE|p2|' "$MAN" | while IFS='|' read -r _ _ SRC DST MODE; do
        if [ "$MODE" = "0755" ]; then echo "set_inode_field $DST mode 0100755"; fi
    done
} >> "$W/p2_cmds.txt"

echo "--- injecting into p2 (system) ---"
debugfs -w -f "$W/p2_cmds.txt" "$W/inject_p2.img" 2>&1 | grep -viE "^debugfs|^\s*$" | sed 's/^/    /' || true

# ---------------------------------------------------------------- p3 (vendor)
{
    grep '^FILE|p3|' "$MAN" | while IFS='|' read -r _ _ SRC DST MODE; do
        d=$(dirname "$DST")
        [ "$d" = "/" ] || echo "mkdir $d"
    done | sort -u
    grep '^FILE|p3|' "$MAN" | while IFS='|' read -r _ _ SRC DST MODE; do
        echo "rm $DST"
        echo "write $SRC $DST"
    done
    grep '^LINK|p3|' "$MAN" | while IFS='|' read -r _ _ REAL LINK TARGET; do
        echo "rm $LINK"
        echo "symlink $LINK $TARGET"
    done
} > "$W/p3_cmds.txt"

# patch the device init cfg: import our cfg + start the probe in the boot job
echo "--- patching /etc/init.pc_ptl.cfg (vendor fs) ---"
CFG="$W/init.pc_ptl.cfg"
rm -f "$CFG"
debugfs -R "dump /etc/init.pc_ptl.cfg $CFG" "$W/inject_p3.img" >/dev/null 2>&1 || true
if [ -s "$CFG" ]; then
    python3 - "$CFG" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
imp = d.get("import", [])
if "/vendor/etc/init.hwdec_probe.cfg" not in imp:
    imp.append("/vendor/etc/init.hwdec_probe.cfg")
    d["import"] = imp
    print("    added import init.hwdec_probe.cfg")
for job in d.get("jobs", []):
    if job.get("name") == "boot":
        cmds = job.setdefault("cmds", [])
        if "start hwdec_probe" not in cmds:
            cmds.append("start hwdec_probe")
            print("    added 'start hwdec_probe' to the boot job")
json.dump(d, open(p, "w"), indent=4)
PY
    {
        echo "rm /etc/init.pc_ptl.cfg"
        echo "write $CFG /etc/init.pc_ptl.cfg"
    } >> "$W/p3_cmds.txt"
else
    echo "    WARNING: could not read /etc/init.pc_ptl.cfg - probe service will not start"
fi

echo "--- injecting into p3 (vendor) ---"
debugfs -w -f "$W/p3_cmds.txt" "$W/inject_p3.img" 2>&1 | grep -viE "^debugfs|^\s*$" | sed 's/^/    /' || true

# ---------------------------------------------------------------- fsck
echo "--- e2fsck p2 ---"
e2fsck -f -y "$W/inject_p2.img" > "$W/e2fsck_p2.log" 2>&1 || true
tail -2 "$W/e2fsck_p2.log" | sed 's/^/    /'
echo "--- e2fsck p3 ---"
e2fsck -f -y "$W/inject_p3.img" > "$W/e2fsck_p3.log" 2>&1 || true
tail -2 "$W/e2fsck_p3.log" | sed 's/^/    /'

# ---------------------------------------------------------------- verify
echo "--- verifying files inside the image ---"
RC=0
while IFS='|' read -r kind part src dst mode; do
    case "$kind" in
        FILE)
            case "$part" in
                p2) IMGFS="$W/inject_p2.img" ;;
                p3) IMGFS="$W/inject_p3.img" ;;
                *) continue ;;
            esac
            TMP="$W/_check.bin"; rm -f "$TMP"
            debugfs -R "dump $dst $TMP" "$IMGFS" >/dev/null 2>&1 || true
            if [ ! -f "$TMP" ]; then
                echo "    MISSING in image: $dst"; RC=1; continue
            fi
            A=$(sha256sum "$src" | cut -d' ' -f1)
            B=$(sha256sum "$TMP" | cut -d' ' -f1)
            if [ "$A" != "$B" ]; then
                echo "    MISMATCH: $dst  ($A != $B)"; RC=1
            else
                echo "    OK: $dst  sha256=$A  size=$(stat -c%s "$TMP")"
            fi
            rm -f "$TMP"
            ;;
        LINK)
            case "$part" in
                p2) IMGFS="$W/inject_p2.img" ;;
                p3) IMGFS="$W/inject_p3.img" ;;
                *) continue ;;
            esac
            if debugfs -R "stat $dst" "$IMGFS" 2>/dev/null | grep -q "Fast link dest"; then
                echo "    OK: symlink $dst -> $(debugfs -R "stat $dst" "$IMGFS" 2>/dev/null | sed -n 's/.*Fast link dest: "\(.*\)"/\1/p')"
            else
                echo "    MISSING symlink: $dst"; RC=1
            fi
            ;;
    esac
done < "$MAN"
[ "$RC" = "0" ] || { echo "ERROR: verification failed"; exit 1; }

# ---------------------------------------------------------------- write back
echo "--- writing partitions back ---"
dd if="$W/inject_p2.img" of="$IMG" bs=1M seek=$P2_OFF_MB count=$P2_LEN_MB conv=notrunc,fsync status=none
dd if="$W/inject_p3.img" of="$IMG" bs=1M seek=$P3_OFF_MB count=$P3_LEN_MB conv=notrunc,fsync status=none

echo "=== OK: oneVPL hw decode stack injected into $IMG"
echo "    (sha256 of image: $(sha256sum "$IMG" | cut -d' ' -f1))"
