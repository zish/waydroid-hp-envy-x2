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
