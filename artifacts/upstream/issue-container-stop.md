Title: `waydroid container stop` leaves the container service tracking a session that no longer exists

---

### Summary

`waydroid container stop` stops the container without telling the service that owns it, so the service goes on tracking a session whose container is gone. You end up at `Session: RUNNING / Container: STOPPED`, and starting a session again fails until you run `waydroid session stop`.

Same end state as #1905 and #2234, which #2305 fixed for the Android-shutdown cause. This is a second, unrelated way to reach it, and it is still present on `main`.

### What happens

```
$ sudo waydroid container stop
[20:46:05] Stopping container

$ waydroid status
Session:	RUNNING
Container:	STOPPED

$ waydroid session start
[20:46:10] Session is already running
```

Recovery is `waydroid session stop`, which does go through the service.

The service confirms it is still holding the record:

```
$ busctl --system call id.waydro.Container /ContainerManager \
        id.waydro.ContainerManager GetSession
a{ss} 14 "user_name" "jmelanso" ... "pid" "159807" ... "state" "STOPPED"
```

A populated dict there means `args.session` survived in the service, so `"session" in args` is still true.

### Why

[`tools/__init__.py:78`](https://github.com/waydroid/waydroid/blob/main/tools/__init__.py#L78) calls `container_manager.stop()` directly, in the CLI's own process, instead of asking the service:

```python
        elif args.action == "container":
            actionNeedRoot(args.action)
            if args.subaction == "start":
                actions.container_manager.start(args)
            elif args.subaction == "stop":
                actions.container_manager.stop(args)
```

That process has a fresh `args` namespace with no `session` attribute, so `stop()` tears down the container, network and mounts but skips the three things only the service can do:

1. **Clear `args.session`.** At [`container_manager.py:265`](https://github.com/waydroid/waydroid/blob/main/tools/actions/container_manager.py#L265), `if "session" in args:` is False in the CLI process, so the record survives and the next `do_start()` raises `Already tracking a session` ([`container_manager.py:157-158`](https://github.com/waydroid/waydroid/blob/main/tools/actions/container_manager.py#L157-L158)).

2. **Stop the hardware manager.** `services.hardware_manager.stop()` ([`container_manager.py:230`](https://github.com/waydroid/waydroid/blob/main/tools/actions/container_manager.py#L230)) sets a module-global `stopping` and quits `args.hardwareLoop` — both of which live in the *service's* process. In the CLI, `stopping` is a fresh global and `args.hardwareLoop` does not exist; the `AttributeError` is caught and logged as `Hardware service is not even started`. The service's `service_thread` goes on re-registering `waydroidhardware` for a container that is gone.

3. **Serialise the teardown.** Nothing orders the CLI's `stop()` against the service's. If a session ends at the same moment, both processes run `umount_rootfs`, `waydroid-net.sh stop`, and `pidof waydroid-sensord` followed by `kill -9`. The service's main loop is single-threaded, so routing through D-Bus removes that race for free.

### How to reproduce

**The session process has to still be running after the container stops.** Start the session so that it is not tied to the compositor's lifetime:

```
# in one shell, against an already-running compositor
$ WAYLAND_DISPLAY=wayland-1 setsid waydroid session start

# in another
$ sudo waydroid container stop
$ waydroid status          # Session: RUNNING / Container: STOPPED
$ waydroid session start   # Session is already running
```

If instead the session process exits along with the container — which is what happens when you launch it from a compositor that goes away, because the stop takes Android and `waydroid show-full-ui` with it — then `session_manager`'s `Disconnected` handler ([`session_manager.py:34`](https://github.com/waydroid/waydroid/blob/main/tools/actions/session_manager.py#L34)) calls `stop_container(quit_session=False)`, the service reaches `del args.session`, and the state clears itself after a second or two.

Both paths were measured on the same host, so it is worth knowing which one you are testing.

### Two error messages, one fault

| what is left behind | next `waydroid session start` says |
|---|---|
| session process alive, still owns `id.waydro.Session` | `Session is already running` — measured |
| bus name released but `args.session` not cleared (e.g. the process was `SIGKILL`ed) | `Already tracking a session`, from `do_start` — read from the code, not measured here |

The second is the one that turns up in search results, including #774. Both are the same underlying fault: a record the service will not release.

### Suggested fix

Route the CLI through the service, falling back to the direct call when it is not reachable — so `waydroid container stop` still works as a recovery command with the service down. That is the idiom `upgrader.upgrade()` already uses at [`upgrader.py:43-47`](https://github.com/waydroid/waydroid/blob/main/tools/actions/upgrader.py#L43-L47).

### Waydroid version

Found on 1.6.3, and **still present on `main`** — re-checked 2026-09-29 at `c78a305a38a9`. The `stop` dispatch is unchanged at `tools/__init__.py:78-79`, and `tools/actions/container_manager.py` has had no commit since 2026-03-29 (`13cb638f50ea`).

Nothing open addresses it: #2388 refactors this exact file into a dispatch table and keeps the same direct call; #2389, which rewrote `stop()`'s internals, was closed unmerged.

### Operating System

Fedora 44 Sway Atomic (rpm-ostree), kernel 7.1.x, SELinux enforcing. Waydroid 1.6.3-1.fc44.
