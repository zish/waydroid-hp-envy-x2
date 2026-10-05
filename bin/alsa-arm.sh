#!/bin/sh
# alsa-arm.sh -- switch Waydroid's audio HAL between pipewire-pulse and a real
# ALSA card, and switch it back. Goal 5, docs/44-audio-alsa-backend.md.
#
#     ssh 10.42.0.137 'sudo sh -s' -- status  < bin/alsa-arm.sh
#     ssh 10.42.0.137 'sudo sh -s' -- caps    < bin/alsa-arm.sh
#     ssh 10.42.0.137 'sudo sh -s' -- on      < bin/alsa-arm.sh
#     ssh 10.42.0.137 'sudo sh -s' -- on --pcm hw  < bin/alsa-arm.sh
#     ssh 10.42.0.137 'sudo sh -s' -- off     < bin/alsa-arm.sh
#
# bin/alsa-vs-pulse.sh is the read-only instrument; this is the half that
# changes things.
#
# NEITHER `on` NOR `off` RESTARTS ANYTHING. Both end by telling you to restart
# the Waydroid SESSION, and that is deliberate.
#
# The overlay file and the config_nodes mount entry are both read exactly once,
# by mount_rootfs() and by LXC respectively, and both of those run at SESSION
# start -- not at container start. `systemctl restart waydroid-container` looks
# like the right lever and is not: it restarts a service that is thin
# (`waydroid container start`) while the session that owns the rootfs mount and
# the Android boot is a user session. MEASURED: running it ended the cage
# session after 282499s and left the machine at the SDDM greeter with the
# rootfs not mounted at all, so the overlay never merged, /dev/snd never
# appeared, and the arm silently did not switch. Under cage
# ([docs/25](25-waydroid-in-cage.md)) there is no autologin, so getting it back
# needs someone at the keyboard. That is the whole reason this script stops
# short and prints instructions instead.
#
# WHAT `on` DOES, AND WHY EACH PIECE IS NEEDED
#
# 1. An overlay /system/etc/asound.conf redefining the alsa-lib name the HAL
#    opens. No HAL rebuild: audio.primary.waydroid.so links libasound.so and
#    NOTHING ELSE -- no libpulse -- and calls snd_pcm_open() with the literal
#    name "pulse", which is only a config alias, defined at line 662 of
#    /vendor/usr/share/alsa/alsa.conf. That file's @hooks block loads
#    /etc/asound.conf AFTER its own definitions and /etc is a symlink to
#    /system/etc, so a later definition wins. It must be `pcm.!pulse` with the
#    bang: without it alsa-lib MERGES with the existing block and collides on
#    `type`, which fails in a way that looks like the file was ignored.
#
# 2. The /dev/snd bind mount. generate_nodes_lxc_config() globs /dev/video*,
#    /dev/fb* and /dev/dma_heap/* and has no /dev/snd, so the container has no
#    sound nodes at all. This goes in config_nodes, which waydroid writes only
#    from `waydroid init` -- container start regenerates only config_session --
#    so the entry survives restarts and reboots, and dies at the next init or
#    package upgrade. No device-cgroup rule is needed; the generated config
#    carries no lxc.cgroup2.devices.* at all, same as the camera nodes.
#
# 3. A udev rule putting mode 0666 on the chosen card's nodes. /dev/snd/* is
#    root:audio 0660 and the host's `audio` group is gid 63, while Android's
#    audioserver is uid 1041 gid 1005 with no supplementary group anywhere near
#    63 -- measured, not assumed. There is no idmap, so Android's uids ARE the
#    host's uids, and /dev/video0 being world-accessible is the only reason the
#    camera works without anything like this.
#
#    An earlier version of this script used `setfacl -m u:1041:rw` instead,
#    which is more surgical and does not work: udev's uaccess ACL is re-applied
#    to /dev/snd/* whenever the active seat session changes, and it rewrites the
#    whole ACL rather than merging. MEASURED -- the extra entry was gone within
#    seconds of the first session restart, replaced by `user:sddm:rw-` when the
#    machine fell back to the greeter. A rule is not merely the more durable
#    form, it is the only one that survives the very restart that applies it.
#
#    0666 is the cost of that, and it is scoped to the one card being handed
#    over rather than to /dev/snd as a whole.
#
# 4. WirePlumber's profile for the card set to "Off". Every PCM on this machine
#    has exactly ONE substream, so a second opener of hw:1,0 gets EBUSY; dmix
#    cannot bridge the two sides because the container has its own IPC
#    namespace and PipeWire does not use dmix anyway. So this is not sharing,
#    it is handing the device over. PipeWire does leave the PCM closed while
#    idle, which makes the naive version of this LOOK like it works and then
#    lose a race the first time the host plays a sound. Profile Off is the
#    non-racy form. SELinux is not part of this list: the container's audio
#    domain is container_runtime_t, which is allowed open/read/write/ioctl/map
#    on sound_device_t, and Android's own SELinux inside the image is Disabled.
#
# `off` undoes all four from the state file written by `on`, so the revert does
# not depend on this script's defaults still matching what `on` was given.
#
# `verify` is the post-restart check: it is the verb that says whether the arm
# actually took, and it can only tell the truth once the session is back up.

set -u

STATE=/var/lib/waydroid/.alsa-arm.revert
UDEV=/etc/udev/rules.d/99-waydroid-alsa-arm.rules
OVERLAY=/var/lib/waydroid/overlay/system/etc/asound.conf
NODES=/var/lib/waydroid/lxc/waydroid/config_nodes
MOUNT_LINE='lxc.mount.entry = /dev/snd dev/snd none bind,create=dir,optional 0 0'
ANDROID_AUDIO_UID=1041

CARD=1
DEV=0
PCMTYPE=plug

VERB=${1:-status}
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        --pcm)  PCMTYPE=$2; shift 2 ;;
        --card) CARD=$2;    shift 2 ;;
        --dev)  DEV=$2;     shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
kv()    { printf '  %-32s %s\n' "$1" "$2"; }
say()   { printf '  %s\n' "$1"; }
die()   { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

WDUSER=$(waydroid status 2>/dev/null | sed -n 's/^Session user:[[:space:]]*\([^(]*\)(.*/\1/p' | tr -d '[:space:]')
[ -n "${WDUSER:-}" ] || WDUSER=$(ls -d /home/*/.local/share/waydroid/data 2>/dev/null |
    head -1 | sed 's|^/home/\([^/]*\)/.*|\1|')
WDUID=$(id -u "$WDUSER" 2>/dev/null) || die "cannot resolve the session user"
pw() { runuser -u "$WDUSER" -- env "XDG_RUNTIME_DIR=/run/user/$WDUID" "$@" 2>/dev/null; }

# Everything about the card comes out of one pw-dump, parsed structurally:
# info.params.Profile is the active profile and info.params.EnumProfile the
# list, both already carrying index/name/description. `pw-cli enum-params`
# prints the same data as a flat stream of "Int"/"String" lines with nested
# ints interleaved, which cannot be parsed by position without guessing.
#
# The card is matched on str() of both sides deliberately: api.alsa.card is an
# INT in pw-dump's JSON and a quoted string in `wpctl inspect`'s output, so a
# raw == against "1" matches nothing and reports the card as absent.
#
# Resolved by card number every time, never by a remembered object id: ids
# churn whenever PipeWire restarts, and `off` may run much later than `on`.
card_info() {   # $1: "id" | "profile" | <profile name>
    pw pw-dump | python3 -c '
import json, sys
want, field = str(sys.argv[1]), sys.argv[2]
for o in json.load(sys.stdin):
    if o.get("type") != "PipeWire:Interface:Device":
        continue
    info = o.get("info", {})
    if str(info.get("props", {}).get("api.alsa.card")) != want:
        continue
    params = info.get("params", {})
    if field == "id":
        print(o["id"])
    elif field == "profile":
        for e in params.get("Profile", []):
            if isinstance(e, dict):
                print(e.get("index")); break
    else:
        for e in params.get("EnumProfile", []):
            if isinstance(e, dict) and e.get("name") == field:
                print(e.get("index")); break
    break
' "$CARD" "$1"
}

card_device_id()        { card_info id; }
card_profile_index()    { card_info profile; }
profile_index_by_name() { card_info "$1"; }

pcm_owner() {
    p=$(sed -n 's/^owner_pid *: *//p' "/proc/asound/card$CARD/pcm${DEV}p/sub0/status" 2>/dev/null)
    [ -n "${p:-}" ] && tr -d '\0' < "/proc/$p/comm" 2>/dev/null
}

snd_nodes() {
    echo "/dev/snd/controlC$CARD /dev/snd/pcmC${CARD}D${DEV}p /dev/snd/pcmC${CARD}D${DEV}c /dev/snd/timer"
}

status() {
    head_ "alsa-arm status"
    kv "card / device"            "hw:$CARD,$DEV"
    kv "overlay asound.conf"      "$([ -f "$OVERLAY" ] && echo "present" || echo absent)"
    [ -f "$OVERLAY" ] && sed -n 's/^/        /p' "$OVERLAY"
    kv "visible in container as"  "$([ -f /var/lib/waydroid/rootfs/system/etc/asound.conf ] \
                                      && echo "/system/etc/asound.conf" || echo "(not merged)")"
    kv "/dev/snd mount entry"     "$(grep -qs 'dev/snd' "$NODES" && echo present || echo absent)"
    kv "/dev/snd in container"    "$(waydroid shell -- sh -c 'ls /dev/snd 2>/dev/null | tr "\n" " "' 2>/dev/null |
                                      grep -v 'Permission denied' | tr -d '\r')"
    kv "udev rule"                "$([ -f "$UDEV" ] && echo "present" || echo absent)"
    # Mode bits, not ACLs. getfacl resolves uids to names unless given -n, so
    # an entry for 1041 can print as some unrelated host user and a grep for
    # "user:1041:" then reports it missing -- which is how the ACL version of
    # this check lied before the mechanism was changed.
    for n in $(snd_nodes); do
        [ -e "$n" ] && kv "mode $(basename "$n")" \
            "$(stat -c '%A %U:%G' "$n")$(getfacl -pn "$n" 2>/dev/null |
                 grep -q "^user:$ANDROID_AUDIO_UID:" && echo "  (+acl uid $ANDROID_AUDIO_UID)")"
    done
    DID=$(card_device_id)
    kv "pipewire device for card $CARD" "${DID:-none}"
    [ -n "${DID:-}" ] && kv "active profile index" "$(card_profile_index)"
    kv "hw:$CARD,$DEV held by"    "$(pcm_owner || echo "nobody (closed)")"
    kv "state file"               "$([ -f "$STATE" ] && echo "$STATE" || echo "none -- arm is pulse")"
    [ -f "$STATE" ] && sed -n 's/^/        /p' "$STATE"
    printf '\n'
}

caps() {
    # Only meaningful while the PCM is free: busy means PipeWire still has it,
    # and the answer would be EBUSY rather than the card's real range.
    head_ "What hw:$CARD,$DEV actually accepts"
    o=$(pcm_owner)
    if [ -n "${o:-}" ]; then
        say "hw:$CARD,$DEV is held by $o -- run \`on\` first, or these numbers"
        say "would just be EBUSY. This is the card's range, not the HAL's choice."
        return
    fi
    # -f S16_LE matters: with no -f, aplay defaults to U8, the card refuses it,
    # and the real dump is followed by "Sample format non available" -- which
    # reads as a failure of the probe rather than of the default.
    aplay --dump-hw-params -f S16_LE -D "hw:$CARD,$DEV" /dev/zero 2>&1 |
        sed -n '/HW Params/,$p' | sed -n 's/^/        /p' | head -20
}

on() {
    [ -f "$STATE" ] && die "already on (state file $STATE exists) -- run \`off\` first"
    case "$PCMTYPE" in plug|hw) ;; *) die "--pcm must be plug or hw" ;; esac
    [ -e "/dev/snd/pcmC${CARD}D${DEV}p" ] || die "no /dev/snd/pcmC${CARD}D${DEV}p on this host"

    DID=$(card_device_id)
    [ -n "${DID:-}" ] || die "no PipeWire device for ALSA card $CARD"
    OLDPROF=$(card_profile_index)
    OFFPROF=$(profile_index_by_name off)
    [ -n "${OFFPROF:-}" ] || die "card $CARD has no \"off\" profile to switch to"

    HAD_MOUNT=no;   grep -qs 'dev/snd' "$NODES" && HAD_MOUNT=yes
    HAD_OVERLAY=no; [ -f "$OVERLAY" ] && HAD_OVERLAY=yes
    HAD_UDEV=no;    [ -f "$UDEV" ]    && HAD_UDEV=yes

    head_ "Building the ALSA arm: hw:$CARD,$DEV via pcm type $PCMTYPE"

    # 0. revert state first, so a failure halfway is still undoable.
    cat > "$STATE" <<EOF
card=$CARD
dev=$DEV
pcmtype=$PCMTYPE
pw_device=$DID
old_profile=$OLDPROF
had_mount=$HAD_MOUNT
had_overlay=$HAD_OVERLAY
had_udev=$HAD_UDEV
snd_nodes=$(snd_nodes)
EOF
    say "wrote revert state to $STATE"

    # 1. the override.
    mkdir -p "$(dirname "$OVERLAY")"
    if [ "$PCMTYPE" = hw ]; then
        SLAVE="    type hw
    card $CARD
    device $DEV"
    else
        SLAVE="    type plug
    slave.pcm \"hw:$CARD,$DEV\""
    fi
    cat > "$OVERLAY" <<EOF
# Installed by bin/alsa-arm.sh (goal 5, docs/44-audio-alsa-backend.md).
# Redirects the alsa-lib name that audio.primary.waydroid.so opens.
#
# The bang in pcm.!pulse is required. /vendor/usr/share/alsa/alsa.conf line 662
# already defines pcm.pulse; without the bang alsa-lib merges the two blocks and
# collides on "type" instead of replacing it.
#
# type hw is bit-exact and exclusive and refuses anything the card will not do
# natively; type plug converts and so always opens. The HAL asks for
# S16_LE/48000/2ch with 1024-frame periods x 4.
pcm.!pulse {
$SLAVE
}

# The HAL itself never needs this: audio.primary.waydroid.so has no snd_ctl_*
# and no snd_mixer_* symbols at all, so Android does no mixer work here and the
# card's own levels have to be set host-side. It is defined anyway so that
# anything else in the image opening the ctl by that name does not fall through
# to the pulse plugin and block on a socket that is no longer there.
ctl.!pulse {
    type hw
    card $CARD
}
EOF
    say "wrote $OVERLAY"

    # 2. the mount.
    if [ "$HAD_MOUNT" = no ]; then
        printf '%s\n' "$MOUNT_LINE" >> "$NODES"
        say "appended the /dev/snd mount entry to config_nodes"
    else
        say "config_nodes already had a /dev/snd entry -- left alone"
    fi

    # 3. the permissions, as a udev rule so they survive the session restart
    #    that step 5 asks for. See the header for why setfacl does not.
    cat > "$UDEV" <<EOF
# Installed by bin/alsa-arm.sh (goal 5, docs/44-audio-alsa-backend.md).
# Hands card $CARD's nodes to Waydroid's Android, whose audioserver is uid
# $ANDROID_AUDIO_UID / gid 1005 and so matches neither root nor the host's
# audio group (gid 63). There is no idmap; Android's uids are the host's.
# Scoped to this one card deliberately -- /dev/snd as a whole stays 0660.
SUBSYSTEM=="sound", KERNEL=="controlC$CARD", MODE="0666"
SUBSYSTEM=="sound", KERNEL=="pcmC${CARD}D${DEV}p", MODE="0666"
SUBSYSTEM=="sound", KERNEL=="pcmC${CARD}D${DEV}c", MODE="0666"
SUBSYSTEM=="sound", KERNEL=="timer", MODE="0666"
EOF
    say "wrote $UDEV"
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=sound
    sleep 1
    for n in $(snd_nodes); do
        [ -e "$n" ] && say "$(stat -c '%n %A' "$n")"
    done

    # 4. hand the card over. Do this BEFORE the restart so the PCM is already
    #    free when the HAL's first open happens: it retries 100 x 20 ms and then
    #    gives up for the life of the container.
    pw wpctl set-profile "$DID" "$OFFPROF" && say "set PipeWire device $DID profile to off (was $OLDPROF)"
    sleep 2
    o=$(pcm_owner) && [ -n "${o:-}" ] && say "WARNING: hw:$CARD,$DEV is still held by $o"

    # 5. hand it over to a human. See the header: the two things just written
    #    are read only at SESSION start, and nothing reachable from here can
    #    start a session under cage.
    head_ "Now restart the Waydroid session -- nothing has switched yet"
    say "The overlay file and the mount entry are read by mount_rootfs() and by"
    say "LXC at SESSION start. Restarting waydroid-container.service does NOT"
    say "do it and will strand the machine at the greeter."
    say ""
    say "At the machine: log out of the Waydroid session and log back in,"
    say "choosing the \"waydroid-cage\" session at SDDM."
    say ""
    say "Then check it took, and measure:"
    say "  ssh HOST 'sudo sh -s' -- verify < bin/alsa-arm.sh"
    say "  ssh HOST 'sudo sh -s' -- play   < bin/audio-tone.sh"
    say "  ssh HOST 'sudo sh -s'           < bin/alsa-vs-pulse.sh"
}

verify() {
    # The only verb that can answer "did the arm actually take", and only after
    # a session restart. Each line is a thing that silently did not happen the
    # first time this was tried.
    head_ "Did the ALSA arm take?"
    SESS=$(waydroid status 2>/dev/null | sed -n 's/^Session:[[:space:]]*//p' | tr -d '[:space:]')
    kv "waydroid session" "${SESS:-unknown}"
    if [ "${SESS:-}" != "RUNNING" ]; then
        say "The session is not running, so nothing below can be true yet."
        say "Log in at the greeter choosing the \"waydroid-cage\" session."
        return
    fi
    kv "rootfs mounts" "$(findmnt -rn -o TARGET | grep -c /var/lib/waydroid/rootfs)"
    kv "asound.conf merged" "$([ -f /var/lib/waydroid/rootfs/system/etc/asound.conf ] \
        && echo "yes -- /system/etc/asound.conf" || echo "NO -- the overlay did not merge")"
    kv "/dev/snd in container" "$(waydroid shell -- sh -c 'ls /dev/snd 2>&1 | tr "\n" " "' 2>/dev/null |
        grep -v 'Permission denied' | tr -d '\r')"
    kv "pcm readable by Android" "$(waydroid shell -- sh -c \
        'ls -l /dev/snd/pcmC'"$CARD"'D'"$DEV"'p 2>&1' 2>/dev/null | tr -d '\r' | grep -v 'Permission denied')"
    kv "hw:$CARD,$DEV held by" "$(pcm_owner || echo "nobody (closed -- start audio)")"
    printf '\n'
}

off() {
    [ -f "$STATE" ] || die "no state file $STATE -- nothing to revert"
    . "$STATE"
    head_ "Reverting to the pulse arm"

    if [ "${had_overlay:-no}" = no ]; then
        rm -f "$OVERLAY" && say "removed $OVERLAY"
    else
        say "$OVERLAY predated this script -- left in place"
    fi

    if [ "${had_mount:-no}" = no ]; then
        sed -i '\|dev/snd|d' "$NODES" && say "removed the /dev/snd mount entry from config_nodes"
    else
        say "the /dev/snd mount entry predated this script -- left in place"
    fi

    if [ "${had_udev:-no}" = no ]; then
        rm -f "$UDEV" && say "removed $UDEV"
        udevadm control --reload-rules
        udevadm trigger --subsystem-match=sound
        sleep 1
        for n in ${snd_nodes:-}; do
            [ -e "$n" ] && say "$(stat -c '%n %A' "$n")"
        done
    else
        say "$UDEV predated this script -- left in place"
    fi
    # Belt and braces: an earlier version of this script granted an ACL, so
    # revoke one if it is still there rather than leaving a stale grant behind.
    for n in ${snd_nodes:-}; do
        [ -e "$n" ] && getfacl -pn "$n" 2>/dev/null | grep -q "^user:$ANDROID_AUDIO_UID:" &&
            setfacl -x "u:$ANDROID_AUDIO_UID" "$n" 2>/dev/null &&
            say "revoked a leftover ACL for uid $ANDROID_AUDIO_UID on $n"
    done

    if [ -n "${old_profile:-}" ]; then
        # Re-resolve rather than trusting the id `on` stored: PipeWire object
        # ids do not survive a restart of the daemon.
        CARD=${card:-$CARD}
        DID=$(card_device_id)
        DID=${DID:-${pw_device:-}}
        [ -n "${DID:-}" ] && pw wpctl set-profile "$DID" "$old_profile" &&
            say "restored PipeWire device $DID (card $CARD) to profile $old_profile"
    fi

    rm -f "$STATE"
    head_ "Now restart the Waydroid session"
    say "Same reason as \`on\`: the overlay and the mount entry are read at"
    say "SESSION start. Until you log out and back in, Android is still"
    say "pointed at the card -- and the card is back with PipeWire, so the"
    say "HAL's open will fail and Android will be silent."
    printf '\n'
}

case "$VERB" in
    status) status ;;
    caps)   caps   ;;
    verify) verify ;;
    on)     on     ;;
    off)    off    ;;
    *) echo "usage: $0 {status|caps|verify|on [--pcm plug|hw] [--card N] [--dev N]|off}" >&2
       exit 2 ;;
esac
