#!/bin/sh
# bt-tile.sh -- put the Bluetooth app's tile in the pull-down shade, in place of
# the stock Bluetooth tile (docs/50-bluetooth.md).
#
#     ssh 10.42.0.137 'sudo sh -s'              < bin/bt-tile.sh   # status
#     ssh 10.42.0.137 'sudo sh -s -- --install' < bin/bt-tile.sh
#     ssh 10.42.0.137 'sudo sh -s -- --remove'  < bin/bt-tile.sh
#
# WHY THIS IS A SETTING AND NOT AN OVERLAY
#
# SystemUI reads the shade's tile list from the secure setting sysui_qs_tiles,
# which is an ordinary writable string. Changing it takes effect without
# restarting anything -- no overlay file, no waydroid-container restart, and so
# no drop to the SDDM greeter, which is the usual price of changing anything
# inside the image.
#
# It lives in Android's settings database, so it survives reboots and app
# reinstalls by itself. It does NOT survive wiping /data, and it is not managed
# by waydroid-overlay-sync, so this is the only record of the change.
#
# WHAT IT DOES NOT DO
#
# Removing `bt` from the list hides the stock tile from the shade; it stays
# available in the edit-tiles tray underneath, because that tray is populated
# from a SystemUI resource. Making it genuinely unavailable needs a resource
# overlay, which is a great deal of machinery for a tile nobody will go looking
# for. The stock tile is inert here anyway -- there is no com.android.bluetooth
# in this image for it to drive.

set -u

PKG=lan.syshlt.bluetooth
TILE="custom($PKG/$PKG.BtTileService)"
STOCK=bt
BACKUP=/var/lib/waydroid-btd/qs-tiles.orig
ACTION=${1:---status}

# Two readers, because `waydroid shell` decorates its output: a cosmetic
# "Permission denied: 1" after every command, CRs, and an occasional banner.
# ash1 is for single-value reads like `settings get`; ash for multi-line ones
# like `pm list packages`, where taking only the first line silently answers
# the wrong question.
ash() {
    waydroid shell -- sh -c "$1" 2>/dev/null \
        | grep -v 'Permission denied: 1' | tr -d '\r'
}
ash1() { ash "$1" | head -1; }

# Comma lists are handled with awk rather than sed: the tile spec contains
# parentheses, slashes and dots, all of which are sed metacharacters or
# delimiters waiting to go wrong.
list_has() {
    printf '%s' "$1" | awk -v want="$2" -F, \
        '{for (i=1;i<=NF;i++) if ($i==want) {print "yes"; exit}}'
}
list_replace() {
    printf '%s' "$1" | awk -v from="$2" -v to="$3" -F, \
        '{out=""; for (i=1;i<=NF;i++) {v=$i; if (v==from) v=to;
          out=(out==""?v:out","v)} print out}'
}
list_drop() {
    printf '%s' "$1" | awk -v drop="$2" -F, \
        '{out=""; for (i=1;i<=NF;i++) {if ($i==drop) continue;
          out=(out==""?$i:out","$i)} print out}'
}

CURRENT=$(ash1 "settings get secure sysui_qs_tiles")
case "$CURRENT" in
""|null)
    echo "sysui_qs_tiles is unset -- is the container running?" >&2
    exit 1 ;;
esac

case "$ACTION" in
--status)
    echo "current: $CURRENT"
    echo
    [ -n "$(list_has "$CURRENT" "$TILE")" ] \
        && echo "  our tile:   present" || echo "  our tile:   absent"
    [ -n "$(list_has "$CURRENT" "$STOCK")" ] \
        && echo "  stock 'bt': present (inert -- nothing drives it)" \
        || echo "  stock 'bt': absent"
    if [ -f "$BACKUP" ]; then
        echo "  backup:     $BACKUP"
        echo "              $(cat "$BACKUP")"
    else
        echo "  backup:     none taken yet"
    fi
    ;;

--install)
    if ! ash "pm list packages" | grep -q "$PKG"; then
        echo "$PKG is not installed -- bt-app/build.sh --install first" >&2
        exit 1
    fi
    if [ -n "$(list_has "$CURRENT" "$TILE")" ]; then
        echo "already installed; nothing to do"
        exit 0
    fi
    # Taken once and never overwritten, so a second --install after a manual
    # edit cannot destroy the original.
    if [ ! -f "$BACKUP" ]; then
        mkdir -p "$(dirname "$BACKUP")"
        printf '%s\n' "$CURRENT" > "$BACKUP"
        echo "saved the original list to $BACKUP"
    fi
    if [ -n "$(list_has "$CURRENT" "$STOCK")" ]; then
        NEW=$(list_replace "$CURRENT" "$STOCK" "$TILE")
        echo "replacing the stock tile in place"
    else
        NEW="$CURRENT,$TILE"
        echo "stock tile not in the list; appending ours"
    fi
    ash "settings put secure sysui_qs_tiles '$NEW'" >/dev/null
    AFTER=$(ash1 "settings get secure sysui_qs_tiles")
    echo "now:     $AFTER"
    [ "$AFTER" = "$NEW" ] && echo "ok" || { echo "write did not stick" >&2; exit 1; }
    ;;

--remove)
    if [ -f "$BACKUP" ]; then
        NEW=$(cat "$BACKUP")
        echo "restoring the saved original"
    else
        NEW=$(list_replace "$CURRENT" "$TILE" "$STOCK")
        [ "$NEW" = "$CURRENT" ] && NEW=$(list_drop "$CURRENT" "$TILE")
        echo "no backup; putting the stock tile back where ours was"
    fi
    ash "settings put secure sysui_qs_tiles '$NEW'" >/dev/null
    echo "now:     $(ash1 "settings get secure sysui_qs_tiles")"
    ;;

*)
    echo "usage: bt-tile.sh [--status|--install|--remove]" >&2
    exit 2 ;;
esac
