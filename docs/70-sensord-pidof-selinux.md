# The sensord that outlives its session: `pidof` cannot read /proc from `waydroid_t`

Observed 2026-10-16. A `waydroid-sensord` whose session has ended keeps polling `/dev/hwbinder` at
1 Hz for as long as nobody logs back in, and on this boot that one process wrote **81.9% of every
binder line in the kernel log**. Waydroid means to kill it and cannot: the `pidof` in
`container_manager.stop()` runs confined as `waydroid_t`, SELinux denies that domain `read` on
`/proc`, so `pidof` enumerates nothing, matches nothing, and prints nothing — and the two
`check=False` / `if pid:` guards around it turn a hard failure into a silent no-op.

[69-wifid-binder-ping-spam.md](69-wifid-binder-ping-spam.md) measured this as "5.1%, which has the
same bug on `/dev/hwbinder`". The share was right for the moment it was taken and the diagnosis was
wrong: this is not the same bug. `waydroid-wifid` was a boot service polling for a session that had
never started, fixed by waiting for one. This is a daemon that *had* a session, lost it, and was
supposed to be killed. Now that wifid's startup wait is gone, this is the largest remaining source.

[03-binder-ping-spam.md](03-binder-ping-spam.md) decodes the two kernel lines and docs/69 tabulates
them; neither is repeated here.

## Symptom

```
binder: 4348:4348 cannot find target node
binder: 4348:4348 transaction call to 0:0 failed 95/29189/-22, code 1599098439 size 0-0 line 3253
```

Two lines per second from a single pid, starting when a session stops and ending only when
somebody logs in again. Measured on the 2026-10-16 boot, with `waydroid-ext-wifid` 1.1.1 already
installed so that wifid's startup wait is no longer in the way:

| Source | pid | Binder lines | Share |
|---|---|---|---|
| **`waydroid-sensord`, session ended 16:32** | 4348 | **20,031** | **81.9%** |
| `waydroid-wifid`, the docs/69 case | 1066 | 2,926 | 12.0% |
| short-lived, not identified here | 3792 | 1,018 | 4.2% |
| `waydroid-wifid` test instance | 30895 | 442 | 1.8% |
| | | **24,459** | |

The arithmetic closes: 20,031 lines at two per ping is 10,015 pings, and the session stopped at
16:32 — 2.8 hours before the count was taken at 19:2x. It is a 1 Hz poll with no stop condition,
not a burst.

The leak is one process wide, not cumulative. A new session's daemon finds the pid file, SIGTERMs
whatever holds it and takes the lock (`sensors/service.cpp`, `app_take_lock`), so logging back in
does clean up. What is unbounded is the *gap*: a tablet left at the greeter overnight spends the
whole night with one daemon pinging an empty binder.

## What was supposed to happen

`container_manager.stop()` already intends exactly the right thing:

```python
# Sensors
if which("waydroid-sensord"):
    command = ["pidof", "waydroid-sensord"]
    pid = tools.helpers.run.user(args, command, check=False, output_return=True).strip()
    if pid:
        command = ["kill", "-9", pid]
        tools.helpers.run.user(args, command, check=False)
```

So "dead when there is no session" is upstream's design, not something to be argued for. Nothing
needs a new policy about sensord's lifetime; the existing one simply does not execute.

## What actually happens

`/var/lib/waydroid/waydroid.log` is the whole story, because `run_core.pipe_read()` logs every
command's output at debug and debug goes to that file regardless of console level:

```
16:32:04  % /usr/lib/waydroid/data/scripts/waydroid-net.sh stop
16:32:04  vnic is waydroid0
16:32:04  % pidof waydroid-sensord
16:32:04  % umount /var/lib/waydroid/rootfs/vendor/waydroid.prop
```

The neighbouring commands are the control: `waydroid-net.sh` logs `vnic is waydroid0`, `lxc-info`
logs `RUNNING` and `STOPPED`. `pidof` logs nothing at all. Across the four session stops in that
log there are four bare `% pidof waydroid-sensord` lines, and the string `% kill` appears **nowhere
in the file**. The kill is not failing — it is never attempted.

The audit log says why:

```
avc:  denied  { read } for  pid=374500 comm="pidof" name="/" dev="proc" ino=1
      scontext=system_u:system_r:waydroid_t:s0
      tcontext=system_u:object_r:proc_t:s0 tclass=dir permissive=0
```

`name="/" dev="proc" ino=1` is the root of `/proc` itself. procps' `openproc()` cannot read the
directory, so it enumerates zero processes, `pidof` matches nothing and exits 1. `check=False`
discards the exit code, `.strip()` yields `""`, and `if pid:` skips the kill. Three independent
layers of silence over one denial.

## Why this looked like a phantom

`pidof waydroid-sensord` works perfectly when you check it by hand. An ssh login is `unconfined_t`,
which may read `/proc`; the service is `waydroid_t`, which may not. The bug is therefore invisible
to every interactive reproduction of it, and visible only from inside the service.

`sensors/service.cpp` already documents this exact trap, for the lock file rather than for `/proc`:

> Running the same binary by hand under sudo works, because an ssh login gives `unconfined_t` --
> which makes this fail exactly one way round and look like a phantom.

Same trap, different syscall, two years of the same lesson. What follows was ruled out before the
audit log was consulted, and is recorded so the next person can skip it:

| Hypothesis | Why not |
|---|---|
| `comm` truncated to 15 chars (`waydroid-sensor` vs the 16-char name) | Real, but not the cause: `pidof` matches `argv[0]` out of `/proc/pid/cmdline` and finds the process fine. It does mean the match can *only* come from cmdline. |
| The exe was replaced under it by `rpm-ostree apply-live`, so the name no longer resolves | Tested directly: a copy of `sleep` whose binary is deleted mid-run is still found by `pidof`. And `/proc/4348/exe` reads intact. |
| The non-blocking `readline()` race in `run_core.foreground_pipe()` | Replicated byte-for-byte against the live process, 200 iterations: the pid came back 200/200. The read loop is sound. |
| `run.user()` drops privileges, so `kill` hits EPERM | `run.user()` does no privilege drop at all — it is the plain-exec path, and the service is root. (It is also moot: the kill never ran.) |
| The service sees a different `/proc` (mount or pid namespace) | All ten namespace inodes of pid 1126 are identical to the shell's; the unit sets no sandboxing. |
| `which()` failed, or Popen raised | The `% pidof` line is logged *before* the run, and the umounts that follow it prove nothing propagated out of the `try`. |

One trap worth naming: `sesearch` is not installed on this host, so every `sesearch -A -s waydroid_t
...` query returns empty and reads exactly like proof that no rule exists. The AVC record is
positive evidence; an empty policy query is not evidence of anything.

## The fix: let the daemon decide, rather than wait to be killed

`waydroid-ext-sensord` now treats a dead service manager as a question instead of a verdict. On
death it restores the backlight as before, then asks `id.waydro.Container`'s `GetSession` whether a
session is still running. If one is, nothing changes — the existing "service manager has reappeared"
branch re-registers both names, so a framework restart under a live session still works. If there
is no session, the daemon exits, and `container_manager.py` starts a fresh one with the next
session, which is what it does on every session start anyway.

Three details carry the design:

- **It asks repeatedly, not once.** `stop()` clears its session as the *last* statement of its
  `try`, long after lxc has already taken the service manager down. Measured on this host: the
  service manager died at 16:31:58 and the session was still being reported until 16:32:04, a 6 s
  window. A single check at death time would always see a live session and stay up for ever. The
  watch polls every 2 s and gives up after 60 s, ten times the measured gap.
- **It fails toward staying up.** No bus, no reply, a malformed reply — all return "a session is
  running". The two mistakes are not symmetric: a daemon that wrongly stays up writes log noise,
  which is exactly today's behaviour, while one that wrongly exits takes the sensors and the
  backlight with it until the next login.
- **The backlight restore happens before the decision.** docs/37's black screen — panel at 0 behind
  the SDDM greeter, on a machine whose only other input is ssh — must not become dependent on how
  long this process lives.

`GetSession` costs no binder traffic. It does add two `DT_NEEDED` entries, `libgio-2.0.so.0` and
`libgobject-2.0.so.0`: the daemon was already *linked* against both, but `--as-needed` had been
dropping them because nothing in it used a symbol from either. Both ship in `glib2`, which this
package already `Requires` and which the host already has, so nothing new is pulled in — checked
against the installed 1.0.4 binary rather than assumed, after an earlier draft of this file claimed
the set was unchanged and was wrong. `objdump` is not installed on bigtab01, which is part of why
that was easy to believe; the comparison has to be made off-host.

## Why not just fix the policy

Allowing `waydroid_t` to read `/proc` would make upstream's kill work, and the denial is a genuine
bug worth reporting either way. It was not the fix chosen here:

- It buys exactly one kill. That `pidof` is the only thing in `/usr/lib/waydroid/tools` that
  *enumerates* `/proc`. The tools do read `/proc` elsewhere — `cpuinfo`, `filesystems`, `mounts`,
  `device-tree` — but all at known paths, which need `search` on the directory and not `read`, and
  which is why every one of those keeps working under this denial while the kill does not.
- It risks trading binder spam for audit spam. `pidof` reads every process's `/proc` entries, so a
  grant on the directory invites a second round of denials against every other domain on the host.
- The mechanism it restores is independently fragile. The match can only come from `cmdline`,
  because `comm` is truncated one character short of `waydroid-sensord`; and if `pidof` ever
  returned two pids, `kill -9 "4348 4349"` is a single argv element that util-linux `kill` rejects.

Deciding inside our own daemon needs no policy change and holds whether or not the kill ever lands.

## Residue: a zombie per session stop, and why that is acceptable

The exiting daemon becomes a zombie rather than disappearing, because `do_start` discards the
`Popen` that `run.user(..., output="background")` returns and so never reaps the child. Seen on
both paths: a SIGTERM to the old pid 4348 stopped its binder output dead (delta 0 over the
following 8 s) and left it in state `Z` with the backlight restored to 937/937, and the fixed
daemon's own exit at 20:18:20 ended the same way.

A zombie holds a pid table entry and nothing else — no binder traffic, no CPU, no `flock` — and it
is reaped when `waydroid-container.service` restarts. One pid slot per session stop, against two
kernel log lines per second, is a good trade.

It also points at the proper upstream fix, which is the same root cause as the `pidof` failure:
`do_start` spawns the daemon and throws away the handle, so `stop()` has to go looking for it again
by name. Keeping the `Popen` and calling `.kill()` / `.wait()` on it needs no `pidof`, no `/proc`
enumeration, no SELinux permission, and leaves no zombie.

## Verification

Measured on bigtab01, 2026-10-16, with the fixed binary installed to `/usr/local/bin` so that
`container_manager.py`'s `which()` picks it up and spawns it. That detail is the test: the daemon
has to actually be `waydroid_t` for "may it call `GetSession`?" to mean anything, and running it by
hand would have given it `unconfined_t` — the same trap as everything else on this page.

**Session start, 20:12:19.** Spawned from `/var/usrlocal/bin/waydroid-sensord`, label
`system_u:system_r:waydroid_t:s0`, its IIO devices bound, backlight read at 937/937,
`Waydroid Sensors HAL service ready.` and `Added "android.hardware.light@2.0::ILight/default"`.
Startup is untouched by the fix and behaved accordingly.

**Session stop, 20:18.** From the daemon's own log and `waydroid.log` side by side:

| Time | Event |
|---|---|
| 20:18:14 | `Service manager has died` |
| 20:18:14 | `Restoring backlight to 937 (Android went away)` |
| 20:18:19 | `stop()` logs `Stopping container` |
| 20:18:19 | `% pidof waydroid-sensord` — **still empty; the denial is untouched** |
| 20:18:20 | `The session this daemon was started for is gone; exiting ...` |

Six seconds from death to exit, and the exit happened *because the daemon asked* — the `pidof` line
one second earlier is as empty as it was at every previous stop. Nothing killed it. Those 6 s are
exactly the window the repeated check exists for: a single check at 20:18:14 would have seen a live
session and stayed up for ever.

| Measure | Before (pid 4348) | After (pid 58753) |
|---|---|---|
| Binder lines written | **20,521** | **5** |
| End state | `Sl`, still polling 2.9 h later | `Z` within a second of deciding |
| Backlight | 937/937 | 937/937 |
| AVC denial on the `GetSession` call | — | none |

Five lines, all of them inside the 6 s window, against an unbounded two per second.

No denial was logged for the D-Bus call, which settles the one thing no policy query could answer
here: `waydroid_t` may talk to `id.waydro.Container`. Had it been denied, the predicate's
fail-toward-"a session is running" would have left the daemon up — no regression, but no fix
either. That is precisely why this had to be run instead of reasoned about.

What is left on this host is `waydroid-wifid`'s own post-logout poll: pid 52592 wrote 2,600 lines
between the 20:18 logout and 20:41 and was still going. That is docs/69's open 19.5%, untouched by
any of this.

## Still open

The `waydroid-wifid` post-logout poll — 19.5% in docs/69's accounting — is unchanged. It is the
same libgbinder reanimate timer, but wifid is a boot service that must survive a logout, so it
cannot simply exit; see docs/69's "Still open".
