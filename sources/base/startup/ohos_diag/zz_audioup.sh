#!/bin/sh
# zz_audioup - playback-path sanity pass, started from init after boot by
# /system/etc/init/zz_audio.cfg.
#
# Why this exists (pc_ptl / Intel PTL / SOF HDA + Realtek ALC256):
#
#   1) The HDA codec comes up with the DAC muted / at zero gain
#      ([Master Playback Volume] : values=0,0).  The audio HDI only touches the
#      codec volume once something plays or the user moves the volume slider,
#      so the very first playback attempt is silent even though the whole
#      ALSA/SOF path is fine.
#
#   2) The *SOF DAI* mixers of the "HDA Analog" path ("Pre/Post Mixer Analog
#      Playback Volume", ALSA numid 31/32 on this card) are a second,
#      independent digital gain stage inside the DSP topology.  On a working
#      system (verified on the same machine running Ubuntu) they sit at their
#      maximum (45/45).  If they are 0 the stream is digitally silent even
#      though the codec mixer is unmuted and the PCM is running - which is
#      exactly the "no sound at all" symptom.
#
#   3) The ALC256 "Auto-Mute Mode" switch mutes the speaker when no headset
#      is plugged in when it is left in the "Enabled" state.
#
# Policy:
#   * the *user facing* codec volumes are only raised when they are exactly 0
#     (we never override a volume the user has chosen),
#   * the DSP-internal DAI mixers are forced to their maximum, because they
#     are not user facing and 0 means "digital silence",
#   * every step is best effort: a failure is logged and ignored, the script
#     must never be fatal.
#
# The "keep it that way" part lives in zz_audioguard.sh (same init job):
# SOF re-initialises the DAI-link widgets when a stream is instantiated, so
# a one-shot pass at boot can be undone by the first playback.
PATH=/system/bin:/vendor/bin:/bin:/usr/bin:/sbin:/usr/sbin
export PATH
LC_ALL=C
export LC_ALL

LOG=/data/local/tmp/zz_audioup.txt
kmsg() {
    printf '%s\n' "ZZAUD: $1" > /dev/kmsg 2>/dev/null
    printf '%s\n' "$1" >> "$LOG" 2>/dev/null
}

# cget_value <control name> -> the first "values=N" of that control
cget_value() {
    amixer -c 0 cget name="$1" 2>/dev/null |
        sed -n 's/.*: values=\([0-9][0-9]*\).*/\1/p' | head -1
}

# cget_max <control name> -> the "max=N" of that control ("" if unknown)
cget_max() {
    amixer -c 0 cget name="$1" 2>/dev/null |
        sed -n 's/.*max=\([0-9][0-9]*\).*/\1/p' | head -1
}

# cget_mute <control name> -> "0" (not muted) / "1" (muted) / "" (unknown)
cget_mute() {
    amixer -c 0 cget name="$1" 2>/dev/null |
        sed -n 's/.*mute=\([0-9]\).*/\1/p' | head -1
}

i=0
while [ "$i" -lt 60 ]; do
    [ -c /dev/snd/controlC0 ] && break
    sleep 1
    i=$((i + 1))
done
if [ ! -c /dev/snd/controlC0 ]; then
    kmsg "no /dev/snd/controlC0 - no ALSA card, give up"
    exit 0
fi
kmsg "playback pass on card 0 (controls are probed by name)"

# ---- 0. record the whole mixer map (this is what we report back) ---------
# NOTE: the device has no 'tr' (toybox + mksh only) -> join with sed.
kmsg "mixer map: $(amixer -c 0 controls 2>/dev/null | sed ':a;N;$!ba;s/\n/ /g' | cut -c1-900)"

# ---- 1. user facing codec volumes: raise only when they are exactly 0 -----
for c in 'Master Playback Volume' 'PCM Playback Volume' \
         'Headphone Playback Volume' 'Speaker Playback Volume'; do
    val=$(cget_value "$c")
    [ -n "$val" ] || continue
    if [ "$val" -eq 0 ]; then
        if amixer -c 0 cset name="$c" 64% >/dev/null 2>&1; then
            kmsg "raised '$c' from 0 to 64%"
        else
            kmsg "cannot raise '$c'"
        fi
    else
        kmsg "'$c' = $val (left alone)"
    fi
done

# ---- 2. codec playback switches: make sure nothing is switched off ---------
for s in 'Master Playback Switch' 'PCM Playback Switch' \
         'Headphone Playback Switch' 'Speaker Playback Switch'; do
    if amixer -c 0 cset name="$s" 1 >/dev/null 2>&1; then
        kmsg "switch on '$s'"
    fi
done

# ---- 3. SOF DAI mixers: force the maximum (0 == digital silence) -----------
# These are the DSP-side gain stages of the "HDA Analog" path
# (numid 31/32 on the SOF card).  They are *not* user facing.
for m in 'Pre Mixer Analog Playback Volume' 'Post Mixer Analog Playback Volume' \
         'Pre Mixer Deepbuffer HDA Analog Volume'; do
    val=$(cget_value "$m")
    [ -n "$val" ] || continue
    max=$(cget_max "$m")
    [ -n "$max" ] || max=45
    if [ "$val" -ge "$max" ]; then
        kmsg "DSP mixer '$m' = $val (ok, max=$max)"
    elif amixer -c 0 cset name="$m" "$max" >/dev/null 2>&1; then
        kmsg "raised DSP mixer '$m' from $val to $max (was attenuating/digitally silent)"
    else
        kmsg "cannot raise DSP mixer '$m' (=$val, max=$max)"
    fi
done

# ---- 4. ALC256 auto-mute: the speaker must not be muted by the codec -------
if amixer -c 0 cset name='Auto-Mute Mode' Disabled >/dev/null 2>&1; then
    kmsg "Auto-Mute Mode -> Disabled (speaker stays audible without a headset)"
fi

# ---- 5. report the final state -------------------------------------------
for c in 'Master Playback Volume' 'Speaker Playback Volume' \
         'Headphone Playback Volume' 'Pre Mixer Analog Playback Volume' \
         'Post Mixer Analog Playback Volume' 'Pre Mixer Deepbuffer HDA Analog Volume'; do
    kmsg "final '$c' = $(cget_value "$c") mute=$(cget_mute "$c")"
done
kmsg "playback pass done"
exit 0
