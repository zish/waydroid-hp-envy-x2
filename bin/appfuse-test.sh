#!/bin/sh
# appfuse-test.sh -- re-run AppFuse Probe and report what happened (goal 9, docs/55).
#
#     ssh 10.42.0.137 'sudo sh -s' < bin/appfuse-test.sh
#
# Drives the whole loop in one command: force-stop the probe so it runs fresh,
# launch it, wait for the report, print it, and then print the two places the
# *reason* for a failure lives -- vold's own log line and the host's AVC denials.
# Those two are the point. The app can only ever say "Failed to mount"; whether
# that was an unparseable mount context (EINVAL, nothing in ausearch) or a policy
# denial (EPERM, an AVC) is the difference between the two candidate fixes, and
# the app cannot tell them apart.
#
# Needs root: `waydroid shell` has no unprivileged form, the report lands under
# <data>/media/0/Android/data owned by the app's uid, and ausearch is root-only.
#
# Install the probe first with appfuse-probe/build.sh --install.
#
# ONE TRAP, AND IT COST A ROUND OF DEBUGGING: this script is delivered to
# `sh -s` on STDIN, so any command in it that reads stdin consumes the rest of
# the script. `ausearch` does exactly that. The symptom is not an error -- the
# script just stops, mid-run, and exits 0, which reads as "finished" rather than
# "truncated". Every command here that might touch stdin gets `</dev/null`.

set -u

PKG=lan.syshlt.appfuseprobe
REPORT_REL="Android/data/$PKG/files/reports/appfuse-probe.txt"

ok()    { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
no()    { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
na()    { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# `waydroid shell` always exits non-zero with a cosmetic permission-denied line;
# strip it rather than trusting the status. Trap inherited from the other scripts.
ash() { waydroid shell -- sh -c "$1" </dev/null 2>&1 | grep -v 'Permission denied: 1'; }

# There is only ever one session user, and the daemons all autodetect it this way.
DATA=$(ls -d /home/*/.local/share/waydroid/data 2>/dev/null | head -1)
REPORT="$DATA/media/0/$REPORT_REL"

head_ "1. Preconditions"
if [ -z "$DATA" ]; then
    no "no waydroid data directory found -- is the container initialised?"
    exit 1
fi
ok "data directory: $DATA"
if ash "pm path $PKG" | grep -q package; then
    ok "$PKG is installed"
else
    no "$PKG is not installed -- run appfuse-probe/build.sh --install"
    exit 1
fi
if [ -e /dev/fuse ]; then ok "/dev/fuse exists on the host"; else no "/dev/fuse missing on the host"; fi
if semodule -l 2>/dev/null | grep -q '^waydroid_appfuse'; then
    ok "SELinux module waydroid_appfuse is loaded"
else
    na "SELinux module waydroid_appfuse is NOT loaded (expected, before the fix)"
fi

head_ "2. Running the probe"
# Clear the old report so a stale one cannot be mistaken for a fresh pass, and
# mark the log so only this run's lines are read back.
rm -f "$REPORT"
ash "log -p i -t APPFUSE '=== appfuse-test.sh run starting ==='" >/dev/null 2>&1
ash "am force-stop $PKG" >/dev/null 2>&1
ash "am start -n $PKG/.MainActivity" >/dev/null 2>&1
n=0
while [ $n -lt 40 ]; do
    [ -s "$REPORT" ] && break
    sleep 1
    n=$((n+1))
done
PROBE_OK=0
if [ -s "$REPORT" ]; then
    ok "report written after ${n}s"
    grep -q '^RESULT: AppFuse WORKS' "$REPORT" && PROBE_OK=1
else
    no "no report after ${n}s -- the probe did not finish; logcat below"
fi

head_ "3. The probe's report"
if [ -s "$REPORT" ]; then
    sed 's/^/    /' "$REPORT"
else
    na "nothing to show"
fi

head_ "4. What vold said"
# vold logs the mount failure with its errno. This is the authoritative line:
# "Invalid argument" is EINVAL (the mount context could not be parsed at all),
# "Permission denied" is EPERM (it parsed, and policy refused it).
VOLD=$(ash "logcat -d -t 400 -s vold" 2>/dev/null | grep -i 'appfuse\|Failed to mount' | tail -10)
if [ -n "$VOLD" ]; then
    echo "$VOLD" | sed 's/^/    /'
else
    na "no appfuse lines from vold in the last 400 log lines"
fi

head_ "5. What the kernel logged"
# THIS IS THE SECTION THAT MATTERS, and the reason it reads dmesg first.
#
# A context that cannot be PARSED never becomes an AVC, so ausearch is completely
# clean for the original fault and the obvious first move gives the wrong answer.
# The kernel says it in dmesg instead:
#
#   SELinux: security_context_str_to_sid (u:object_r:app_fuse_file:s0)
#            failed with errno=-22
#
# -22 is EINVAL. If that line is present and recent, the policy module is missing
# or did not take. If it is absent and the mount still fails, the context parsed
# and something else is wrong -- look for an AVC below.
UP=$(cut -d. -f1 /proc/uptime)
PARSE=$(dmesg </dev/null 2>/dev/null | grep 'security_context_str_to_sid.*app_fuse' | tail -3)
if [ -n "$PARSE" ]; then
    LAST=$(echo "$PARSE" | tail -1 | sed 's/^\[ *\([0-9]*\).*/\1/')
    AGE=$((UP - LAST))
    echo "$PARSE" | sed 's/^/    /'
    if [ "$PROBE_OK" = 1 ]; then
        ok "the probe passed, so these are history -- most recent ${AGE}s ago"
    elif [ "$AGE" -lt 120 ]; then
        no "a context parse failure ${AGE}s ago -- the policy module is missing or did not take"
    else
        no "parse failures present, newest ${AGE}s ago -- older than this run, so look further"
    fi
else
    ok "no SELinux context parse failures in dmesg at all"
fi

# ausearch second, and bounded: on a host with a large audit log it can take
# minutes, which is long enough to look like this script hanging.
AVC=$(timeout 20 ausearch -m AVC,USER_AVC -ts recent </dev/null 2>/dev/null | grep -i 'app_fuse' | tail -10 || true)
if [ -n "$AVC" ]; then
    echo "$AVC" | sed 's/^/    /'
    if [ "$PROBE_OK" = 1 ]; then
        na "AVC denials present but the probe passed -- not blocking"
    else
        no "AVC denials on the appfuse types -- a rule is missing from waydroid_appfuse.cil"
    fi
else
    na "no app_fuse AVC denials in the last 10 minutes (ausearch capped at 20s)"
fi

head_ "6. Verdict"
if [ "$PROBE_OK" = 1 ]; then
    ok "AppFuse works in this container"
    exit 0
fi
no "AppFuse is not working -- sections 4 and 5 say which fix to reach for"
exit 1
