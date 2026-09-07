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
$ waydroid status
Session:	RUNNING
Container:	STOPPED
$ waydroid session start
[...] Already tracking a session
```

### Three things the direct call cannot do

1. **Clear `args.session`.** At [`container_manager.py:265`](https://github.com/waydroid/waydroid/blob/main/tools/actions/container_manager.py#L265), `if "session" in args:` is False in the CLI process, so the service's record survives and the next `do_start()` raises `Already tracking a session` ([`container_manager.py:157`](https://github.com/waydroid/waydroid/blob/main/tools/actions/container_manager.py#L157)).

2. **Stop the hardware manager.** `services.hardware_manager.stop()` ([`container_manager.py:230`](https://github.com/waydroid/waydroid/blob/main/tools/actions/container_manager.py#L230)) sets a module-global `stopping` and quits `args.hardwareLoop` — both of which live in the *service's* process. In the CLI, `stopping` is a fresh global and `args.hardwareLoop` does not exist; the `AttributeError` is caught and logged as `Hardware service is not even started`. The service's `service_thread` goes on re-registering `waydroidhardware` for a container that is gone.

3. **Serialise the teardown.** Nothing orders the CLI's `stop()` against the service's. If a session ends at the same moment, both processes run `umount_rootfs`, `waydroid-net.sh stop`, and `pidof waydroid-sensord` followed by `kill -9`. The service's main loop is single-threaded, so routing through D-Bus removes that race for free.

### Why the symptom looks familiar

The resulting `Session: RUNNING / Container: STOPPED` is the same state reported in #1905 and #2234, which #2305 fixed for the Android-shutdown cause. This is a second, unrelated way to reach it, and it is still present on `main`.

### Recovery

`waydroid session stop`, which does go through the service.

### Suggested fix

Route the CLI through the service, falling back to the direct call when it is not reachable — so `waydroid container stop` still works as a recovery command with the service down. That is the idiom `upgrader.upgrade()` already uses at [`upgrader.py:43-47`](https://github.com/waydroid/waydroid/blob/main/tools/actions/upgrader.py#L43-L47).

### Waydroid version

1.6.3. `tools/__init__.py` and `tools/actions/container_manager.py` on `main` are byte-identical to the 1.6.3 files (verified by md5), so this applies to `main` unchanged.

### Operating System

Fedora 44 Sway Atomic, kernel 7.1.x, SELinux enforcing.
