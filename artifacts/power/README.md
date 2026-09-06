# Power-button and sleep configuration staged for bigtab01

Both files were installed to the host on 2026-09-06, mode `0644`. The rationale, what is
verified, and what is still untested are in [docs/15-power-button.md](../../docs/15-power-button.md).

| File | Installed to |
|---|---|
| `10-power-button.conf` | `/etc/systemd/logind.conf.d/10-power-button.conf` |
| `10-s2idle.conf` | `/etc/systemd/sleep.conf.d/10-s2idle.conf` |

**No originals are kept alongside, because there were none.** The host had no
`/etc/systemd/logind.conf`, no `/etc/systemd/sleep.conf` and no drop-in directories at all — it
was running upstream defaults, under which a short press on the power button powered the machine
off. Reverting means deleting these two files, not restoring a backup.

Applied with `systemctl reload systemd-logind` (`CanReload=yes`, so no session restart).
