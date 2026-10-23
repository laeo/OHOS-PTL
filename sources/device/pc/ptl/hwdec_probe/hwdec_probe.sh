#!/bin/sh
# hwdec_probe.sh - launcher for the Intel hardware video decode probe.
#
# Runs once at boot (init service "hwdec_probe") and produces:
#   * hilog lines with the "HWDEC:" prefix (via OH_LOG_Print in the probe)
#   * a persistent log file (default /sys_prod/hwdec_probe.log)
#
# /sys_prod is mounted read-only by the fstab, so we try to remount it rw.
# If that is not possible the probe falls back to /data/local/tmp/hwdec_probe.log.
#
# The VA stack needs to find the Intel media driver.  The libva in the image is
# built with -Ddriverdir=/vendor/lib64/dri (the compile time default), the
# environment variables below are the belt-and-braces fallback for an image
# that still carries a libva with the build-host DRI path baked in.

STREAM=/system/etc/hwdec/sample.h264
LOG=/sys_prod/hwdec_probe.log
MAX_FRAMES=120
CODEC=avc
MODE=auto

# --- driver search paths (only if not already set) ---
[ -n "$LIBVA_DRIVERS_PATH" ] || {
    if [ -d /vendor/lib64/dri ]; then
        LIBVA_DRIVERS_PATH=/vendor/lib64/dri:/system/lib64/dri
        export LIBVA_DRIVERS_PATH
    fi
}
[ -n "$LIBVA_DRIVER_NAME" ] || {
    if [ -f /vendor/lib64/dri/iHD_drv_video.so ]; then
        LIBVA_DRIVER_NAME=iHD
        export LIBVA_DRIVER_NAME
    fi
}
[ -n "$ONEVPL_SEARCH_PATH" ] || {
    ONEVPL_SEARCH_PATH=/system/lib64:/vendor/lib64
    export ONEVPL_SEARCH_PATH
}
[ -n "$ONEVPL_PRIORITY_PATH" ] || {
    ONEVPL_PRIORITY_PATH=/vendor/lib64:/system/lib64
    export ONEVPL_PRIORITY_PATH
}
MFX_VPL_LOG_LEVEL=1
export MFX_VPL_LOG_LEVEL

mount -o remount,rw /sys_prod 2>/dev/null

/system/bin/hwdec_probe "$STREAM" "$LOG" "$MAX_FRAMES" "$CODEC" "$MODE"
rc=$?

# keep a copy on the writable data partition (always available for `hdc file recv`)
if [ -f "$LOG" ]; then
    cp -f "$LOG" /data/local/tmp/hwdec_probe.log 2>/dev/null
fi

exit $rc
