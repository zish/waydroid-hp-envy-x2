#!/bin/sh
# audio-fastpath.sh -- give Waydroid's audio HAL a FastMixer, by making it
# report one card period instead of the whole card buffer. Goal 5,
# docs/44-audio-alsa-backend.md.
#
#     ssh 10.42.0.137 'sudo sh -s' -- status             < bin/audio-fastpath.sh
#     ssh 10.42.0.137 'sudo sh -s' -- on                 < bin/audio-fastpath.sh
#     ssh 10.42.0.137 'sudo sh -s' -- on --frames 512     < bin/audio-fastpath.sh
#     ssh 10.42.0.137 'sudo sh -s' -- verify             < bin/audio-fastpath.sh
#     ssh 10.42.0.137 'sudo sh -s' -- off                < bin/audio-fastpath.sh
#
# Sibling of bin/alsa-arm.sh, which switches the HAL onto a real card. This one
# assumes that arm is already on and changes how deep the buffer is. Like
# alsa-arm.sh, NEITHER `on` NOR `off` RESTARTS ANYTHING -- the overlay is read
# by mount_rootfs() at SESSION start, so both verbs end by telling you to log
# out and back in. `systemctl restart waydroid-container` is not the lever and
# strands the kiosk at the SDDM greeter; see bin/alsa-arm.sh for the measurement.
#
# WHY THIS IS THE LEVER, AND WHY THE POLICY FLAG ALONE IS NOT
#
# MEASURED 2026-10-05, `dumpsys media.audio_flinger`:
#
#     HAL frame count:    1024
#     Normal frame count: 1024
#     No FastMixer
#
# AudioFlinger decides whether a MixerThread gets a FastMixer at all in
# PlaybackThread/MixerThread setup, from the HAL's own buffer size:
#
#     initFastMixer = (mFrameCount < mNormalFrameCount)        # FastMixer_Static
#
# and mNormalFrameCount is mFrameCount scaled up only far enough to reach
# kMinNormalSinkBufferSizeMs (20 ms, = 960 frames at 48 kHz):
#
#     multiplier = 960 / mFrameCount ; if (multiplier <= 1.0) multiplier = 1.0
#     mNormalFrameCount = multiplier * mFrameCount
#
# With mFrameCount == 1024 the multiplier is 960/1024 = 0.9375, clamped to 1.0,
# so mNormalFrameCount == 1024 == mFrameCount and initFastMixer is FALSE. That
# arithmetic reproduces the two observed numbers exactly, which is the evidence
# that this is the live mechanism and not a guess.
#
# So there is NO FastMixer thread for a fast track to live on, and
# AUDIO_OUTPUT_FLAG_FAST in the policy XML would be denied no matter what --
# AudioFlinger logs exactly that, with hasFastMixer=0. The policy flag is
# necessary (without it the policy strips FAST before AudioFlinger ever sees
# the request) but it is NOT sufficient, and the HAL buffer is the gate.
#
# WHAT `on` CHANGES
#
# 1. /vendor/lib/hw/audio.primary.waydroid.so -- the 32-bit build, which is the
#    one actually loaded (/vendor/bin/hw/android.hardware.audio.service is i686;
#    confirmed from its /proc/<pid>/maps). The HAL's get_buffer_size() is a
#    standalone function, installed at audio_stream vtable slot 0x8, that
#    switches on get_format() through a 6-entry jump table and multiplies by
#    popcnt(get_channels()):
#
#        PCM_16_BIT        0x800 bytes/channel  x 2ch = 4096 B = 1024 frames
#        PCM_8_BIT         0x400
#        PCM_32_BIT/8_24/FLOAT  0x1000
#        PCM_24_BIT_PACKED 0xc00
#
#    i.e. 1024 frames hardcoded for every format. There is no property and no
#    config file -- the only property this HAL reads at all is
#    waydroid.pulse_runtime_path. So the constant is patched: the single
#    instruction `mov $0x800,%esi` becomes `mov $0x200,%esi`, making
#    get_buffer_size() report 256 frames.
#
#    The ALSA buffer is NOT touched. The same arithmetic appears a second time,
#    inlined where snd_pcm_hw_params_set_buffer_size() is called, and that copy
#    keeps its own constants -- so the card stays at a 1024-frame buffer of 4 x
#    256-frame periods, exactly as measured, and the HAL simply writes one
#    period per call instead of the whole buffer. Three periods of slack remain.
#
#    get_buffer_size() is shared by the input and output streams (one function,
#    both vtables), so capture's reported buffer shrinks too. Capture has never
#    been exercised in this project, so there is no behaviour here to regress,
#    but it is a real side effect and not a no-op.
#
# 1b. The SAME file's out_get_latency(), which is three instructions:
#
#        mov  $0x3e8000,%eax        ; 4096000 = 4096 frames x 1000
#        xor  %edx,%edx
#        divl 0xac(%ecx)            ; / sample rate (the field get_sample_rate returns)
#
#     so it reports 4096000/48000 = 85 ms, flat. That is upstream's
#     PLAYBACK_PERIOD_SIZE 1024 x PERIOD_COUNT 4 = 4096 frames -- a buffer this
#     card does not have. The card runs 1024 frames (verified in
#     /proc/asound/card1/pcm0p/sub0/hw_params), and the measured `delay` sat at
#     896-1053 frames, so the truth is ~21 ms and the HAL overstates by 4x.
#
#     This matters more than a wrong number usually would. AudioFlinger adds the
#     MonoPipe's average fill to it (correctLatency_l, only when a FastMixer
#     exists), AudioTrack adds its own buffer, and the result is what
#     getLatency() hands an app -- measured at 127/229/287 ms across three
#     performance modes, i.e. a constant ~116 ms plus each arm's own buffer.
#     A DAW uses that figure to time-align what it records. The fast path gave
#     it a 10.67 ms buffer behind a 116 ms claim.
#
#     --latency-frames (default 1024, the card's real buffer) sets the dividend
#     to frames x 1000. The HAL still is not MEASURING anything -- it has no
#     snd_pcm_delay and cannot -- but a correct constant beats a 4x-wrong one.
#
# 2. /vendor/etc/audio_policy_configuration.xml -- AUDIO_OUTPUT_FLAG_FAST is
#    added to the EXISTING "primary output" mixPort rather than declared as a
#    new "fast output" mixPort. That is deliberate. A separate mixPort is what
#    real devices ship, but it makes AudioPolicyManager open a SECOND HAL output
#    stream, and this card cannot do that:
#
#        /proc/asound/card1/pcm0p/info:  subdevices_count: 1
#
#    A second snd_pcm_open("hw:1,0") would get -EBUSY. Combining both flags on
#    one mixPort keeps it to one stream -- the same thing the Android emulator's
#    goldfish policy does -- and AudioFlinger then attaches a fast track to the
#    primary MixerThread's FastMixer.
#
# NEITHER FILE IS CARRIED IN THIS REPO. Both are derived here from the host's
# own stock /etc/waydroid-extra/images/vendor.img, read with debugfs without
# mounting it, by a deterministic transform; and `on` refuses loudly if the
# input hash has moved -- it does not silently skip, which is the known flaw in
# waydroid-overlay-sync's existing `derive` rows. It must be the IMAGE and not
# /var/lib/waydroid/rootfs, because once the overlay is applied the rootfs path
# returns the patched file and `on` would be deriving from its own output.
#
# WHAT TO EXPECT, AND HOW IT CAN FAIL
#
# Predicted after a session restart, at --frames 256:
#
#     HAL frame count:    256
#     Normal frame count: 768          (floor(960/256) = 3, so 3 x 256)
#     a FastMixer section replacing "No FastMixer"
#
# Two ways it can legitimately come back negative, both of which this tells you:
#
#   - `No FastMixer` SURVIVES with the frame counts changed. Then this build has
#     kUseFastMixer == FastMixer_Never compiled in and no HAL change can help;
#     it needs a framework rebuild. Nothing in the binary distinguishes Never
#     from Static beforehand, so this verb is the test.
#   - a FastMixer appears but underruns. The FastMixer wants SCHED_FIFO, and in
#     this container the HAL's writer thread is SCHED_OTHER nice -19 while
#     `Max realtime priority` is 10 -- so requestPriority() may be refused and a
#     5.33 ms period then has no scheduling protection. `verify` prints the
#     FastMixer's own underrun counters, which is where that would show.

set -u

OVERLAY_DIR=/var/lib/waydroid/overlay
ROOTFS=/var/lib/waydroid/rootfs
VENDOR_IMG=/etc/waydroid-extra/images/vendor.img
HAL_REL=vendor/lib/hw/audio.primary.waydroid.so
XML_REL=vendor/etc/audio_policy_configuration.xml
STATE=/var/lib/waydroid/.audio-fastpath.revert

# The stock 32-bit HAL this transform was derived against.
HAL_SHA_STOCK=cac012cfc7d8b1852635afdf34d160f7b9524e927fba3f17c9424b1b2b639cd2
# Both patch sites are keyed on their full instruction encoding, each verified to
# occur exactly once in the stock file. See the HAL PATCH block in on().

FRAMES=256
LATFRAMES=1024
VERB=${1:-status}
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        --frames) FRAMES=${2:?--frames needs a value}; shift 2 ;;
        --latency-frames) LATFRAMES=${2:?--latency-frames needs a value}; shift 2 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
kv()    { printf '  %-32s %s\n' "$1" "$2"; }
say()   { printf '  %s\n' "$1"; }
warn()  { printf '  \033[33m%s\033[0m\n' "$1"; }
die()   { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

have_python() { command -v python3 >/dev/null 2>&1 || die "python3 is needed to patch the HAL"; }

af_dump() { waydroid shell -- sh -c 'dumpsys media.audio_flinger' 2>/dev/null; }

# hw_params reads as the single word "closed" when nothing holds the PCM, so a
# plain sed yields an empty string rather than failing -- check for it.
hwp_field() {
    V=$(sed -n "s/^$1: *//p" /proc/asound/card1/pcm0p/sub0/hw_params 2>/dev/null)
    [ -n "$V" ] && printf '%s frames\n' "$V" || printf 'closed (nothing playing)\n'
}

# ---- reporting -------------------------------------------------------------

report_live() {
    D=$(af_dump)
    if [ -z "$D" ]; then
        warn "no session -- cannot read dumpsys media.audio_flinger"
        return
    fi
    kv "HAL frame count"    "$(echo "$D" | sed -n 's/^ *HAL frame count: *//p'    | head -1)"
    kv "Normal frame count" "$(echo "$D" | sed -n 's/^ *Normal frame count: *//p' | head -1)"
    kv "sample rate"        "$(echo "$D" | sed -n 's/^ *Sample rate: *//p'        | head -1)"
    # CAREFUL. "No FastMixer statistics available currently" is FastMixerDumpState
    # saying it has no SAMPLES yet, which happens whenever nothing has played --
    # it means the FastMixer EXISTS. The line for a genuinely absent FastMixer is
    # exactly "  No FastMixer". A substring match on 'No FastMixer' conflates the
    # two and reports success as failure; that cost a false negative on
    # 2026-10-05, on the very run that had in fact worked.
    if echo "$D" | grep -qE '^[[:space:]]*No FastMixer[[:space:]]*$'; then
        kv "FastMixer" "ABSENT -- no FastMixer thread was constructed"
    else
        kv "FastMixer" "PRESENT"
        AVAIL=$(echo "$D" | sed -n 's/^ *Fast track availMask=//p' | head -1)
        PIPE=$(echo "$D"  | sed -n 's/^ *Monopipe write pipe depth stats: *//p' | head -1)
        FLAGS=$(echo "$D" | sed -n 's/^ *AudioStreamOut: [^ ]* flags *//p' | head -1)
        PSINK=$(echo "$D" | sed -n 's/^ *PipeSink frames written: *//p' | head -1)
        [ -n "$FLAGS" ] && kv "  stream flags" "$FLAGS"
        [ -n "$AVAIL" ] && kv "  fast track availMask" "$AVAIL"
        [ -n "$PIPE" ]  && kv "  monopipe depth" "$PIPE"
        [ -n "$PSINK" ] && kv "  PipeSink frames written" "$PSINK"
        if echo "$D" | grep -q 'No FastMixer statistics available currently'; then
            say "  (no statistics yet -- nothing has played; they appear once audio flows)"
        else
            echo "$D" | grep -iE 'fastmixer|underrun|sampling N|measured warmup' \
                      | sed 's/^/        /' | head -14
        fi
    fi
    FD=$(echo "$D" | grep -c 'AUDIO_OUTPUT_FLAG_FAST denied' 2>/dev/null || true)
    [ "${FD:-0}" -gt 0 ] && warn "dumpsys mentions AUDIO_OUTPUT_FLAG_FAST denied"
    return 0
}

status() {
    head_ "Waydroid audio fast path"
    kv "session" "$(waydroid status 2>/dev/null | sed -n 's/^Session:[[:space:]]*//p')"
    [ -f "$STATE" ] && kv "state file" "$STATE (on)" || kv "state file" "absent (off)"

    head_ "Overlay files"
    for r in "$HAL_REL" "$XML_REL"; do
        if [ -f "$OVERLAY_DIR/$r" ]; then
            kv "$r" "present"
        else
            kv "$r" "absent (stock)"
        fi
    done

    head_ "Live, from dumpsys media.audio_flinger"
    report_live

    head_ "Card"
    HWP=/proc/asound/card1/pcm0p/sub0/hw_params
    kv "pcm0p buffer"    "$(hwp_field buffer_size)"
    kv "pcm0p period"    "$(hwp_field period_size)"
    kv "subdevices"      "$(sed -n 's/^subdevices_count: *//p' /proc/asound/card1/pcm0p/info 2>/dev/null)"
    echo
}

# ---- apply -----------------------------------------------------------------

on() {
    have_python
    case "$FRAMES" in ''|*[!0-9]*) die "--frames must be a number" ;; esac
    [ "$FRAMES" -ge 64 ]   || die "--frames $FRAMES is below 64; AudioFlinger will not thank you"
    [ "$FRAMES" -le 1024 ] || die "--frames $FRAMES exceeds the stock 1024; this verb only shrinks"
    [ $((FRAMES % 16)) -eq 0 ] || die "--frames must be a multiple of 16 (AudioMixer requires it)"
    case "$LATFRAMES" in ''|*[!0-9]*) die "--latency-frames must be a number" ;; esac
    [ "$LATFRAMES" -ge 64 ]   || die "--latency-frames $LATFRAMES is implausibly small"
    [ "$LATFRAMES" -le 4096 ] || die "--latency-frames $LATFRAMES exceeds the stock 4096"

    # DERIVE FROM THE IMAGE, NOT FROM $ROOTFS. Paid for on 2026-10-06: once the
    # overlay is applied, /var/lib/waydroid/rootfs IS the overlay-merged view, so
    # reading the HAL back through it returns the file this script wrote last
    # time. `on` would then patch an already-patched file -- the byte sequence
    # would no longer be found, and with a less careful gate it would have
    # silently produced something wrong. The hash check caught it, which is the
    # argument for having it fail loudly rather than skip.
    #
    # vendor.img is ext2 and debugfs reads it without mounting anything, which is
    # the same mechanism waydroid-overlay-sync's `derive` rows use. Its root is
    # /vendor, so the in-image paths drop the leading "vendor/".
    [ -f "$VENDOR_IMG" ] || die "$VENDOR_IMG not found -- cannot derive from a stock image"
    command -v debugfs >/dev/null 2>&1 || die "debugfs not found (e2fsprogs) -- cannot read vendor.img"

    SRC_HAL=$(mktemp) || die "mktemp failed"
    SRC_XML=$(mktemp) || die "mktemp failed"
    trap 'rm -f "$SRC_HAL" "$SRC_XML"' EXIT HUP INT TERM
    debugfs -R "dump /${HAL_REL#vendor/} $SRC_HAL" "$VENDOR_IMG" 2>/dev/null
    debugfs -R "dump /${XML_REL#vendor/} $SRC_XML" "$VENDOR_IMG" 2>/dev/null
    [ -s "$SRC_HAL" ] || die "could not extract /${HAL_REL#vendor/} from $VENDOR_IMG"
    [ -s "$SRC_XML" ] || die "could not extract /${XML_REL#vendor/} from $VENDOR_IMG"

    head_ "Deriving from the host's own stock image"
    kv "source" "$VENDOR_IMG (via debugfs, unmounted)"
    GOT=$(sha256sum "$SRC_HAL" | cut -d' ' -f1)
    kv "stock HAL sha256" "$GOT"
    if [ "$GOT" != "$HAL_SHA_STOCK" ]; then
        die "HAL hash has moved -- expected $HAL_SHA_STOCK.
  This transform was derived by disassembling that exact build. Re-verify the
  patch site before forcing it; a blind patch here writes a wrong immediate
  into whatever instruction now sits at that byte sequence."
    fi
    say "matches the build this transform was derived against"

    mkdir -p "$OVERLAY_DIR/vendor/lib/hw" "$OVERLAY_DIR/vendor/etc" || die "cannot create overlay dirs"

    # --- 1. the HAL constants, both of them ---
    python3 - "$SRC_HAL" "$OVERLAY_DIR/$HAL_REL" "$FRAMES" "$LATFRAMES" <<'HALPATCH' || die "HAL patch failed"
import struct, sys
src, dst, frames, latframes = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
f = bytearray(open(src, 'rb').read())
# Each site is keyed on its whole instruction encoding, verified to occur exactly
# once in the stock file, so the transform does not depend on a brittle offset.
patches = [
    ("get_buffer_size frames", bytes.fromhex('be00080000'),
     b'\xbe' + struct.pack('<I', frames * 2)),
    ("get_latency dividend",   bytes.fromhex('b800803e00'),
     b'\xb8' + struct.pack('<I', latframes * 1000)),
]
for name, find, repl in patches:
    n = bytes(f).count(find)
    if n != 1:
        sys.exit("  %s: site occurs %d times, expected exactly 1 -- refusing" % (name, n))
    off = bytes(f).find(find)
    f[off:off + len(repl)] = repl
    print("  %-24s %s -> %s  @ %s" % (name, find.hex(' '), repl.hex(' '), hex(off)))
open(dst, 'wb').write(bytes(f))
HALPATCH
    chmod 0644 "$OVERLAY_DIR/$HAL_REL"
    kv "overlay HAL sha256" "$(sha256sum "$OVERLAY_DIR/$HAL_REL" | cut -d' ' -f1)"
    kv "get_buffer_size now reports" "$FRAMES frames ($(python3 -c "print('%.2f' % ($FRAMES/48.0))") ms at 48 kHz)"
    kv "get_latency now reports" "$((LATFRAMES * 1000 / 48000)) ms (was 85, from a 4096-frame buffer this card never had)"

    # --- 2. the policy flag ---
    # Output: add FAST to the existing mixPort (see the note above on why not a
    # new one). Input: the primary input mixPort carries NO flags attribute at
    # all, which is why capture was handed a 2880-frame (60 ms) buffer against a
    # 640-frame minimum -- there is no fast capture path for it to land on.
    # AUDIO_INPUT_FLAG_FAST is the symmetric fix, and goes on the existing
    # mixPort for the same reason: pcm0c has one substream too.
    sed -e 's#\(<mixPort name="primary output" role="source" flags="AUDIO_OUTPUT_FLAG_PRIMARY\)"#\1|AUDIO_OUTPUT_FLAG_FAST"#' \
        -e 's#\(<mixPort name="primary input" role="sink"\)>#\1 flags="AUDIO_INPUT_FLAG_FAST">#' \
        "$SRC_XML" > "$OVERLAY_DIR/$XML_REL" || die "cannot write the policy overlay"
    CNT=$(grep -c 'AUDIO_OUTPUT_FLAG_PRIMARY|AUDIO_OUTPUT_FLAG_FAST' "$OVERLAY_DIR/$XML_REL")
    ICNT=$(grep -c 'AUDIO_INPUT_FLAG_FAST' "$OVERLAY_DIR/$XML_REL")
    if [ "$CNT" -ne 1 ] || [ "$ICNT" -ne 1 ]; then
        rm -f "$OVERLAY_DIR/$XML_REL"
        die "policy edit matched out:$CNT in:$ICNT, expected 1 each -- a mixPort line has
  changed shape. Refusing rather than shipping a half-edited policy."
    fi
    chmod 0644 "$OVERLAY_DIR/$XML_REL"
    kv "primary output flags" "AUDIO_OUTPUT_FLAG_PRIMARY|AUDIO_OUTPUT_FLAG_FAST"
    kv "primary input flags" "AUDIO_INPUT_FLAG_FAST (was: none declared)"

    {
        echo "# written by bin/audio-fastpath.sh on $(date -Is)"
        echo "frames=$FRAMES"
        echo "latency_frames=$LATFRAMES"
        echo "stock_hal_sha256=$HAL_SHA_STOCK"
        echo "overlay_hal=$OVERLAY_DIR/$HAL_REL"
        echo "overlay_xml=$OVERLAY_DIR/$XML_REL"
    } > "$STATE"

    head_ "Nothing has been restarted, and that is deliberate"
    say "The overlay is merged by mount_rootfs() at SESSION start. To apply:"
    say "  log out of the waydroid-cage session at SDDM and log back in."
    say "Do NOT 'systemctl restart waydroid-container' -- it applies nothing and"
    say "strands the kiosk at the greeter."
    say ""
    say "Then: ssh 10.42.0.137 'sudo sh -s' -- verify < bin/audio-fastpath.sh"
    echo
}

off() {
    head_ "Removing the fast-path overlay"
    for r in "$HAL_REL" "$XML_REL"; do
        if [ -f "$OVERLAY_DIR/$r" ]; then
            rm -f "$OVERLAY_DIR/$r" && kv "removed" "$r"
        else
            kv "already absent" "$r"
        fi
    done
    rm -f "$STATE"
    say "The image's own files take over again -- nothing was modified in place."
    head_ "Log out and back in to apply"
    echo
}

verify() {
    head_ "Is the overlay actually in effect?"
    if ! waydroid status 2>/dev/null | grep -q 'Session:.*RUNNING'; then
        die "no running session -- log in to the waydroid-cage session first"
    fi

    # Read from INSIDE the container; ls-ing the overlay dir proves nothing.
    IN_XML=$(waydroid shell -- sh -c "grep -c 'AUDIO_OUTPUT_FLAG_PRIMARY|AUDIO_OUTPUT_FLAG_FAST' /vendor/etc/audio_policy_configuration.xml" 2>/dev/null | tr -cd '0-9')
    kv "policy FAST flag, in container" "${IN_XML:-0} match(es)"
    IN_SHA=$(waydroid shell -- sh -c "sha256sum /vendor/lib/hw/audio.primary.waydroid.so" 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$IN_SHA" ]; then
        kv "HAL sha256, in container" "$IN_SHA"
        if [ "$IN_SHA" = "$HAL_SHA_STOCK" ]; then
            warn "that is the STOCK hash -- the overlay is NOT in effect"
        elif [ -f "$OVERLAY_DIR/$HAL_REL" ] && \
             [ "$IN_SHA" = "$(sha256sum "$OVERLAY_DIR/$HAL_REL" | cut -d' ' -f1)" ]; then
            say "matches the overlay file -- the patched HAL is live"
        fi
    else
        warn "could not hash the HAL from inside the container"
    fi

    head_ "Did it do anything?"
    report_live
    say ""
    say "Wanted: HAL frame count below Normal frame count, and a FastMixer."
    say "Three independent signs the FastMixer is real, all in the dump above:"
    say "  - 'Fast track availMask', the fast-track slot bitmap"
    say "  - 'Monopipe write pipe depth', the pipe from the normal mixer to it"
    say "  - 'PipeSink frames written', i.e. the sink is a pipe, not the HAL"
    say "Note that 'Normal frame count' differing from 'HAL frame count' already"
    say "rules out kUseFastMixer == FastMixer_Never: the scaling that produces it"
    say "only runs under FastMixer_Static or _Dynamic."
    echo
}

case "$VERB" in
    status) status ;;
    on)     on     ;;
    off)    off    ;;
    verify) verify ;;
    *) printf 'usage: %s {status|on [--frames N]|off|verify}\n' "$0" >&2; exit 2 ;;
esac
