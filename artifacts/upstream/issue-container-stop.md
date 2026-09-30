Title: `waydroid container stop` leaves the container service tracking a session that no longer exists

---

### Describe the bug

`waydroid container stop` does not go through the container service. [`tools/__init__.py:78`](https://github.com/waydroid/waydroid/blob/main/tools/__init__.py#L78) calls `container_manager.stop()` directly, in the CLI's own process:

```python
        elif args.action == "container":
            actionNeedRoot(args.action)
            if args.subaction == "start":
                actions.container_manager.start(args)
            elif args.subaction == "stop":
                actions.container_manager.stop(args)
```

That process has its own `args` namespace with no `session` attribute, so `stop()` tears the container, network and mounts down but skips everything that only the service holds. Afterwards the service still believes a session is running:

```
$ sudo waydroid container stop
[20:46:05] Stopping container
$ waydroid status
Session:	RUNNING
Container:	STOPPED
$ busctl --system call id.waydro.Container /ContainerManager \
        id.waydro.ContainerManager GetSession
a{ss} 14 "user_name" "jmelanso" ... "pid" "159807" ... "state" "STOPPED"
$ waydroid session start
[20:46:10] Session is already running
```

`GetSession` still returning a populated dict is the defect stated exactly: the service's `args.session` survived, so `"session" in args` is still true.

### One condition, and it decides whether you can reproduce this

**The session process has to outlive the container stop.** If it exits — which is what happens under a desktop or kiosk session, because stopping the container takes Android and therefore `waydroid show-full-ui` with it — then `session_manager`'s own `Disconnected` handler ([`session_manager.py:34`](https://github.com/waydroid/waydroid/blob/main/tools/actions/session_manager.py#L34)) runs `stop_container(quit_session=False)`, the service reaches `del args.session`, and the state clears itself a second or two later.

So a casual test looks like there is no bug. Measured both ways on the same host: with the session started from a compositor that exits, `GetSession` went from populated to `a{ss} 0` on its own; with the session started over ssh so its process survives, the state above persisted until `waydroid session stop`.

That ssh-started case is not exotic — it is the documented way to run a session against a compositor you did not launch it from, and it is the case where recovery needs a command the user has no reason to guess.

### Which error you get depends on what is left behind

There are two residues and they produce different messages, which is worth stating because the second is the one people search for:

| state | next `waydroid session start` says |
|---|---|
| session process alive, still owns `id.waydro.Session` | `Session is already running` — **measured**, above |
| session process gone without clearing the record (e.g. `SIGKILL`), so the bus name is free but `args.session` is not | `Already tracking a session`, from `do_start` — read from the code, not measured here |

Both are the same underlying fault: a record the service will not release.

### Three things the direct call cannot do

1. **Clear `args.session`.** At [`container_manager.py:265`](https://github.com/waydroid/waydroid/blob/main/tools/actions/container_manager.py#L265), `if "session" in args:` is False in the CLI process, so the service's record survives and the next `do_start()` raises `Already tracking a session` ([`container_manager.py:157-158`](https://github.com/waydroid/waydroid/blob/main/tools/actions/container_manager.py#L157-L158)).

2. **Stop the hardware manager.** `services.hardware_manager.stop()` ([`container_manager.py:230`](https://github.com/waydroid/waydroid/blob/main/tools/actions/container_manager.py#L230)) sets a module-global `stopping` and quits `args.hardwareLoop` — both of which live in the *service's* process. In the CLI, `stopping` is a fresh global and `args.hardwareLoop` does not exist; the `AttributeError` is caught and logged as `Hardware service is not even started`. The service's `service_thread` goes on re-registering `waydroidhardware` for a container that is gone.

3. **Serialise the teardown.** Nothing orders the CLI's `stop()` against the service's. If a session ends at the same moment, both processes run `umount_rootfs`, `waydroid-net.sh stop`, and `pidof waydroid-sensord` followed by `kill -9`. The service's main loop is single-threaded, so routing through D-Bus removes that race for free.

### Why the symptom looks familiar

The resulting `Session: RUNNING / Container: STOPPED` is the same state reported in #1905 and #2234, which #2305 fixed for the Android-shutdown cause. This is a second, unrelated way to reach it, and it is still present on `main`.

### Recovery

`waydroid session stop`, which does go through the service.

### Suggested fix

Route the CLI through the service, falling back to the direct call when it is not reachable — so `waydroid container stop` still works as a recovery command with the service down. That is the idiom `upgrader.upgrade()` already uses at [`upgrader.py:43-47`](https://github.com/waydroid/waydroid/blob/main/tools/actions/upgrader.py#L43-L47).

### Waydroid version

Found on 1.6.3, and **still present on `main`** — re-checked 2026-09-29 at `c78a305a38a9`. The `stop` dispatch is unchanged at `tools/__init__.py:78-79`, and `tools/actions/container_manager.py` has had no commit since 2026-03-29 (`13cb638f50ea`).

Nothing open addresses it: #2388 refactors this exact file into a dispatch table and keeps the same direct call; #2389, which rewrote `stop()`'s internals, was closed unmerged.

### Operating System

Fedora 44 Sway Atomic (rpm-ostree), kernel 7.1.x, SELinux enforcing. Waydroid 1.6.3-1.fc44.

### How this was tested

Everything above was run on that host on 2026-09-29 against a live container. `/usr` is read-only there, so the patched tree was run from a copy — `sudo python3 <copy>/waydroid.py container stop` — and `rpm -V waydroid` afterwards reports no content difference on any file.

With the patch applied, from the same starting state:

```
Session:	STOPPED          (was RUNNING / STOPPED)
GetSession -> a{ss} 0        (was a populated dict)
session process              gone -- SIGUSR1 delivered and handled
waydroid session start       succeeds; RUNNING / RUNNING
```
