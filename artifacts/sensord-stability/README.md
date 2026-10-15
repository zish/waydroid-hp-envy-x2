# Sampling waydroid-sensord's cost over days, not minutes

`waydroid-sensord-sample` appends one line per run to
`/var/log/waydroid-sensord-stability.log` and exits.
`waydroid-sensord-sample.timer` runs it every ten minutes.

## What it is for

[docs/67](../../docs/67-sensor-poll-cost.md) cut the daemon's CPU from 1.9% of a core to ~0.9% by
polling each sensor at the rate Android asked for instead of a flat 20 Hz. Three of the claims
that came with that work can only be tested by time:

| claim | column to watch |
|---|---|
| CPU stays near 0.9% of a core and does not drift up | `interval=` |
| holding the IIO descriptors open does not leak them | `fds=` |
| RSS does not creep | `rss=` |

The descriptors are the interesting one. `DisableSensorEvents` deliberately does **not** close
them, because it runs on an hwbinder thread while `PollOnce` may be mid-`pread` on those same
descriptors — and the dangerous outcome of closing them there is not `EBADF` but a recycled
descriptor number quietly reading some other file. They are only dropped on the main thread, on a
failed read or a reprobe. That is correct, and it is also exactly the shape of a leak: three
descriptors per sensor across thousands of activate/deactivate cycles would show here long before
it mattered. The baseline is **25**.

`interval=` is the CPU percentage since the previous sample, which is the figure that can show a
drift. `life=` is the average since the process started, which is dominated by its early history
and cannot.

## Reading a line

```
2026-10-15T10:49:14-04:00 pid=1833 ver=1.0.3-1 exe=/usr/bin/waydroid-sensord up=3138s \
    cpu=28s life=0.892% interval=-% rss=4252KB vsz=450252KB threads=5 fds=25
```

`interval=-%` means there was no comparable previous sample: the first run after a boot, or after
the daemon's pid changed. `ver=` and `exe=` are recorded because a hand-built binary in
`/usr/local/bin` silently shadows the packaged one in `/usr/bin` — the trap docs/67 documents —
and a log spanning an upgrade is otherwise uninterpretable. A `?` in any field means the lookup
failed, usually for want of root; it does not mean zero, and `ver=?` is not `ver=unpackaged`.

## Install

```sh
sudo sh install.sh              # units into /etc/systemd/system, script into /usr/local/bin
sudo sh install.sh --uninstall  # removes all of it; keeps the log
```

Honours `DESTDIR`/`PREFIX`/`UNITDIR` like the other artifacts here, so the same script would serve
as a package's `%install` step. It is hand-installed today — it is a diagnostic, not part of the
daemon.

## Notes

- **It replaced a `setsid nohup` loop.** The original sampler was
  `while :; do ...; sleep 600; done` started by hand, which did not survive a reboot, so after
  every reboot it silently collected nothing. Its log is still at
  `~jmelanso/sensord-stability.log` on bigtab01, nine lines, not continued here.
- **`OnBootSec=5min` is deliberately late.** `container_manager.py` spawns the daemon at session
  start, which is after a greeter login, so a sample at boot would only ever record
  `no live daemon`.
- **The unit cannot use `ProtectProc=`.** It has to read another process's `/proc`, and
  `ProtectProc=invisible` hides exactly the entries it reads — which would fail as a
  plausible-looking `no live daemon` rather than as an error.
- **Writing the state file as root under `/tmp` fails**, which is `fs.protected_regular` refusing
  to open another user's file for writing inside a sticky world-writable directory, even for root.
  Only a trap when testing by hand; the installed state file is root-owned in `/var/lib`.
