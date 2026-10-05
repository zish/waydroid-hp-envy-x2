#!/bin/sh
# audio-tone.sh -- make Android play a known signal, headless. Goal 5, docs/44.
#
#     ssh 10.42.0.137 'sudo sh -s' -- gen           < bin/audio-tone.sh
#     ssh 10.42.0.137 'sudo sh -s' -- play          < bin/audio-tone.sh
#     ssh 10.42.0.137 'sudo sh -s' -- stop          < bin/audio-tone.sh
#
# VOL=n sets the media-stream index both arms are pinned to (default 4 of 15).
#
# WHY THIS EXISTS AT ALL
#
# This image has no headless way to make a sound. There is no tinyplay, no
# tinymix and no stagefright in /system/bin -- checked, all five candidates
# absent -- so nothing can be driven straight at AudioFlinger from a shell, and
# nothing at all can be driven at the HAL without going through an app. What it
# does have is VLC (org.videolan.vlc), whose .StartActivity answers a plain
# VIEW intent with a file:// URI. That is the whole trick, and it is worth a
# script because every audio measurement needs it and it is not guessable.
#
# A bare VIEW intent is NOT enough: `cmd package resolve-activity` on the URI
# resolves to com.android.internal.app.ResolverActivity -- the chooser -- so an
# unqualified `am start` puts a dialog on screen and plays nothing. The -n is
# what makes it headless.
#
# `play` pins the media stream to a KNOWN, MODERATE index (VOL, default 4 of
# 15). Known matters: the first measured run came in at -37.5 dBFS of signal
# power for a -6 dBFS file because the stream happened to sit at 4, and an A/B
# whose arms differ by volume rather than by backend measures nothing. Loud does
# not matter, and an earlier version of this script pinning the maximum was
# simply wrong to: AudioFlinger applies stream gain in its own mixer BEFORE the
# HAL write, so write count, write jitter, xruns and CPU -- every number the A/B
# turns on -- are identical at index 4 and index 15. The only metric volume
# touches is signal power, which merely has to be audibly non-silent. A 1 kHz
# sine at full scale through a laptop speaker is unpleasant for whoever is at
# the machine, and buys the measurement nothing.
#
# THE SIGNAL. 1 kHz sine, -6 dBFS, 48 kHz / 16-bit / stereo, DUR s (1200).
# 48 kHz 16-bit stereo is deliberate: it is exactly what the HAL asks the PCM
# for and exactly what audio_policy_configuration.xml lets an app have, so the
# file is carried to the card with no resample and no format conversion in the
# guest, and anything that happens to it happened on the host side.
#
# The length is 20 minutes rather than the 5 it started as, because a listening
# test is not a measurement run. An A/B with a human in it costs one question
# round-trip per arm on top of the ~60 s instrument, and a 300 s file ran out
# mid-test: the card read `closed`, the reported symptom was "nothing at all",
# and the arm under test was not actually playing. Length is cheap -- 20 minutes
# is 230 MB against 178 GB free -- and relaunching on a timer is not, because
# each relaunch puts an audible gap in the tone that a listener would
# reasonably report as a dropout.
#
# WHY THE DURATION IS IN THE FILENAME: ANDROID'S STALE STAT
#
# The first attempt at lengthening the tone deleted abtone.wav on the host and
# wrote a 1200 s file to the same path. The host then saw 230400044 bytes; the
# container went on reporting the OLD 57600044 bytes and the OLD mtime, while
# `od` through the same path returned the NEW header. So Android's attribute
# cache for that path was stale even though its reads were not, VLC bounded the
# stream by the cached st_size, and playback stopped at exactly 300.0 s --
# 14400000 frames -- with a clean end-of-stream on a file that was four times
# longer. It looked exactly like load killing playback during an A/B, and it was
# not; it cost a round of investigation to tell apart.
#
# Removing and recreating a path under a live container mount is the same class
# of mistake as editing an overlayfs lowerdir while it is mounted. The fix is to
# never reuse a path: a filename the container has never stat'd cannot have a
# stale entry for it. Hence abtone-<DUR>s.wav, and hence `play` asserting the
# size it expects rather than trusting that the file on disk is the file Android
# will read.

set -u

VOL=${VOL:-4}
DUR=${DUR:-1200}
TONE_DIR=/Music
# The duration is IN THE FILENAME, and that is load-bearing -- see the note on
# Android's stale attribute cache below. Never reuse a path for new content.
TONE=abtone-${DUR}s.wav
VLC=org.videolan.vlc/.StartActivity

MEDIA=$(ls -d /home/*/.local/share/waydroid/data/media/0 2>/dev/null | head -1)
[ -n "$MEDIA" ] || { echo "no waydroid media dir -- has the container ever run?" >&2; exit 1; }
HOSTPATH=$MEDIA$TONE_DIR/$TONE

ash() { waydroid shell -- sh -c "$1" 2>&1 | grep -v 'Permission denied: 1'; }

gen() {
    mkdir -p "$MEDIA$TONE_DIR"
    python3 - "$HOSTPATH" "$DUR" <<'PY'
import math, os, struct, sys, wave
fn, dur = sys.argv[1], int(sys.argv[2])
sr, amp = 48000, int(32767 * 0.5)                     # 0.5 => -6 dBFS peak
one = b"".join(struct.pack("<hh", v, v) for v in
               (int(amp * math.sin(2 * math.pi * 1000 * n / sr)) for n in range(sr)))
w = wave.open(fn, "wb")
w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr)
for _ in range(dur):                                  # one second at a time
    w.writeframes(one)
w.close()
print("%s  %d bytes  %d s" % (fn, os.path.getsize(fn), dur))
PY
    # media_rw:media_rw 0770 is what everything else under media/0 is; see docs/46.
    chown 1023:1023 "$HOSTPATH"
    chmod 0770 "$HOSTPATH"
}

case "${1:-play}" in
  gen)  gen ;;
  play)
    [ -f "$HOSTPATH" ] || gen
    # Assert Android's view, not the host's. These can disagree (see above), and
    # when they do it is the container's number that decides where playback ends.
    WANT_BYTES=$(( 48000 * DUR * 4 + 44 ))
    SEEN=$(waydroid shell -- stat -c %s "/storage/emulated/0${TONE_DIR}/${TONE}" 2>/dev/null |
           tr -cd '0-9')
    if [ -n "${SEEN:-}" ] && [ "$SEEN" != "$WANT_BYTES" ]; then
        echo "WARNING: Android sees ${SEEN} bytes, expected ${WANT_BYTES}." >&2
        echo "         Playback will stop early. Use a fresh DUR (new filename)" >&2
        echo "         rather than rewriting this path -- see the header." >&2
    fi
    # Stream 3 is STREAM_MUSIC. There is no `media` binary in this image -- the
    # usual `media volume` wrapper is absent from /system/bin -- so this goes
    # through `cmd media_session`, which is what that wrapper would have called.
    # Clamp to the ladder's top, read from "volume is X in range [0..Y]" rather
    # than assumed: asking for one past the top is an error, not a clamp, and it
    # leaves the volume where it was while looking like it worked.
    TOP=$(ash 'cmd media_session volume --stream 3 --get' |
          sed -n 's/.*range \[[0-9]*\.\.\([0-9]*\)\].*/\1/p' | head -1)
    [ -n "${TOP:-}" ] || TOP=15
    WANT=$VOL
    [ "$WANT" -gt "$TOP" ] && WANT=$TOP
    ash "cmd media_session volume --stream 3 --set $WANT" >/dev/null
    ash "am start -n $VLC -a android.intent.action.VIEW -t audio/x-wav \
         -d file:///storage/emulated/0${TONE_DIR}/${TONE}" | sed -n '1,3p'
    sleep 6
    ash 'cmd media_session volume --stream 3 --get' | sed -n '/volume is/p'
    ;;
  stop)
    ash 'am force-stop org.videolan.vlc'
    echo "stopped org.videolan.vlc"
    ;;
  *) echo "usage: $0 {gen|play|stop}" >&2; exit 2 ;;
esac
