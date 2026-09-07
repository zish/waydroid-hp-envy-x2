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

## Tested, and not

- both patches apply cleanly to `main`; both files parse
- `pid_start_time()` cross-checked against `awk '{print $22}' /proc/<pid>/stat` — matches for live
  pids, stable across reads, differs between processes, `None` for a dead one. Splitting on the last
  `)` rather than on whitespace is what makes a `comm` containing spaces or parentheses safe; **that
  specific case was not exercised**, the shell available refused to fake the process name
- `helpers.ipc.DBusContainerService` resolves from the `tools/__init__.py` namespace on the host

**Not runtime-tested.** Exercising it means stopping a live container, and the host had a session in
use. The behavioural claims are read from the code, which is where they came from. The natural time to
run it is alongside the first real cage login, which needs a logout anyway.

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

Drafted, not submitted. Nothing has been posted to GitHub.

| file | what |
|---|---|
| `artifacts/upstream/issue-container-stop.md` | the issue, ready to paste |
| `artifacts/upstream/pr-container-stop.md` | the PR body; fill in `#<ISSUE>` |
| `artifacts/upstream/0001-container-stop-via-dbus.patch` | commit 1 |
| `artifacts/upstream/0002-guard-session-pid-signal.patch` | commit 2 |
| `artifacts/upstream/comment-2389.md` | the review comment |
