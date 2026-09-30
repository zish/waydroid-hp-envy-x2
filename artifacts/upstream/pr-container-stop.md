Title: tools: route "waydroid container stop" through the container service

---

Fixes #<ISSUE>

**Two commits, two files, +41/-4.** One concern each; the second is independent and can be dropped on its own.

`waydroid container stop` calls `container_manager.stop()` directly, in the CLI's own process, rather than asking the service that owns the container. Three things only the service can do are therefore skipped: clearing the session it tracks in `args.session`, quitting its hardware-manager thread, and serialising the teardown against a session stopping concurrently. The visible result is `Session: RUNNING / Container: STOPPED`, and `Session is already running` on the next `waydroid session start`. The issue has the detail.

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

Run against a live container on Fedora 44 Sway Atomic, Waydroid 1.6.3, on 2026-09-29.

**Commit 1, end to end.** From `RUNNING / RUNNING`, with the session started so that its process outlives the container:

| | before patch | after patch |
|---|---|---|
| `waydroid status` | `Session: RUNNING / Container: STOPPED` | `Session: STOPPED` |
| `GetSession` | populated dict, `pid 159807` | `a{ss} 0` |
| session process | alive | gone — `SIGUSR1` delivered and handled |
| next `waydroid session start` | `Session is already running` | succeeds, `RUNNING / RUNNING` |

The host is rpm-ostree with a read-only `/usr`, so the patched tree was run from a copy rather than installed; `rpm -V waydroid` afterwards reports no content difference on any file.

**Commit 2.** `pid_start_time()` unit-tested, including the case the parse exists for. A child process renamed itself via `prctl(PR_SET_NAME)` to `ev) il ((name` — spaces and unbalanced parentheses. Because a process's start time is fixed at creation, the value read while `comm` was still plain is the oracle:

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

Note `awk '{print $22}'` is *not* a valid oracle here — it splits on whitespace, so it is the naive parser and returns `1` alongside it. That is the whole reason for splitting on the last `)`.

**What was not exercised.** Commit 2's guard runs in the service process, and the service was the unpatched one throughout — so the recording at `do_start()` and the stale-pid branch itself were not run live. Reaching that branch requires a pid to be reused, which is not something a test can arrange on demand. The guard is written to degrade to current behaviour when the recorded value is absent (`getattr(..., None)` then signal anyway), so an upgrade across a running service cannot regress.

- Both patches apply cleanly to `main` at `c78a305a38a9` **and** to the installed 1.6.3 tree.
- `helpers.ipc.DBusContainerService` confirmed reachable from the `tools/__init__.py` namespace with no added import.

### One thing reviewers should know before reproducing

The bad state clears itself if the session process exits with the container, which is what happens under a normal desktop or kiosk session: `session_manager`'s `Disconnected` handler calls `stop_container(quit_session=False)` and the service reaches `del args.session`. To see the fault, the session process has to survive — start the session over ssh against an existing compositor. Both behaviours were measured on the same host. The issue has the detail.
