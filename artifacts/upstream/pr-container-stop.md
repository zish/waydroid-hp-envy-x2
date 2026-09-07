Title: tools: route "waydroid container stop" through the container service

---

Fixes #<ISSUE>

`waydroid container stop` calls `container_manager.stop()` directly, in the CLI's own process, rather than asking the service that owns the container. Three things only the service can do are therefore skipped: clearing the session it tracks in `args.session`, quitting its hardware-manager thread, and serialising the teardown against a session stopping concurrently. The visible result is `Session: RUNNING / Container: STOPPED` and `Already tracking a session` on the next `waydroid session start`. The issue has the detail.

### Commit 1 — route through the service

Prefer `Stop(True)` over D-Bus, fall back to the direct call when the service is not reachable, so the command remains usable for recovery when the service is down. This is the same idiom `upgrader.upgrade()` already uses.

`quit_session=True` rather than `False`: `False` would clear the service's record but leave the session manager holding `id.waydro.Session`, so the next start would fail with `Session is already running` instead — wedged differently. `upgrader` can pass `False` only because it restarts the container with the same session immediately afterwards.

`actionNeedRoot` is deliberately kept. The D-Bus method needs no privilege (`id.waydro.Container.conf` grants `send_destination` to `context="default"`), and dropping the check would quietly turn an admin command into one any local user can aim at another user's container.

No new import: `tools/__init__.py` already does `from . import helpers`, and `tools/helpers/__init__.py` imports `tools.helpers.ipc`.

### Commit 2 — don't signal a session pid that has been reused

Independent of commit 1 and can be dropped on its own.

`stop(quit_session=True)` does `os.kill(int(args.session["pid"]), signal.SIGUSR1)` on a pid recorded back at `Start()`, with nothing rechecking that it is still the same process. pids are reused, and SIGUSR1's default disposition is to terminate, so a stale record means signalling something unrelated. Commit 1 adds a caller to that path, which is why the guard is here.

The service now records the session process's start time (field 22 of `/proc/<pid>/stat`) at `Start()` and compares it before signalling. Parsing splits on the last `)` so a `comm` containing spaces or parentheses cannot shift the fields.

### Testing

- Both patches apply cleanly to `main` and both files parse.
- `pid_start_time()` cross-checked against `awk '{print $22}' /proc/<pid>/stat`: matches for live pids, stable across reads, differs between processes, `None` for a dead pid.
- `helpers.ipc.DBusContainerService` confirmed reachable from the `tools/__init__.py` namespace with no added import.

**Not runtime-tested**: exercising it means stopping a live container, which the machine this was found on could not spare at the time. Reviewers should treat the behavioural claims as read from the code, which is where they came from.
