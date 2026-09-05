# Host access — the non-PTY SSH hang (RESOLVED)

> **Resolved 2026-09-05.** Restarting `sshd` on the host fixed it. Non-PTY exec, `sftp`, and
> `rsync` all work normally again. Host load at the time of failure was 3.16 with ten stale
> hung sessions accumulated; afterwards it was 0.01. The cause was most likely sshd in a
> degraded state under memory/load pressure rather than any configuration error — no
> `ForceCommand`, `~/.ssh/rc`, or `/etc/ssh/sshrc` was ever involved.
>
> **`bin/rsh` is no longer required.** It is kept because the failure mode may recur on a
> memory-constrained machine, and the `-tt` trick is the fastest way to keep working if it does.
>
> The original investigation is preserved below.

## Symptom

Interactive `ssh 10.42.0.137` works normally. Anything that does **not** allocate a PTY hangs
forever after successful authentication:

| Invocation | Result |
|---|---|
| `ssh host` (interactive, PTY) | works |
| `ssh host 'cmd'` (exec, no PTY) | hangs |
| `ssh -T host 'cmd'` | hangs |
| `sftp host` | hangs |
| `rsync host:/file .` | hangs (exit 124 / code 255) |
| `ssh -tt host 'cmd'` (forced PTY) | **works** |

Authentication itself is fine — verbose output confirms the key is accepted:

```
debug1: Server accepts key: .../id_rsa RSA SHA256:H0oVS/...
Authenticated to 10.42.0.137 ([10.42.0.137]:22) using "publickey".
```

The stall happens *after* auth, during session setup.

## Workaround

Force a PTY with `-tt` and strip the resulting carriage returns. Helper used for this project:

```bash
#!/bin/bash
# run a command on bigtab01 via forced-PTY ssh (non-PTY exec hangs on this host)
timeout "${RSH_TIMEOUT:-60}" ssh -tt -o BatchMode=yes 10.42.0.137 "$@" < /dev/null 2>&1 \
  | tr -d '\r' | sed '/^Connection to .* closed\.$/d'
```

Caveats: stdout and stderr are merged by the PTY, exit codes are not reliably propagated, and
binary output is mangled. Good enough for diagnostics, not for data transfer.

## rsync is blocked by this

`rsync` needs a clean binary non-PTY channel, and a PTY would corrupt its protocol — so `-tt`
is not a workaround for it. Until the root cause is fixed, file transfer options are:

- `ssh -tt host 'base64 -w0 < /path/file'` piped through `base64 -d` locally (small files only)
- fixing the root cause (preferred)

## Sessions leak

Each hung non-PTY attempt leaves a session open indefinitely. `who` showed ten stale
`jmelanso sshd` entries with no TTY, against 23 `sshd` processes. On a machine with 8 GB RAM
running Waydroid this is worth cleaning up, and it means diagnostics should avoid non-PTY
attempts entirely.

## Ruled out

- **Shell rc files** — neither `~/.ssh/rc` nor `/etc/ssh/sshrc` exists.
- **A broken login shell** — `sftp` uses the subsystem and bypasses the shell entirely, yet
  hangs identically.

## Still unknown (needs root)

`/etc/ssh/sshd_config` and `/etc/ssh/sshd_config.d/` are not readable as a normal user, so the
server-side configuration has not been inspected. Candidates worth checking:

- A `ForceCommand` or `Subsystem` directive that misbehaves without a TTY
- PAM session modules blocking on something (`pam_systemd` / logind / D-Bus)
- `strace` on a hung `sshd` child, which would answer it directly
