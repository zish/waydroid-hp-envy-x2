#!/bin/sh
# alsa-vs-pulse.sh -- one instrument, two arms: measure Waydroid's audio path
# whether it runs through pipewire-pulse or straight at a /dev/snd card.
# Goal 5, docs/44-audio-alsa-backend.md.
#
#     ssh 10.42.0.137 'sudo sh -s' < bin/alsa-vs-pulse.sh > arm-pulse.txt
#     ssh 10.42.0.137 'sudo sh -s' < bin/alsa-vs-pulse.sh > arm-alsa.txt
#     diff -y arm-pulse.txt arm-alsa.txt
#
# It takes no argument and chooses no backend. It REPORTS which one is live --
# by asking who owns the card, not by reading config -- so the same file is the
# correct instrument for both arms and cannot be run against the wrong one.
#
# READ-ONLY. No mount, no ACL, no overlay file, no profile change, no restart.
# bin/alsa-arm.sh is the half that changes things.
#
# WHY IT SAMPLES EVERYTHING TWICE
#
# Every fault worth finding here is a RATE, and all four of the counters that
# would show it (PipeWire ERR, AudioFlinger's delayed writes, its timestamp
# errors, ALSA's avail_max) are CUMULATIVE since the stream opened. docs/56
# records a quantum ladder that reported zero xruns at a setting a listener
# called unusable, partly for exactly this reason. So nothing here prints a
# bare total: each counter is read at T and T+GAP and the delta is what the
# report shows. A total is printed only as context, in parentheses.
#
# IT INSISTS ON AUDIO PLAYING, for the same reason pw-audio-diag.sh does: an
# idle path misses no deadlines and jitters not at all, so every number below
# would be a clean zero that means nothing. Start playback first, e.g.
#
#   waydroid shell -- am start -n org.videolan.vlc/.StartActivity \
#       -a android.intent.action.VIEW -t audio/x-wav \
#       -d file:///storage/emulated/0/Music/abtone.wav

set -u

GAP=${GAP:-20}
CARD=${CARD:-1}
DEV=${DEV:-0}

head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
kv()    { printf '  %-34s %s\n' "$1" "$2"; }
inf()   { printf '        %s\n' "$1"; }
no()    { printf '  \033[31m%-34s\033[0m %s\n' "$1" "$2"; }

PCM=/proc/asound/card$CARD/pcm${DEV}p/sub0

# The session user owns the PipeWire graph; every pw-*/wpctl call has to be made
# as them, with their bus, or it talks to nothing and reports a healthy silence.
WDUSER=$(waydroid status 2>/dev/null | sed -n 's/^Session user:[[:space:]]*\([^(]*\)(.*/\1/p' | tr -d '[:space:]')
[ -n "${WDUSER:-}" ] || WDUSER=$(ls -d /home/*/.local/share/waydroid/data 2>/dev/null |
    head -1 | sed 's|^/home/\([^/]*\)/.*|\1|')
WDUID=$(id -u "$WDUSER" 2>/dev/null || echo 1000)
pw() { runuser -u "$WDUSER" -- env "XDG_RUNTIME_DIR=/run/user/$WDUID" $* 2>/dev/null; }

ash() { waydroid shell -- sh -c "$1" 2>&1 | grep -v 'Permission denied: 1'; }

# ---------------------------------------------------------------- arm detection

head_ "0. Which arm is this?"

# owner_pid in /proc/asound is a THREAD id, and the thread is named for its job
# ("writer"), not for its program -- so it has to be resolved through Tgid to
# the process and then to its cmdline. Reading /proc/<owner_pid>/comm alone
# reports "writer", which identifies nothing.
#
# And the process is NOT audioserver. Measured: the PCM is held by
# /vendor/bin/hw/android.hardware.audio.service, a separate HAL service process
# running as uid 1000 (AID_SYSTEM) with gid 1041 (AID_AUDIO), while audioserver
# is a different pid at uid 1041. Anything keyed on audioserver -- an arm
# detector, or an ACL granting uid 1041 -- is aimed at the wrong process.
OWNER_TID=$(sed -n 's/^owner_pid *: *//p' "$PCM/status" 2>/dev/null)
OWNER=""; OWNER_PID=""; OWNER_UID=""
if [ -n "${OWNER_TID:-}" ] && [ -d "/proc/$OWNER_TID" ]; then
    OWNER_PID=$(grep -a '^Tgid:' "/proc/$OWNER_TID/status" 2>/dev/null | awk '{print $2}')
    OWNER_PID=${OWNER_PID:-$OWNER_TID}
    OWNER=$(tr -d '\0' < "/proc/$OWNER_PID/cmdline" 2>/dev/null)
    [ -n "${OWNER:-}" ] || OWNER=$(tr -d '\0' < "/proc/$OWNER_PID/comm" 2>/dev/null)
    OWNER_UID=$(grep -a '^Uid:' "/proc/$OWNER_PID/status" 2>/dev/null | awk '{print $2}')
fi

# The decisive question is not what asound.conf says, it is who holds the PCM.
# The Android audio HAL service holding it means the HAL reached the card;
# pipewire holding it means the HAL is upstream of the graph; nobody holding it
# means no audio is playing and every number below would be unearned.
case "$OWNER" in
    *android.hardware.audio*|*audioserver*) ARM=alsa  ;;
    *pipewire*)                             ARM=pulse ;;
    "")                                     ARM=idle  ;;
    *)                                      ARM="other:$OWNER" ;;
esac

if [ "$ARM" = idle ]; then
    no "ARM = idle" "nothing holds hw:$CARD,$DEV -- is audio playing?"
    inf "Every number below would be a zero that it has not earned."
    inf "Start playback in Android, then re-run. See the header of this file."
else
    kv "ARM" "$ARM"
fi
kv "hw:$CARD,$DEV held by" "${OWNER:-nobody}"
kv "  its pid / uid"       "${OWNER_PID:-none} / ${OWNER_UID:-none}"
kv "/system/etc/asound.conf" \
   "$([ -e /var/lib/waydroid/rootfs/system/etc/asound.conf ] && echo present || echo absent)"
kv "/dev/snd in container" \
   "$(grep -qs 'dev/snd' /var/lib/waydroid/lxc/waydroid/config_nodes \
        /var/lib/waydroid/lxc/waydroid/config_session && echo mounted || echo not mounted)"
kv "pulse socket in container" \
   "$(grep -qs 'pulse/native' /var/lib/waydroid/lxc/waydroid/config_session \
        && echo mounted || echo not mounted)"

# ------------------------------------------------------- the card, kernel's view

head_ "1. The card, as the kernel sees it"

if [ -r "$PCM/hw_params" ] && [ "$(cat "$PCM/hw_params")" != closed ]; then
    ACC=$(sed -n 's/^access: *//p'      "$PCM/hw_params")
    FMT=$(sed -n 's/^format: *//p'      "$PCM/hw_params")
    CH=$(sed  -n 's/^channels: *//p'    "$PCM/hw_params")
    RATE=$(sed -n 's/^rate: *\([0-9]*\).*/\1/p' "$PCM/hw_params")
    PSZ=$(sed -n 's/^period_size: *//p' "$PCM/hw_params")
    BSZ=$(sed -n 's/^buffer_size: *//p' "$PCM/hw_params")
    kv "access"  "$ACC"
    kv "format"  "$FMT"
    kv "rate / channels" "$RATE Hz / $CH"
    kv "period_size" "$PSZ frames ($(awk "BEGIN{printf \"%.2f\", $PSZ*1000/$RATE}") ms)"
    kv "buffer_size" "$BSZ frames ($(awk "BEGIN{printf \"%.1f\", $BSZ*1000/$RATE}") ms, \
$(awk "BEGIN{printf \"%.0f\", $BSZ/$PSZ}") periods)"
    # delay is the only honest latency number in procfs: frames actually queued
    # between appl_ptr and the DMA pointer, not the size of the buffer holding them.
    D1=$(sed -n 's/^delay *: *//p' "$PCM/status")
    kv "delay (frames queued now)" "$D1 ($(awk "BEGIN{printf \"%.2f\", $D1*1000/$RATE}") ms)"
else
    no "hw:$CARD,$DEV" "closed -- no stream on the card"
fi

# --------------------------------------------------------------- the host graph

head_ "2. The host PipeWire graph"

NODES=$(pw 'pw-top -b -n 2' | tail -n +2 | awk '$1=="R"')
if [ -n "$NODES" ]; then
    # pw-top -b columns are: S ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME.
    # ERR is field 9, not 8 -- field 8 is B/Q, a float, which reads as a
    # plausible xrun count and then poisons every delta computed from it.
    printf '        %-3s %-6s %-6s %-9s %-5s %s\n' ID QUANT RATE BUSY ERR NAME
    echo "$NODES" | awk '{printf "        %-3s %-6s %-6s %-9s %-5s ", $2,$3,$4,$6,$9;
                          for(i=10;i<=NF;i++) printf "%s ", $i; print ""}'
    WD=$(echo "$NODES" | grep -c 'Waydroid')
    if [ "$WD" -gt 0 ]; then
        kv "Waydroid node in graph" "yes -- audio is going through the host graph"
    else
        kv "Waydroid node in graph" "no -- the HAL is not a PipeWire client"
    fi
else
    kv "pw-top" "no running nodes (graph idle or unreachable as $WDUSER)"
fi
kv "clock.quantum / force" \
   "$(pw 'pw-metadata -n settings' | sed -n "s/.*key:'clock.quantum' value:'\([0-9]*\)'.*/\1/p") / \
$(pw 'pw-metadata -n settings' | sed -n "s/.*key:'clock.force-quantum' value:'\([0-9]*\)'.*/\1/p")"

SI=$(pw 'pactl list sink-inputs' | grep -c 'application.name = "Waydroid"')
kv "Waydroid PA sink-input" "$SI"

# ---------------------------------------------------------- first counter read

read_counters() {
    # $1: output file. Everything cumulative, read as close together as possible.
    {
        echo "ERR $(pw 'pw-top -b -n 2' | tail -n +2 | awk '$1=="R"{e+=$9} END{print e+0}')"
        echo "AVAILMAX $(sed -n 's/^avail_max *: *//p' "$PCM/status" 2>/dev/null | head -1)"
        for n in pipewire pipewire-pulse wireplumber audioserver; do
            p=$(pgrep -x "$n" | head -1)
            [ -n "$p" ] && echo "CPU_$n $(awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null)"
        done
        ash 'dumpsys media.audio_flinger' | sed -n '/^Output thread/,/^Input thread/p' |
          sed -n 's/^ *Total writes: *\([0-9]*\).*/AFWRITES \1/p;
                  s/^ *Delayed writes: *\([0-9]*\).*/AFDELAYED \1/p;
                  s/.*err=\([0-9]*\).*/AFTSERR \1/p'
    } > "$1" 2>/dev/null
}

get() { sed -n "s/^$2 //p" "$1" | head -1; }

head_ "3. Rates, not totals ($GAP s window)"
read_counters /tmp/.avp1
sleep "$GAP"
read_counters /tmp/.avp2

delta() { # name label unit-per-sec?
    a=$(get /tmp/.avp1 "$1"); b=$(get /tmp/.avp2 "$1")
    if [ -z "${a:-}" ] || [ -z "${b:-}" ]; then kv "$2" "unavailable"; return; fi
    d=$((b - a))
    case "${3:-}" in
        cpu)  kv "$2" "$(awk "BEGIN{printf \"%.2f%% of a core\", $d/$GAP}") ($d ticks)" ;;
        rate) kv "$2" "$d in ${GAP}s ($(awk "BEGIN{printf \"%.3f\", $d/$GAP}")/s, total $b)" ;;
        *)    kv "$2" "$d (total $b)" ;;
    esac
}

delta ERR        "PipeWire xruns"            rate
delta AFDELAYED  "AudioFlinger delayed writes" rate
delta AFTSERR    "AudioFlinger timestamp errors" rate
delta AFWRITES   "AudioFlinger HAL writes"   rate
echo
delta CPU_pipewire       "cpu: pipewire"       cpu
delta CPU_pipewire-pulse "cpu: pipewire-pulse" cpu
delta CPU_wireplumber    "cpu: wireplumber"    cpu
delta CPU_audioserver    "cpu: audioserver"    cpu

A=$(get /tmp/.avp1 CPU_pipewire); B=$(get /tmp/.avp2 CPU_pipewire)
C=$(get /tmp/.avp1 CPU_pipewire-pulse); E=$(get /tmp/.avp2 CPU_pipewire-pulse)
if [ -n "${A:-}" ] && [ -n "${C:-}" ]; then
    kv "cpu: host graph total" \
       "$(awk "BEGIN{printf \"%.2f%% of a core\", (($B-$A)+($E-$C))/$GAP}")"
fi

# -------------------------------------------------------- AudioFlinger's own view

head_ "4. What AudioFlinger thinks it is writing to"

AF=$(ash 'dumpsys media.audio_flinger' | sed -n '/^Output thread/,/^Input thread/p')
if [ -n "$AF" ]; then
    echo "$AF" | sed -n 's/^ *\(Sample rate\|HAL frame count\|HAL format\|HAL buffer size\|Channel count\|Processing format\|Normal frame count\|Standby\|Output devices\|Blocked in write\):.*/        &/p' |
        sed 's/^        *//' | while read -r l; do inf "$l"; done
    # The two lines that actually separate the arms. Jitter is how regular the
    # HAL's write() returns are, i.e. how steady the clock downstream of it is.
    echo "$AF" | grep -E 'Hal write jitter|Process time ms stats' |
        sed 's/^ *//' | while read -r l; do inf "$l"; done
    inf "$(echo "$AF" | grep -oE 'err=[0-9]+ jitterMs[^ ]*' | head -1)"
    # Signal power proves samples are present and at what level, so a silent
    # arm cannot be mistaken for a quiet one.
    # The history is "MM-DD HH:MM:SS.mmm:  <ten dB values>", so the level is
    # field 3 -- field 2 is the timestamp. Anchored on the date shape and
    # carried to the end in one awk pass: the section runs on past the history
    # into the per-track dump, and a `tail -1` over it picks up a table header
    # and prints one of its column names as if it were a level.
    # A history line is "MM-DD HH:MM:SS.mmm:  <ten dB values>", and it takes all
    # THREE of those shapes to identify one, because the latch stays armed to
    # the end of the section and two other lines look like it if you check
    # fewer. Checking only the leading date admits
    #     10-04 22:56:08.143 UID 10181, 1 KVP received: bgm_state=false
    # from the setParameters log, and reports the level as "UID". Adding
    # "timestamp ends in a colon, third field numeric" admits
    #     Master balance: 0.000000 (balance 0 channelCount 2 volumes: 1 1)
    # and reports the level as 0.000000 -- which looks like full scale, i.e.
    # exactly the kind of plausible wrong number that gets believed. Requiring
    # the date in $1 as well leaves nothing else in the section that matches.
    inf "signal power now: $(echo "$AF" |
        awk '/Signal power history/ { f = 1; next }
             f && $1 ~ /^[0-9][0-9]-[0-9][0-9]$/ && $2 ~ /:$/ &&
                  $3 ~ /^-?[0-9]+\.[0-9]+$/ { v = $3 }
             END { print (v == "" ? "unavailable" : v) }') dBFS"
else
    no "dumpsys media.audio_flinger" "no output thread -- is the container up?"
fi

head_ "5. What apps are allowed to ask for"
inf "$(ash 'getprop waydroid.audio_device'   ) <- waydroid.audio_device (empty = HAL default \"pulse\")"
ash 'dumpsys audio' 2>/dev/null | sed -n '/^Audio routes/,/^$/p' | head -6 |
    while read -r l; do [ -n "$l" ] && inf "$l"; done

rm -f /tmp/.avp1 /tmp/.avp2
printf '\n'
