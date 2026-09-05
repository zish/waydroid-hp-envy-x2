# Stuck session: binder ping spam in dmesg

Observed 2026-09-04, ~22:10 onward. **RESOLVED 2026-09-05** — the session was restarted and the
spam stopped; `journalctl -k --since -60s | grep -c binder` now returns `0`. Kept as a reference
for decoding binder messages and for recognising the stuck `Session: RUNNING / Container: STOPPED`
state if it recurs.

## Symptom

`journalctl -k` (equivalently `journalctl --dmesg`; plain `dmesg` is blocked for non-root by
`kernel.dmesg_restrict`) fills at roughly two events per second:

```
kernel: binder: 913:913 cannot find target node
kernel: binder: 913:913 transaction call to 0:0 failed 2712089/29189/-22, code 1599098439 size 0-0 line 3252
kernel: binder: 2587:2682 cannot find target node
kernel: binder: 2587:2682 transaction call to 0:0 failed 2712090/29189/-22, code 1599098439 size 0-0 line 3252
kernel: binder_debug: 10 callbacks suppressed
```

Measured rate: 132 binder lines in 60 s, plus rate-limit suppression notices.

## Decoding the message

| Field | Value | Meaning |
|---|---|---|
| `0:0` | target pid 0, handle 0 | binder **handle 0** — the context manager, i.e. Android's `servicemanager` |
| `code 1599098439` | `0x5F504E47` = `_PNG` | `IBinder::PING_TRANSACTION` — a liveness ping, not real work |
| `-22` | `-EINVAL` | no node is registered as context manager |
| `cannot find target node` | — | nothing is listening on handle 0 |

In plain terms: **something pinged Android's service manager, and there is no service manager.**
This is the expected kernel response when a host-side process talks to binder while the Waydroid
container is not running. It is a symptom, never a cause.

## Who is doing it

Both peers are Waydroid's own long-lived processes — not diagnostic commands:

```
913   root       /usr/bin/python3 /usr/bin/waydroid container start    (waydroid-container.service)
2587  jmelanso   /usr/bin/python3 /usr/bin/waydroid show-full-ui
```

Waydroid reaches the Android side through `gbinder`. `tools/interfaces/IPlatform.py:298`
(`get_service`) opens a `gbinder.ServiceManager` on `/dev/binder` and then retries
`get_service_sync()` once per second — `tries = 1000` — waiting for the platform service to
appear. Each attempt (and gbinder's own presence check behind `is_present()`) emits one PING to
handle 0. Two stuck processes × 1 Hz = the observed rate.

## Root cause

**Android was shut down from inside the Waydroid session** (user action, confirmed). That stops
the container but leaves the session up, producing an inconsistent pair:

```
Session:   RUNNING
Container: STOPPED
```

`waydroid.log` shows the container ending at 22:10:50 after running since 20:34:12. Both
processes above are still waiting for an Android side that will never come back on its own.

## Not the cause — ruled out

- **The `lxc.hook.post-stop` error.** `waydroid.log` reports
  `run_buffer: 569 Script exited with status 126` / `Failed to run lxc.hook.post-stop`.
  `/var/lib/waydroid/lxc/waydroid/config:17` sets `lxc.hook.post-stop = /dev/null`, which is
  Waydroid's own way of disabling the hook. Status 126 is "found but not executable" — expected
  and cosmetic. It follows the shutdown, it did not cause it.
- **Diagnostics run against the host.** All investigation so far has been read-only, and the two
  spamming PIDs have been alive since container start.
- **Missing binder devices.** `/dev/binderfs` is mounted with `binder`, `hwbinder`, `vndbinder`
  present and mode `crw-rw-rw-`. The binder driver is fine; there is simply no Android on it.

## Clearing it

As `jmelanso`, no sudo required:

```bash
waydroid session stop     # tears down the session; both waiters should exit
waydroid show-full-ui     # or `waydroid session start` for a headless session
```

If PID 2587 survives the stop, kill it directly — it is the process holding the stale wait.

## Why it matters for the camera work

[01-camera-investigation.md](01-camera-investigation.md) lists the decisive evidence as
"requires the container running". This stuck state is the reason the container is stopped, so
clearing it is a prerequisite for that step, not a side quest.

## Incidental finding (corrected)

An earlier note here claimed `cheese` was not installed, on the strength of `rpm -q cheese` and
`command -v cheese` both failing. That test was wrong for this host: Cheese is installed as a
**Flatpak** (`org.gnome.Cheese` 44.1, origin `fedora`), so it appears in neither the rpm database
nor `PATH`. On Sway Atomic, check `flatpak list` before concluding a GUI app is missing.

The camera is confirmed working on the host via Cheese — see
[01-camera-investigation.md](01-camera-investigation.md).

`adb` (`android-tools`) is layered and present. `rpm-ostree status` reports `State: idle` with no
pending deployment, so no reboot is owed.
