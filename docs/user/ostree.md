# Installing these packages on an rpm-ostree host, and the one way a change can silently not apply

If your host is Fedora Silverblue, Kinoite, Sericea, CoreOS, or any other `rpm-ostree` system, an
installed package does **not** take effect when you install it. It takes effect at the next boot,
and there is a step in between that can be lost. This page is about that step.

Everything here applies to the host, not to Android. If you are looking for why a change *inside*
Android did not appear, that is [overlay.md](overlay.md) instead.

If you read only one section, read [The scenarios](#the-scenarios).

## A change lands in three steps, not one

```
  rpm-ostree install ...        ->  STAGED     a new deployment is written to disk,
                                               but nothing boots it yet
  orderly shutdown             ->  FINALIZED  the bootloader is pointed at it
  next boot                    ->  ACTIVE     you are running it
```

The middle step is the one worth knowing about. Finalization is done by a systemd service that acts
**only while the system is shutting down**:

```ini
# /usr/lib/systemd/system/ostree-finalize-staged.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStop=/usr/bin/ostree admin finalize-staged
```

The work is in `ExecStop`. The service starts early in boot, stays active the whole time the machine
is up, and does its job when it is *stopped* — which happens during an orderly shutdown or reboot.
Until then, the record of what is staged lives in `/run/ostree/`, which is a **tmpfs**: it exists
only in memory.

## The scenarios

| What you do after installing | Does the change apply? |
|---|---|
| `systemctl reboot` | **Yes.** Shutdown finalizes it, next boot runs it. |
| `systemctl poweroff`, then power on later | **Yes.** A clean poweroff finalizes it just like a reboot. |
| Close the lid / suspend / hibernate, then resume | **No, and nothing is lost.** The system never shut down, so it is still staged and still pending. It applies at your next real reboot. |
| Hard power-off, forced reset, battery pull, crash | **No, and the staged deployment is gone.** |
| Power is lost *during* shutdown, before finalization | **No, and it is gone**, same as above. |

**A later clean reboot does not rescue a staged deployment that was lost to a hard power-off.**
There is nothing left for it to finalize: `ExecStop` never ran, so the bootloader was never pointed
at the new deployment, and the `/run/ostree/` record that named it went away with the power. You
come back up on the old deployment, with no error and no warning. **Re-run the `rpm-ostree` command
to stage it again.**

> This follows from the unit definition above and from `/run` being tmpfs, both of which are
> verified. It has not been confirmed by deliberately power-cutting a machine mid-stage.

## A staged deployment's `/etc` looks empty of your files, and that is correct

If you look inside a staged deployment before rebooting, your own `/etc` is not there:

```console
$ ls /ostree/deploy/fedora/deploy/<staged-commit>.0/etc/waydroid-extra
ls: cannot access '.../etc/waydroid-extra': No such file or directory
```

Nothing is wrong. **ostree merges `/etc` during finalization, not when the deployment is staged.**
Until `ExecStop` runs, a staged deployment's `/etc` is the new commit's *default* `/etc` and nothing
more. That is deliberate: it means `/etc` edits you make *after* staging are still picked up, rather
than frozen at install time.

The quickest way to tell an unmerged `/etc` from a damaged one is to look for a file no machine could
boot without:

| In the staged deployment's `/etc` | Means |
|---|---|
| no `fstab` (and no `crypttab`, if you use one) | not merged yet — normal, you are looking at the commit's default `/etc` |
| `fstab` present but your own files missing | something really is wrong |

The merge itself is in the finalization log, and so is its cost:

```
Stopping ostree-finalize-staged.service...
ostree[...]: Finalizing staged deployment
ostree[...]: Copying /etc changes: 35 modified, 0 removed, 157 added
ostree[...]: Refreshing SELinux policy
ostree[...]: Refreshed SELinux policy in 9439 ms
ostree[...]: Finalized deployment
```

On the reference machine that whole `ExecStop` took **23 seconds**: 2 s for the 157 added files, 9 s
to refresh the SELinux policy, the rest bookkeeping and `syncfs`. Read it back after the fact with
`journalctl -b -1 -u ostree-finalize-staged`.

**Why this matters more on a Waydroid host than on a stock one.** Waydroid keeps the Android system
and vendor images under `images_path`, which is `/etc/waydroid-extra/images` by default — so `/etc`
holds multiple gigabytes that get merged at shutdown. On the reference machine that is **3.0 GB**
(`system.img` 2.58 GB, `vendor.img` 582 MB), and it is carried into each new deployment: every
finalized deployment's `/etc` reports the full 3.0 GB under `du`. Two consequences:

- **There is a time budget.** `ostree-finalize-staged.service` ships `TimeoutStopSec=5min` rather
  than the 45 s `DefaultTimeoutStopSec`, so there is real headroom. But the 2 s above was measured
  with `/var` on **btrfs**, where the copy is nearly free. On a filesystem without reflink support
  the same merge is a genuine multi-gigabyte byte copy, and five minutes is the whole budget.
- **This is the worst possible moment to cut power.** A shutdown that appears to sit still shortly
  after you asked for a reboot is finalization doing its job, not a hang. Interrupting it puts you
  in the hard power-off row of [The scenarios](#the-scenarios), and the staged deployment is gone.

One thing this explains away: a staged deployment that has *just* been superseded by another
`rpm-ostree` command never had a merged `/etc` to lose, so nothing about its empty-looking `/etc`
tells you whether your local packages survived. Read `rpm-ostree status` for that instead — the
staged entry lists its own `LocalPackages`.

> The 23 s, the log lines, the 3.0 GB and the `TimeoutStopSec` are measured. That the gigabytes are
> **reflinked** rather than byte-copied is inferred: 2 s is not a 3 GB copy on that hardware, and
> each deployment's images have their own inodes, which rules out hardlinks. Confirm it on your own
> host by comparing physical extents with `filefrag -v` on two deployments' `system.img`.

## `--apply-live` can report failure after having already applied

`rpm-ostree install --apply-live` lands the change now *and* stages the same deployment for the
next boot, which is how most of this project's packages reached their host. It runs a sequence, and
a step **after** the filesystem work can fail while the filesystem work has already succeeded:

```
Updating /usr...done
Updating /etc...done
Running systemd-tmpfiles for /run and /var...done
error: Running tmpfiles for /run and /var: Running systemd worker: exit status: 73
```

The exit code says the command failed. The package is installed anyway — `rpm -q` answers and the
files are on disk, `%config` files in `/etc` included. So **do not read a non-zero exit as "nothing
happened"**, and do not re-run the install on that assumption; check first.

**What the failure costs you is the bookkeeping, not the files.** Compare these two:

| In `rpm-ostree status` | Meaning |
|---|---|
| `LiveCommit: <hash>` equal to the pending deployment's `Commit` | the running filesystem is consistent with what the next boot lands on, and nothing is owed |
| `InterruptedLiveCommit: <hash>` | the content applied, and rpm-ostree does not consider the sequence finished |

With `InterruptedLiveCommit` set, expect a further `--apply-live` on that host to object until
either the underlying fault is fixed or the machine is rebooted into the staged deployment. A
reboot clears it.

**One cause seen in practice, on a host that had been working for weeks:** `/var` owned by a
regular user instead of `root`. systemd 259 refuses what it calls an unsafe path transition when a
parent directory is owned by a non-root user, which makes the tmpfiles step fail. It is harmless at
boot — the boot-time unit logs the same complaints and still reports `Finished` — so it can sit
unnoticed until an `--apply-live` turns it into an error.

```bash
ls -ld /var                       # expect root root
sudo systemd-tmpfiles --dry-run --create --remove --boot --prefix=/run --prefix=/var
```

The second command names every path it objects to without changing anything, which is how to tell
this cause from another.

## How to tell which state you are in

```bash
rpm-ostree status
```

- A line reading **`Staged`** with a `Diff:` under it, above the `*`-marked booted deployment →
  staged and waiting for a reboot.
- The `*` marks what you are **running right now**. If the package version you expect is only on the
  staged line, you have not rebooted into it yet.
- No staged line and the version you wanted is absent → it never landed, or it was lost. Re-run the
  install.

To check a specific package against what is actually booted:

```bash
rpm -q <package-name>          # what the BOOTED deployment has
rpm-ostree db diff             # booted vs staged, if anything is staged
```

## It is the deployment that is staged, not the package

This is the part most worth being clear about, because it is easy to assume otherwise.

`ostree-finalize-staged.service` is **part of the host OS, not part of any package here.** No
package in this project references it, requires it, ships a drop-in for it, or can opt in or out of
it. Nothing a package author does changes any of the above.

What is staged is the **whole deployment** — one complete filesystem tree containing every layered
package. So:

- Every `rpm-ostree install`, `uninstall`, `upgrade` or `override` produces **one** staged
  deployment.
- Everything you changed in that one command shares a single fate. If it is lost, all of it is lost
  together; if it applies, all of it applies together.
- This is identical for all of this project's packages and for any other package you layer. There is
  no per-package behaviour to learn.

If you install several things in one command, that is one deployment and one reboot. If you install
them in three commands, each one supersedes the last staged deployment — still one reboot, and the
last command's view is what you get.

## Replacing a package you installed from a local file

If you installed a package from an `.rpm` file and later want to install a newer build of the same
package from another file, the obvious command fails:

```console
$ sudo rpm-ostree install ./waydroid-ext-example-1.1.0-1.x86_64.rpm
error: Could not depsolve transaction; 1 problem detected:
 Problem: cannot install both waydroid-ext-example-1.1.0-1.x86_64 from @commandline
          and waydroid-ext-example-1.0.1-1.x86_64 from @commandline
  - conflicting requests
```

This is not a broken package. A locally-installed file stays a `@commandline` request forever, so
asking for a second version of the same name asks for both at once. Do the removal and the
installation as **one** transaction:

```bash
sudo rpm-ostree uninstall waydroid-ext-example \
     --install ./waydroid-ext-example-1.1.0-1.x86_64.rpm
```

One transaction matters for more than tidiness: anything that `Requires` the package is never left
unsatisfied, and you get one staged deployment and one reboot instead of two.

Packages installed from a repository upgrade normally and need none of this.

## Expect the package count to be large, and do not be alarmed

Adding or replacing one local package re-resolves the entire layer, so `rpm-ostree` will report a
number far larger than what you asked for:

```
Installing 191 packages:
  ...
```

That is the full layered set being re-composed, not 191 new things. To see what actually **changes**,
ignore that number and read the summary at the end, or ask directly:

```bash
rpm-ostree db diff
```

```
Upgraded:
  waydroid-ext-example 1.0.1-1 -> 1.1.0-1
```

One caveat worth knowing before you reboot: because the whole layer is re-resolved, repository
packages you have layered can be pulled to newer versions at the same time, even though you only
asked for one local file. `rpm-ostree db diff` is how you find out whether that happened, and it is
worth a look if a kernel or graphics package appears in it.

## What none of this protects you from

**A hand-placed file in `/etc` or `/usr/local` wins over the packaged one, silently.** This is a
different problem from staging and it bites in the same way — you install something, reboot, and
still run the old code.

systemd gives `/etc/systemd/system/` priority over `/usr/lib/systemd/system/`. So a unit you (or an
older install script) put in `/etc` **shadows** the packaged unit completely, and if that unit
executes something out of `/usr/local/bin`, the packaged binary in `/usr/bin` is never run. The
package is installed, `rpm -q` confirms it, and none of it is in use.

To check whether a service is running what you think:

```bash
systemctl show -p FragmentPath <unit>      # which unit file actually won
systemctl show -p ExecStart <unit>         # which binary it launches
sudo readlink /proc/$(systemctl show -p MainPID --value <unit>)/exe
```

If `FragmentPath` is under `/etc` or `ExecStart` points into `/usr/local`, you are running a
hand-placed copy. Removing it hands control back to the package — but read what you are removing
first, in case it differs from the packaged version by more than a path.

**A package's `%post` script may legitimately do nothing.** On `rpm-ostree`, scriptlets run against
the compose rather than against your running system, so anything that reloads a daemon, loads a
kernel module or writes to `/sys` cannot take effect at install time. Packages here are written not
to depend on that, which is why a reboot is the documented way to apply a change.

## Undoing a deployment

```bash
sudo rpm-ostree rollback     # go back to the previous deployment at next boot
sudo rpm-ostree status       # confirm which one is marked for next boot
```

Rollback is itself staged, so it needs a reboot too — and the same shutdown caveat applies to it.
