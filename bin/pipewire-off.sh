#!/bin/sh
# pipewire-off.sh -- leave the host with ZERO PipeWire processes while keeping
# Waydroid's audio, and put it all back. Goal 5, docs/44-audio-alsa-backend.md.
#
#     ssh 10.42.0.137 'sudo sh -s' -- status  < bin/pipewire-off.sh
#     ssh 10.42.0.137 'sudo sh -s' -- off     < bin/pipewire-off.sh
#     ssh 10.42.0.137 'sudo sh -s' -- on      < bin/pipewire-off.sh
#
# This needs NO session restart and does NOT risk the SDDM greeter. Both of
# those are consequences of one design choice, explained below.
#
# WHY THIS IS SAFE TO DO AT ALL
#
# Waydroid's audio no longer goes anywhere near PipeWire. bin/alsa-arm.sh
# redirects the alsa-lib name the HAL opens ("pulse") straight at hw:1,0, and
# the HAL maps only libasound.so -- no libpulse, no pulse plugin, and the sole
# sound fd is /dev/snd/pcmC1D0p. So the host's graph is carrying nothing.
#
# MEASURED on this host, 2026-10-06: `wpctl status` has an EMPTY Audio section
# (card 1's profile is Off, because Android owns it), and of the things that
# link libpipewire-0.3.so.0 -- firefox, waybar, xdg-desktop-portal,
# xdg-desktop-portal-wlr, pavucontrol -- NONE are running. This is a cage kiosk,
# not a Sway desktop. The only live PipeWire client is waydroid-pwd, our own
# package, whose entire job is to expose the host graph to Android.
#
# WHY UNINSTALLING IS THE WRONG LEVER
#
# `rpm-ostree override remove pipewire-libs` would also take firefox, waybar,
# both xdg-desktop-portals and uresourced, because they link
# libpipewire-0.3.so.0. It is a base-image package, so it needs an override and
# a reboot. Masking the units gets the stated goal -- nothing running -- while
# leaving every library in place for those programs to keep linking against.
#
# THE TRAP, AND WHY ONE SOCKET STAYS
#
# Waydroid appends a mount entry for the host's PulseAudio socket
# UNCONDITIONALLY. /usr/lib/waydroid/tools/helpers/lxc.py:204
#
#     pulse_host_socket = os.path.join(session["pulse_runtime_path"], "native")
#     make_entry(pulse_host_socket, pulse_container_socket[1:])
#
# and generate_session_lxc_config's make_entry skips its existence check
# whenever `dist` is given, then calls add_node_entry(..., check=False), which
# appends the entry whether the source exists or not. The default options are
# "rbind,create=file 0 0" -- note the absence of `optional`, which
# generate_nodes_lxc_config's sibling make_entry does have. The live result:
#
#     lxc.mount.entry = /run/user/1000/pulse/native run/xdg/pulse/native none rbind,create=file 0 0
#
# A bind mount needs its SOURCE to exist. Kill the thing that creates
# /run/user/1000/pulse/native and the next session start fails on a fatal mount
# entry -- and under cage there is no autologin, so that means someone at the
# keyboard. That is the upstream bug docs/44 recorded as blocking PipeWire's
# removal.
#
# It does not have to block it. pipewire-pulse.socket is a PURE systemd socket
# unit -- `ListenStream=%t/pulse/native`, no Requires= on pipewire.service -- so
# SYSTEMD creates and binds that socket, not PipeWire. pipewire-pulse.service is
# socket-activated and, with nothing connecting to it any more, already sits
# `inactive dead` while the socket sits `active listening`.
#
# So: mask everything that RUNS, and leave pipewire-pulse.socket alone. The
# mount source keeps existing at every login, created by systemd, with zero
# PipeWire processes behind it. No shim file, no tmpfiles ordering race against
# an SDDM-launched session script, nothing to get wrong at the next login.
#
# If something ever does connect to that socket, systemd tries to start the
# masked service and the connection is refused. Harmless, and nothing in the
# container connects: the HAL resolves "pulse" through asound.conf to hw:1,0.
#
# WHAT IS LOST
#
#   - Bluetooth audio on the host. WirePlumber's bluez5 monitor is what claims
#     BlueZ's media endpoint. Nothing is paired today, so nothing breaks now,
#     but A2DP will not work until something replaces it (bluez-alsa).
#   - Screen sharing via xdg-desktop-portal-wlr, which needs PipeWire for
#     screencast. Not running here.
#   - waybar's wireplumber/pulseaudio volume module. Not running here.
#   - waydroid-pwd, our PipeWire-graph-to-Android bridge, becomes pointless and
#     is masked with the rest.
#   - Host application audio generally. There is none: card 1 belongs to Android.
#
# `on` reverses every bit of it, immediately, with no restart.

set -u

WDUSER=$(waydroid status 2>/dev/null | sed -n 's/^Session user:[[:space:]]*\([^(]*\)(.*/\1/p' | tr -d '[:space:]')
[ -n "$WDUSER" ] || WDUSER=jmelanso
WDUID=$(id -u "$WDUSER" 2>/dev/null) || WDUID=1000
RUNTIME=/run/user/$WDUID
PULSE_SOCK=$RUNTIME/pulse/native

# Everything that RUNS. pipewire-pulse.socket is deliberately NOT in this list.
UNITS="pipewire.service pipewire.socket pipewire-pulse.service wireplumber.service filter-chain.service waydroid-pwd.service"
KEEP="pipewire-pulse.socket"

VERB=${1:-status}

head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
kv()    { printf '  %-34s %s\n' "$1" "$2"; }
say()   { printf '  %s\n' "$1"; }
warn()  { printf '  \033[33m%s\033[0m\n' "$1"; }
die()   { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

uctl() { runuser -u "$WDUSER" -- env "XDG_RUNTIME_DIR=$RUNTIME" systemctl --user "$@" 2>/dev/null; }

procs() { pgrep -x -u "$WDUSER" 'pipewire|wireplumber' 2>/dev/null | wc -l | tr -d ' '; }

# is-enabled/is-active exit non-zero for masked or inactive units and some
# print nothing, so take the first line and default it rather than chaining
# `|| echo`, which appends a second line to the field.
ustate() {
    E=$(uctl is-enabled "$1" | head -1 | tr -d '[:space:]')
    A=$(uctl is-active  "$1" | head -1 | tr -d '[:space:]')
    printf '%s / %s' "${E:-unknown}" "${A:-inactive}"
}

# owner_pid in /proc/asound is a THREAD id named for its job, so it has to be
# resolved through Tgid before it names a program. Same trap as alsa-vs-pulse.sh.
hw_owner() {
    T=$(sed -n 's/^owner_pid *: *//p' /proc/asound/card1/pcm0p/sub0/status 2>/dev/null)
    [ -n "$T" ] || { printf 'nobody\n'; return; }
    P=$(grep -a '^Tgid:' "/proc/$T/status" 2>/dev/null | awk '{print $2}')
    [ -n "$P" ] || { printf 'pid %s (gone)\n' "$T"; return; }
    tr '\0' ' ' < "/proc/$P/cmdline" 2>/dev/null | awk '{print $1}'
}

report() {
    head_ "PipeWire processes"
    N=$(procs)
    kv "running (pipewire + wireplumber)" "$N"
    [ "$N" -gt 0 ] && ps -u "$WDUSER" -o pid=,args= 2>/dev/null \
        | grep -E '/usr/bin/(pipewire|wireplumber)' | sed 's/^/        /'

    head_ "Units"
    for u in $UNITS; do kv "$u" "$(ustate "$u")"; done
    for u in $KEEP;  do kv "$u  <- KEPT" "$(ustate "$u")"; done

    head_ "The thing that must not break"
    if [ -e "$PULSE_SOCK" ]; then
        kv "$PULSE_SOCK" "EXISTS ($(stat -c %A "$PULSE_SOCK" 2>/dev/null))"
        say "Waydroid's unconditional LXC mount entry has a source, so a session"
        say "start will not fail on it. See the header."
    else
        warn "$PULSE_SOCK IS MISSING"
        warn "The next waydroid session start will FAIL on a fatal mount entry"
        warn "and leave the machine at the SDDM greeter. Run 'on' before logging out."
    fi

    head_ "Waydroid audio"
    kv "session" "$(waydroid status 2>/dev/null | sed -n 's/^Session:[[:space:]]*//p')"
    B=$(sed -n 's/^buffer_size: *//p' /proc/asound/card1/pcm0p/sub0/hw_params 2>/dev/null)
    kv "card 1 playback" "${B:+$B frames}${B:-closed (nothing playing)}"
    kv "card 1 held by" "$(hw_owner)"
    echo
}

case "$VERB" in
status)
    report
    ;;

off)
    head_ "Masking everything that runs"
    for u in $UNITS; do
        uctl mask --now "$u" >/dev/null 2>&1
        kv "$u" "masked, stopped"
    done
    say "left alone: $KEEP -- it is what creates $PULSE_SOCK"

    # Give systemd a moment to reap, then check the two things that matter.
    N=$(procs)
    head_ "Did it work, and is the session still startable?"
    kv "PipeWire processes now" "$N"

    if [ ! -e "$PULSE_SOCK" ]; then
        warn "$PULSE_SOCK vanished -- that would strand the next login at the greeter."
        warn "ROLLING BACK rather than leaving the machine in that state."
        for u in $UNITS; do uctl unmask "$u" >/dev/null 2>&1; done
        uctl start pipewire.socket >/dev/null 2>&1
        uctl start pipewire.service >/dev/null 2>&1
        uctl start wireplumber.service >/dev/null 2>&1
        die "rolled back. Investigate before retrying: the socket was expected to
  survive because systemd, not PipeWire, binds it."
    fi
    kv "$PULSE_SOCK" "still exists -- session start is safe"

    if [ "$N" -ne 0 ]; then
        warn "$N PipeWire process(es) still alive; something restarted them."
        ps -u "$WDUSER" -o pid=,args= 2>/dev/null | grep -E '/usr/bin/(pipewire|wireplumber)' | sed 's/^/        /'
    fi
    report
    ;;

on)
    head_ "Unmasking and starting"
    for u in $UNITS; do
        uctl unmask "$u" >/dev/null 2>&1
        kv "$u" "unmasked"
    done
    uctl start pipewire.socket >/dev/null 2>&1
    uctl start pipewire.service >/dev/null 2>&1
    uctl start wireplumber.service >/dev/null 2>&1
    uctl start filter-chain.service >/dev/null 2>&1
    uctl start waydroid-pwd.service >/dev/null 2>&1
    say "started pipewire, wireplumber, filter-chain and waydroid-pwd"
    say "NOTE: PipeWire will not take card 1 back while Android holds it. Use"
    say "      bin/alsa-arm.sh off (and a session restart) for that."
    report
    ;;

*)
    printf 'usage: %s {status|off|on}\n' "$0" >&2; exit 2 ;;
esac
