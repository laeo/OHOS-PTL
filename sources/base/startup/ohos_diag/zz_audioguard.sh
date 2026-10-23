#!/bin/sh
# zz_audioguard - keeps the SOF playback path open.
#
# Started from init (same job as zz_audioup.sh, /system/etc/init/zz_audio.cfg).
#
# Why a daemon and not only the one-shot pass:
#   The "Pre/Post Mixer Analog Playback Volume" widgets are *DAI link* gain
#   stages inside the SOF topology.  SOF (re)initialises them from the
#   topology whenever the DAI link is instantiated, i.e. when the first
#   stream is opened.  A value that was written once at boot is therefore
#   not guaranteed to survive the first playback - and a value of 0 there is
#   a digital mute that is indistinguishable from "the speaker is broken".
#
#   The same applies to the ALC256 "Auto-Mute Mode" (it re-mutes the speaker
#   when no headset is plugged).
#
# The loop therefore re-asserts the values, but only when they are not
# already correct, so there is no log spam and no needless DSP writes.
PATH=/system/bin:/vendor/bin:/bin:/usr/bin:/sbin:/usr/sbin
export PATH
LC_ALL=C
export LC_ALL

LOG=/data/local/tmp/zz_audioguard.txt
kmsg() {
    printf '%s\n' "ZZAUDIOG: $1" > /dev/kmsg 2>/dev/null
    printf '%s\n' "$1" >> "$LOG" 2>/dev/null
}

cget_value() {
    amixer -c 0 cget name="$1" 2>/dev/null |
        sed -n 's/.*: values=\([0-9][0-9]*\).*/\1/p' | head -1
}

cget_max() {
    amixer -c 0 cget name="$1" 2>/dev/null |
        sed -n 's/.*max=\([0-9][0-9]*\).*/\1/p' | head -1
}

MIXERS='Pre Mixer Analog Playback Volume
Post Mixer Analog Playback Volume
Pre Mixer Deepbuffer HDA Analog Volume'

# wait for the card
i=0
while [ "$i" -lt 120 ]; do
    [ -c /dev/snd/controlC0 ] && break
    sleep 1
    i=$((i + 1))
done
[ -c /dev/snd/controlC0 ] || { kmsg "no /dev/snd/controlC0 - give up"; exit 0; }

kmsg "guard started (re-asserts the SOF DAI mixers + Auto-Mute every 2 s)"

while true; do
    printf '%s\n' "$MIXERS" | while read -r m; do
        [ -n "$m" ] || continue
        val=$(cget_value "$m")
        [ -n "$val" ] || continue
        max=$(cget_max "$m")
        [ -n "$max" ] || max=45
        if [ "$val" -lt "$max" ]; then
            if amixer -c 0 cset name="$m" "$max" >/dev/null 2>&1; then
                kmsg "re-raised '$m' $val -> $max"
            fi
        fi
    done
    # the codec's auto-mute: keep the speaker alive when no headset is in
    _am=$(cget_value 'Auto-Mute Mode')
    if [ -n "$_am" ] && [ "$_am" -ne 0 ] 2>/dev/null; then
        if amixer -c 0 cset name='Auto-Mute Mode' Disabled >/dev/null 2>&1; then
            kmsg "Auto-Mute Mode $_am -> Disabled"
        fi
    fi
    sleep 2
done
