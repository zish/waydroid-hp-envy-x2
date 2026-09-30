# Upstream: `waydroid container stop` diverges from every other stop path

Written 2026-09-07, out of the cage work in [25](25-waydroid-in-cage.md). That note explains the
container service's anatomy; this one is about the one command that talks past it, what upstream has
and has not already done about it, and the patches staged in
[artifacts/upstream/](../artifacts/upstream).

## The divergence

Every path that stops Waydroid goes through the container service's D-Bus `Stop` — `session_manager`'s
`Stop` method, its `handle_disconnect`, its signal handlers, and `upgrader.upgrade()`. One does not:

```python
# tools/__init__.py:78
elif args.subaction == "stop":
    actions.container_manager.stop(args)
```

`waydroid container stop` runs that in the CLI's own process, against a fresh `args` namespace with no
`session` attribute. Three things only the service can do are therefore skipped:

1. **`args.session` is never cleared** (`container_manager.py:265`) — the service goes on tracking a
   session whose container is gone, and the next `do_start()` raises `Already tracking a session`.
2. **The hardware manager is never stopped** — `services.hardware_manager.stop()` sets a module-global
   `stopping` and quits `args.hardwareLoop`, both of which live in the *service's* process. In the CLI
   the global is a fresh one and the attribute does not exist; the `AttributeError` is swallowed and
   logged as `Hardware service is not even started`. The service keeps re-registering
   `waydroidhardware` for a dead container.
3. **Two processes race the same teardown** — nothing orders the CLI's `stop()` against the service's,
   and both run `umount_rootfs`, `waydroid-net.sh stop` and `pidof waydroid-sensord; kill -9`. The
   service's main loop is single-threaded, so going through it serialises them for free.

The visible result is `Session: RUNNING / Container: STOPPED` — **the same signature an in-Android
power-off produces**, from a completely unrelated cause. Recovery is `waydroid session stop`.

## What upstream already has

Surveyed 2026-09-07 against `waydroid/waydroid`, `main` at **`5a51271131bf`** (2026-09-06) — the
base the staged patches apply to, recorded because a patch in a repository goes stale silently and
the next reader needs to know what it was written against. `tools/__init__.py` and
`tools/actions/container_manager.py` on `main` are **byte-identical to this host's 1.6.3** (md5), so
nothing has changed underneath.

**The fix is unclaimed.** Nothing open or merged addresses it:

| | |
|---|---|
| [#2388](https://github.com/waydroid/waydroid/pull/2388) (open) | refactors `tools/__init__.py` into a `DISPATCH` table — the exact file — and keeps `"stop": actions.container_manager.stop`. Same direct call, restructured |
| [#2389](https://github.com/waydroid/waydroid/pull/2389) (open) | rewrites `container_manager.stop()`'s internals (`stop_networking`, `stop_sensors`, `wait_for_status`) but never touches the CLI and does not change the `args.session` semantics |
| issue search | no report of the divergence itself |

**The symptom, though, is a long-running complaint** — always reported via the Android-shutdown cause,
never this one:

| | |
|---|---|
| [#774](https://github.com/waydroid/waydroid/issues/774) (2023) | `Already tracking a session` after the compositor exits. Closed the same day: *"Wayland clients die when the compositor quits"* — true, and not the whole answer; it is the same wedge [25](25-waydroid-in-cage.md) has to clear at every cage login |
| [#1905](https://github.com/waydroid/waydroid/issues/1905), [#2234](https://github.com/waydroid/waydroid/issues/2234) | `Session: RUNNING / Container: STOPPED` after shutting Android down from its own UI. Both closed by [#2305](https://github.com/waydroid/waydroid/pull/2305) |
| [#2244](https://github.com/waydroid/waydroid/pull/2244) (open) | an opt-in `stop_on_idle` monitor in the session manager that polls container state over D-Bus — essentially the cage watchdog, upstream. Adjacent, not overlapping |

So the Android-shutdown route to that state is fixed and the CLI route is not.

## The patches

Two, in [artifacts/upstream/](../artifacts/upstream), both applying cleanly to `main`:

**`0001-container-stop-via-dbus.patch`** — prefer `Stop(True)` over D-Bus, fall back to the direct call
when the service is unreachable. Deliberate choices:

- **`quit_session=True`, not `False`.** `False` clears the service's record but leaves the session
  manager holding `id.waydro.Session`, so the next start fails with `Session is already running` —
  wedged differently. `upgrader` gets away with `False` only because it restarts the container with the
  same session immediately afterwards.
- **`actionNeedRoot` stays.** The D-Bus method needs no privilege at all
  (`id.waydro.Container.conf` grants `send_destination` to `context="default"`), so dropping the check
  would quietly turn an admin command into one any local user can aim at another user's container.
- **No new import** — `tools/__init__.py` already does `from . import helpers`, and
  `tools/helpers/__init__.py` imports `tools.helpers.ipc`. Confirmed by importing the package on the
  host and resolving `tools.helpers.ipc.DBusContainerService`.

**`0002-guard-session-pid-signal.patch`** — independent, droppable on its own.
`stop(quit_session=True)` does `os.kill(int(args.session["pid"]), signal.SIGUSR1)` on a pid recorded at
`Start()`, with nothing rechecking it is still that process. pids get reused and SIGUSR1's default
disposition is *terminate*, so a stale record means signalling something unrelated. The service now
records the process start time (field 22 of `/proc/<pid>/stat`) and compares before signalling. Patch 1
adds a caller to that path, which is why the guard travels with it.

The same hazard is why [25](25-waydroid-in-cage.md)'s wrapper releases a leftover session with
`Stop(false)` over busctl instead of `waydroid session stop`.

## Tested on hardware, 2026-09-29

~~**Not runtime-tested.**~~ Run against a live container on bigtab01 the evening of 2026-09-29, at
the owner's go-ahead. `/usr` is read-only on an rpm-ostree host, so the patched tree was run from a
copy at `/var/tmp` — `sudo python3 <copy>/waydroid.py container stop`, which works because
`/usr/bin/waydroid` is a symlink into `/usr/lib/waydroid` and Python puts the *resolved* script
directory on `sys.path[0]`. `PYTHONPATH` cannot shadow that, which is why a copy rather than an
env var. Afterwards `rpm -V waydroid` reported mtime deltas only, no content difference on any file.

**Both patches apply cleanly to the installed 1.6.3 as well as to `main`** at `c78a305a38a9`.

**The bug reproduces, and `GetSession` states it exactly.** After an unpatched
`sudo waydroid container stop`: `Session: RUNNING / Container: STOPPED`, and the service still
returns a populated session dict with `pid 159807`. `"session" in args` is still true.

**Commit 1 works end to end.** Same starting state, patched CLI: `Session: STOPPED`,
`GetSession -> a{ss} 0`, the session process gone (so `SIGUSR1` was delivered and handled), and the
next `waydroid session start` reached `RUNNING / RUNNING` with no wedge.

### The test found two things the drafts had wrong

**1. The wedge is conditional, and the ordinary case self-heals.** The first attempt appeared to
disprove the whole report: `GetSession` came back `a{ss} 0` a minute after the stop. The reason is
`session_manager.py:34`, which registers a `Disconnected` handler calling
`stop_container(quit_session=False)` — the service then reaches `del args.session` at
`container_manager.py:270`. So when the session process dies with the container, which is what a
desktop or cage session does because the stop takes Android and `waydroid show-full-ui` with it,
**the state clears itself.**

Reproducing the fault needs a session process that *survives* — the ssh-started case
[docs/24](24-graceful-logout.md) describes. Done here with a headless `WLR_BACKENDS=headless sway`
providing `wayland-1` and `waydroid session start` under `setsid`. Then the bad state persisted
until `waydroid session stop`.

**This was nearly fatal to the submission.** A maintainer testing it the obvious way would have
watched it clear itself and closed the report. Both the issue and the PR now state the condition
up front.

**2. The error message in the issue was wrong for the common case.** The draft showed
`Already tracking a session`. What actually appears is **`Session is already running`** — because the
surviving session process still owns `id.waydro.Session`, so `session_manager`'s own guard fires
before anything reaches the container service's `do_start`. The two messages are two different
residues:

| left behind | message |
|---|---|
| session process alive, owns `id.waydro.Session` | `Session is already running` — measured |
| bus name released but `args.session` not cleared (e.g. `SIGKILL`) | `Already tracking a session` — read from the code |

The distinction was already in this note's own patch rationale — it is why patch 1 passes
`quit_session=True` rather than `False` — and the issue text contradicted it anyway.

### `pid_start_time()`, including the case that was never exercised

~~**that specific case was not exercised**, the shell available refused to fake the process name~~ —
**done.** `prctl(PR_SET_NAME)` renames a process where `argv[0]` cannot, so a child was renamed to
`ev) il ((name`: spaces plus an unbalanced parenthesis.

The oracle needed care. **`awk '{print $22}'` is not ground truth** — it splits on whitespace, so it
*is* the naive parser, and against a hostile `comm` it returns `1` right alongside a naive Python
split. The first version of this test used awk as the oracle and reported a failure that was really
awk being wrong. Since a process's start time is fixed at creation, the fix is to read it while
`comm` is still plain — where whitespace splitting provably agrees — and again after the rename:

```
phase 1 comm is plain              PASS 'python3'
phase 1 correct == naive           PASS 3083431 vs 3083431
phase 2 comm is hostile            PASS 'ev) il ((name'
start time unchanged               PASS 3083431 vs 3083431
naive parse now WRONG              PASS naive=1 truth=3083431
stable across reads                PASS
differs between processes          PASS
dead pid -> None                   PASS
nonexistent pid -> None            PASS
```

**Still not exercised:** commit 2's guard runs in the *service* process, and the service was the
unpatched one throughout, so the recording at `do_start()` and the stale-pid branch never ran live.
Reaching that branch needs a pid reuse, which a test cannot arrange on demand. The guard degrades to
current behaviour when the recorded value is absent, so an upgrade across a running service cannot
regress — which is the property that matters and is visible in the code.

`helpers.ipc.DBusContainerService` resolves from the `tools/__init__.py` namespace on the host.

## Also staged

`comment-2389.md`, for [#2389](https://github.com/waydroid/waydroid/pull/2389). Its
`_validate_session_owner` runs in front of `GetSession`, and the guard fails on
`"session" not in self.args` before it can tell "not yours" from "not there" — so a non-root caller
with no session running gets an error where it used to get `{}`. `waydroid status` is unaffected
(`status.py` catches `DBusException` and prints STOPPED), but external tooling that asks the bus "is a
session already running?" before starting one gets an error in exactly the state where the answer is
*no*, which is the state every login starts in. The comment suggests returning `{}` when nothing is
tracked and applying the ownership check only when something is.

This is not hypothetical here: it is why [25](25-waydroid-in-cage.md)'s wrapper probes `NameHasOwner`
on the bus rather than inferring "no service" from a failed `GetSession`.

## Status

**Runtime-tested 2026-09-29 and being submitted.** Nothing has been posted to GitHub yet at the time
of writing; the issue and PR bodies below were rewritten against what the test measured.

| file | what |
|---|---|
| `artifacts/upstream/issue-container-stop.md` | the issue, ready to paste |
| `artifacts/upstream/pr-container-stop.md` | the PR body; fill in `#<ISSUE>` |
| `artifacts/upstream/0001-container-stop-via-dbus.patch` | commit 1 |
| `artifacts/upstream/0002-guard-session-pid-signal.patch` | commit 2 |
| `artifacts/upstream/comment-2389.md` | the review comment |
