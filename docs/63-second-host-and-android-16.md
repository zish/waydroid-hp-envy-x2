# 63 — A second host, and what Android 16 would cost

> **Superseded in part, 2026-10-08.** The ATV track moved to **`vidiot01`**, not the Dell. See
> [64-vidiot01-atv-host.md](64-vidiot01-atv-host.md) for that host as *measured*, and for the two
> questions this note left open — `sensord` and `wifid` against A16 — both of which are now
> **answered** from the image. The package-portability verdict below still stands; three specific
> claims do not, and each is annotated inline.

*2026-10-06. The owner asked how much of this project can be moved onto a newer laptop running
"the latest Waydroid", and then whether [WayDroid-ATV](https://github.com/WayDroid-ATV/waydroid-builds)'s
Android 16 images are worth chasing on it. The first answer is better than expected and for an
unexpected reason: **1.6.3 is the latest Waydroid**, so there is no version gap to cross. The
second is a real trade rather than an upgrade — Android 16 keeps the thirteen host-side packages
and voids most of the Android-side half.*

## One-paragraph summary

**22 of the 25 built packages move to a second x86_64 Fedora host, 16 of them unchanged** — 23 of
26 and 17 unchanged since `mdns` was packaged on 2026-10-06, counted on the same evidence rather
than re-measured on the second host, which still has nothing from this project on it. The
reason is that the thing a port would have had to chase does not exist: Waydroid's newest release
is **1.6.3, published 2026-05-28**, which is what bigtab01 already runs, and `main` is only seven
commits ahead of it with exactly one that touches a MAINLINE x86_64 host. The real coupling was
never to Waydroid's version — it is to **one specific Android image build**, and it lands on
exactly three packages: `battery` and `camera-hal` carry `derive` rows pinned to a stock sha256
*and byte offsets*, and `camera-gbm` ships a wrapper built against the same image. Everything else
is either host-side and image-agnostic, or a text file whose replacement survives an image change
as a merge rather than a cliff. The second host — a Dell Inspiron, Comet Lake-U, Fedora Silverblue
44 — is a **better** target than bigtab01 in two ways: its images will live somewhere
`waydroid upgrade` is willing to touch, and Silverblue is the rpm-ostree case this project's
packaging was designed around from the start. *(Both of those two ways are specific to the Dell and
**neither holds on `vidiot01`**, which is where the work actually went — see
[64](64-vidiot01-atv-host.md). It is still easier than bigtab01, for a different reason: it is a
traditional dnf host, so nothing needs a reboot.)* Android 16 is where it gets expensive, and the
expense is not the CPU.

## What "the latest Waydroid" turned out to mean

Checked 2026-10-06, against the GitHub API rather than against a mirror or a distro:

| | |
|---|---|
| Newest release | **1.6.3**, tag `1.6.3`, published **2026-05-28** |
| What bigtab01 runs | 1.6.3 ([docs/00](00-host-baseline.md)) |
| `main` ahead of the tag by | **7 commits** |
| Mainline default image | still LineageOS 20 / Android 13 |

So the premise of the question dissolves. There is no newer Waydroid to port to, and
**no `.mod` file in this repository declares a Waydroid version bound** — which cuts both ways: no
package will refuse on a newer host, and nothing gatekeeps a breaking change either.

Of the seven commits on `main`, one matters here and one is a trap:

- **`lxc: Fix post-stop hook erroring on every container stop`** — a real fix, in the area
  [docs/23](23-graceful-shutdown.md) and [docs/26](26-upstream-container-stop.md) live in. Worth
  having.
- **`Detect AIDL gralloc5`** ([PR #2218](https://github.com/waydroid/waydroid/pull/2218)) reads
  like exactly what an Android 16 image would need, and **is disabled for us.** The patch is 12
  added lines in `tools/helpers/lxc.py` and it opens:

  ```python
  def find_aidl(intf):
      if args.vendor_type == "MAINLINE":
          return False
  ```

  bigtab01 is MAINLINE and so is every ATV x86_64 image. The function returns before it looks at
  anything. **Read the diff before recommending a version bump on the strength of a commit
  message** — this one would have sent somebody building Waydroid from git for nothing.

The remaining five are Mali property forwarding, Halium 15+ version detection, Russian
translations, and a `KeyboardInterrupt` traceback. None applies.

One seam worth re-confirming while in there, because `sensord` is built on it: `container_manager.py`
on `main` **still** starts `waydroid-sensord` from `PATH` and still `pidof`s it to stop it. The
design [docs/14](14-sensors.md) depends on has not moved.

Our own [#2435](https://github.com/waydroid/waydroid/pull/2435) is still **open and unreviewed**, so
nothing we submitted upstream has landed in a release. `restartd` and `graceful-exit` remain
load-bearing rather than redundant.

## Porting the 25 packages

Measured from `packaging/mods/*.mod` and from `build/rpm/RPMS/` (46 rpm files, 25 distinct packages
at their newest versions), not from the design notes — [docs/53](53-release-readiness.md) is blunt
about why that distinction matters.

**`mdns` 1.0.0 joins the list on 2026-10-06, in the unchanged group**, which makes it 26 packages
and 17 unchanged. It names no hardware, no CPU and no interface: the firewalld zone comes from
`firewall-cmd --get-default-zone` rather than being hardcoded to `public`, and the service filter
list is `%config(noreplace)`. Its one target assumption is an avahi that knows `reflect-filters`,
which the reconciler checks by grepping the daemon binary and refuses to proceed without — Fedora
44 ships the same `0.9~rc2` as bigtab01, so it holds, and on a host where it does not the package
declines rather than taking that host's mDNS down. What is *not* portable is the usefulness: the
reflector only has something to reflect if there is a print server or a Chromecast on that LAN.

**Installs unchanged — 16.** No image coupling, no hardware named, no per-machine value:
`overlay-sync` 1.1.0 (first, since every overlay component hard-requires it), `binder-nice`,
`pidguard`, `restartd`, `media`, `btd` 1.1.0, `pwd` 1.3.0, `android-power`, `graceful-exit`, `cage`,
`backlight` 1.0.3, `appfuse`, `wifi-sync` 1.1.0, `wifi-framework`, `brightness-overlay` 1.0.1,
`camera` (group) — and, from 2026-10-06, `mdns` 1.0.0, making **17**.

**Installs, needs one thing — 3.**

| Package | What |
|---|---|
| `wifid` 1.1.0 | [`artifacts/wifi/waydroid-wifid.conf`](../artifacts/wifi/waydroid-wifid.conf) ships `--device 60:57:18:0A:E8:B7`, which is *this* machine's radio. It is `%config(noreplace)`, and the daemon treats a `--device` it cannot resolve as **fatal rather than falling back** — deliberately ([docs/38](38-wifi-primary-radio.md)) — so on another host Wi-Fi is simply down until the new `PermHwAddress` is written there |
| `sensord` 1.0.1 | Needs an IIO sensor hub present. It is **not** ITE8350-specific: [sensors/SensorIIO.cpp](../sensors/SensorIIO.cpp) resolves `accel_3d`, `gyro_3d`, `magn_3d` and `dev_rotation`, which are the generic `hid-sensor-hub` names. A host without a hub gets nothing, not a crash |
| `wifi-hostd` 1.0.1 | Replaces `wificond.rc`. Text, so an image change is a merge question |

**Image-pinned — 3. This is the whole fragile surface.**

| Package | The pin | Failure mode |
|---|---|---|
| `battery` 2.0.0 | `derive`: stock `de3cf6bc…` → `a8401c14…`, offsets `6720`, `6730`–`6732`, `cbd1` | Hash mismatch → the reconciler **refuses silently**, the overlay file is simply absent, and Android is back to a hardcoded 85% with nothing failing loudly |
| `camera-hal` 2.0.0 | `derive`: stock `95b1b3e4…`, offset `2c061` | Same |
| `camera-gbm` 1.0.1 | Ships a prebuilt NDK wrapper; stock tripwire hashes `03dc230b…` / `55eee0b4…` | Loads, but against an image it was not built for |

`waydroid-overlay-sync --check-upstream` exists for precisely this and is the pre-flight on any new
host. The cheap way to make it a non-question is to copy bigtab01's own `system.img`/`vendor.img`
across, at which point all 23 apply verbatim.

**Do not install — 3.** `hw-ite8350` and `hw-envyx2` name this laptop (and are only *inert*
elsewhere since 1.0.1 — 1.0.0 failed its resume unit about 11 s after every resume on a box with no
hub, which is the bug a metapackage spreads). `dexopt` is built and deliberately unshipped; its
`0,2` CPU set is Broadwell-shaped anyway.

**What does not come along at all:** the four Widevine overlay files (licensing — the fetcher was
never written), `graceful-shutdown`, ~~`mdns`~~ — **packaged 2026-10-06**, so it now comes along
and is in fact one of the more portable ones, since nothing in it names this laptop and the
firewalld zone is derived from `--get-default-zone` rather than hardcoded — the `lxc.net.0.name`
edit, `tools`, six of the seven groups, and all four APKs. So `media`, `btd` and `pwd` would install their daemons with no app to
drive them. Also **`media.mod` is at 1.1.0 and only `media-1.0.0` is built** — rebuild before
copying anything.

Two structural limits found while counting:

- **All 25 are RPMs and there are no deb templates.** `packaging/templates/` holds `rpm.spec.in`
  and nothing else, so [docs/47](47-package-split.md)'s Debian roadmap is design-only. A non-RPM
  host gets no packaging at all.
- `backlight`, `appfuse` and `wifid`'s `SELinuxContext=` assume Fedora's SELinux policy.

And one piece of good news that had been recorded pessimistically: **the shipped payload contains no
hardcoded username or uid.** The two greps that hit — `jmelanso` in `waydroid-cage-session`,
`uid=1000` in `waydroid-pwd` — are both inside comments. [docs/53](53-release-readiness.md)'s five
path exceptions are all in *build* scripts, none of which a package installs.

## The second host, as measured

Reported by the owner, 2026-10-06:

| | |
|---|---|
| Machine | Dell Inspiron, 16 GB RAM |
| OS | **Fedora Silverblue 44**, GNOME (default session) |
| Waydroid | **1.6.3** — already meets ATV's stated minimum |
| GPU | `00:02.0 VGA compatible controller [0300]: Intel Corporation CometLake-U GT2 [UHD Graphics] [8086:9b41] (rev 02)` |

Two ways this host is **easier** than bigtab01, both worth knowing before anyone assumes it is
merely "the same but newer":

- **Image upgrades will work there.** *(Void on `vidiot01` — see [64](64-vidiot01-atv-host.md). This was a property of where a fresh `init` lands images, and the owner deployed to `/etc/waydroid-extra/images`, which **is** a preinstalled path, so `waydroid upgrade` refuses there exactly as on bigtab01.)* Waydroid's defaults are
  `images_path = /var/lib/waydroid/images` and
  `preinstalled_images_paths = ["/etc/waydroid-extra/images", "/usr/share/waydroid-extra/images"]`.
  bigtab01's images sit in the second of those, which is why the upgrader refuses by design and why
  [docs/25](25-waydroid-in-cage.md) records an image swap there as a manual operation. A fresh
  `waydroid init -f` on the Dell lands in `/var/lib/waydroid/images`, which is not preinstalled, so
  `waydroid upgrade` is available.
- **Silverblue is the case the packaging was built for.** *(Not applicable to `vidiot01`, which is traditional Fedora 43 Workstation — strictly easier, since installs need no `rpm-ostree` round-trip and no reboot. [47](47-package-split.md)'s scriptlet ban remains a portability rule worth keeping.)* [docs/47](47-package-split.md) forbids
  load-bearing scriptlets precisely because rpm-ostree runs them against the compose rather than the
  booted system, and [docs/user/ostree.md](user/ostree.md) already exists. 16 GB against bigtab01's
  8 is not a factor in anything measured here.

## App mode, not kiosk — a standing constraint from 2026-10-07

**The owner will run Waydroid as an app from a normal GNOME session on the Dell, not as the
session.** Stated as a requirement rather than a preference: compatibility with app mode is to be
maintained from here on, which makes any package that only makes sense when Android *is* the session
opt-in rather than assumed.

What that changes, read off the payload rather than inferred from the package names:

| Package | App mode on GNOME |
|---|---|
| `cage` | **Do not install.** Its entire payload is a `wayland-sessions` entry and the wrapper behind it, whose purpose is making Android the session |
| `graceful-exit` | **Half of it works, and it is the half that matters.** The sway `bindsym` drop-in is inert — GNOME never reads `/usr/share/sway/config.d`. The user unit does not depend on sway: it is `WantedBy=graphical-session.target` with the work in `ExecStop=`, and GNOME starts and stops that target, so a GNOME logout should still shut Android down rather than SIGKILL it. **Untested on GNOME** — on bigtab01 it is explicitly a backstop that *races* sway's teardown ([docs/24](24-graceful-logout.md)), and whether GNOME gives it a cleaner window is unknown |
| `android-power` | **Compatible, and already guarded.** `waydroid-android-lock` asks `GetSession` for the container state and exits 0 with a message when it is not `RUNNING` — the normal case in app mode with the app not launched. `waydroid-android-key` writes to the guest's `wl_keyboard` FIFO through `/proc/<pid>/root/dev` and never touches the compositor |
| `backlight` | **Expect it to break GNOME's brightness keys.** Do not install it there without testing — see below |
| Everything else | Mode-agnostic |

### The `backlight` prediction, because it would present as an unrelated regression

[`waydroid_backlight.cil`](../artifacts/backlight/waydroid_backlight.cil) gives
`/sys/class/backlight/*/brightness` a private type and then names exactly four domains that may
write it: `waydroid_t`, `udev_t`, `unconfined_t` and `init_t`. **`systemd_logind_t` is not among
them** — and on GNOME the brightness keys go through gnome-settings-daemon to **logind**, not through
the daemon this module was written for.

That is the same shape of regression [docs/42](42-backlight-selinux.md) already paid for once:
granting the private type silently removed `init_t`'s base-policy access to that file, and
`systemd-backlight` then failed on **every boot for a day, 978 times**, leaving the host permanently
`degraded`. The fix was one added `allow` line. If app-mode brightness is wanted on the Dell the same
fix shape applies to `systemd_logind_t`.

**This is read off the policy file, not measured.** The measurement is one keypress on the Dell, and
it should be taken before the module is trusted there.

### One thing app mode makes strictly better: deploying an overlay change

AGENTS.md's procedure — log out of the `waydroid-cage` session at SDDM and log back in — exists
because on bigtab01 the compositor and the Waydroid session are the same thing. In app mode they are
not: GNOME is the compositor and the Waydroid session is a child of it. So `waydroid session stop`
followed by relaunching the app re-runs `mount_rootfs()` and picks up a new overlay file **with no
logout and no greeter**.

The underlying rule is unchanged — the overlay merge and the LXC `config_nodes` entries are read at
*session* start, and `systemctl restart waydroid-container.service` still applies neither — but the
cheap way to restart a session exists there and does not here.

The two scripts that refuse to run without a compositor socket, `bin/camera-test.sh` and
`bin/sensor-hub-reset.sh --restart` (guarded 2026-10-01, commit `f3dbc14`), stay correct in app mode
for a different reason than the one they were written for. The guard tests
`$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`, which on a GNOME desktop exists, so they proceed — and there
`waydroid session stop` costs a relaunch rather than a physical login. Run over ssh to the Dell they
will still refuse, which is over-cautious rather than wrong, and `--force` covers it.

Finally, the `kiosk` group in [docs/47](47-package-split.md) — `cage`, `graceful-exit`,
`graceful-shutdown`, `android-power` — is kiosk-only by name and by content. App mode wants
`android-power`, and probably `graceful-exit`, installed individually. That group is unbuilt, so this
is a note on the design rather than a change to anything shipped.

## Android 16 via WayDroid-ATV

**Nothing in this section was run on our hardware.** It is read off ATV's releases and issue
tracker on 2026-10-06 and is recorded as a starting point for the next session, not as a finding.
ATV's own issue #2, *"System requirements documentation needed"*, is **still open** — there is no
published requirement list, so feasibility here is empirical by construction.

| | |
|---|---|
| Newest ATV release | **20260717**, published 2026-07-19 — LineageOS 23.2, Android 16 QPR2 |
| Stated requirement | *"Requires Waydroid version 1.6.3 or later"* |
| Arch | x86_64 only; no ARM64 images in that release |
| Install | `waydroid init -f -c https://waydroid-atv.github.io/ota/a16-qpr2/system -v https://waydroid-atv.github.io/ota/a16-qpr2/vendor -r lineage -s GAPPS` |
| Required first | `rm -rf ~/.local/share/waydroid && rm -rf /var/lib/waydroid/overlay*` — ATV requires the wipe, not recommends it |

### Is the Gen10 CPU a problem? No, and it is the wrong variable

Comet Lake-U is a Skylake derivative with SSE4.2, AVX2, FMA3, BMI1/2 and AES-NI — x86-64-v3.
Android's x86_64 ABI baseline needs SSSE3, SSE4.1, SSE4.2 and POPCNT. The CPU exceeds it
comfortably and is not implicated in anything in ATV's tracker.

The variable is the **GPU generation**, and `8086:9b41` is Gen9.5 — *older than every Intel GPU
reported against these images*: Alder Lake GT2 (Gen12) in #37, Arc/Xe in #25 and #36, Core Ultra in
#41. Host-side that is the mature end of the stack — Mesa `iris` covers Gen8+ and ANV covers Gen9+ —
so **untested rather than known-bad** is the honest verdict, and it is the one thing the next
session can actually settle.

### The three documented A16 failure modes, and which ones to expect

| Issue | What | Bearing on the Dell |
|---|---|---|
| [#17](https://github.com/WayDroid-ATV/waydroid-builds/issues/17) | A16 boot loop on **Waydroid 1.6.2** with image **20260302** (a *prerelease*). Closed as fixed by 20260717 | **Ruled out** — the Dell is on 1.6.3. But a previous attempt that used 20260302 would have looked exactly like this |
| [#37](https://github.com/WayDroid-ATV/waydroid-builds/issues/37) | `hwcomposer.waydroid.so` crash-loops on Intel iGPU, aborting **`Binder threadpool cannot be shrunk after starting`**, triggered by **DPMS events**. Crashes under **KDE Plasma**; clean under **niri** and **cage**. Fixed in `lineage-23.2-20260803-UNOFFICIAL-waydroid_x86_64.zip`, linked in the thread and **never promoted to a release** | **Expect this.** The mechanism is binder/compositor, not GPU-generation, so being on Gen9.5 buys no exemption. GNOME appears in neither the crashing nor the clean column |
| [#40](https://github.com/WayDroid-ATV/waydroid-builds/issues/40) | "Severely corrupted graphics on Android 16", open, Fedora 44 | **Does not implicate us** — AMD *discrete* RX 9070 XT, and the reporter's **integrated** GPU works correctly |

[#41](https://github.com/WayDroid-ATV/waydroid-builds/issues/41) is the same composer abort as #37,
still open, Intel iGPU under KDE Plasma — which is why #37 being "closed" should not be read as
"solved in a release".

**The GNOME question is the one that is genuinely ours to answer.** Every report names KDE
(crashing) or niri/cage (clean); GNOME is in neither column. GNOME blanks the screen by default, so
the documented trigger is plausibly present — and that makes `idle-delay 0` the cheapest way to
remove a variable before debugging anything harder. This is inference, not measurement.

A convergence worth noting: the compositor that does **not** trigger #37 is **cage**, which is what
[docs/25](25-waydroid-in-cage.md) already puts Waydroid under here, and `waydroid-ext-cage` is
noarch. It would need adapting — bigtab01's session assumes SDDM and the Dell has GDM — but it is a
test vehicle that already exists.

### What Android 16 costs this project

| | On ATV Android 16 |
|---|---|
| The 13 host-side packages | **Carry over.** Image-agnostic by construction |
| `battery`, `camera-hal` | **Void.** Byte offsets into a rebuilt binary mean nothing; the `derive` rows would refuse and the fix would simply be absent |
| `camera-gbm` | **Depends on the gralloc path.** The selection logic read off `lxc.py` sets `ro.hardware.gralloc=gbm` for MAINLINE-with-DRI — the `gbm_mesa` family, which is the path [docs/08](08-camera-fixed.md) fixed, not ATV's `minigbm_intel`. #37's temporary relief was setting `minigbm_gbm_mesa` explicitly. So our wrapper bug may well be *live* on A16, and our fix would need rebuilding against A16's minigbm |
| `sensord`, `wifid` | **Measured 2026-10-08 — see [64](64-vidiot01-atv-host.md): `wifid` is a re-measurement, `sensord` is a rewrite.** The A16 vendor image contains *no* HIDL sensors HAL and declares none, so there is nothing for a HIDL `ISensors@1.0` server to stand in for; `wifid` needs `SM_PROTOCOL` `aidl3`→`aidl6` and its supplicant surface re-extracted against AIDL v4. Original wording follows. **The real risk, and unmeasured.** `sensord` serves HIDL `ISensors@1.0`; `wifid` serves wificond AIDL and supplicant `aidl3` ([docs/31](31-wifi-stage2.md)). Android 16's interface versions have moved and nobody here has checked which the ATV image binds. These are the two features that took longest to build |
| `appfuse` | CIL declares identifiers read out of **Android 13's** vold ([docs/55](55-appfuse.md)). Needs re-measuring |

Stated plainly: Android 16 buys a maintained image, VA-API and current app compatibility, and costs
most of the Android-side half of this project plus the two compiled daemons. That is a decision, not
an upgrade.

## For the next session

The owner is wiping the Dell and fetching the current A16 images. In order:

1. Use **20260717**, not 20260302. If the composer crash appears, the fix is the **20260803**
   unofficial image linked in #37.
2. Wipe first — `~/.local/share/waydroid` and `/var/lib/waydroid/overlay*`. An Android 13 `/data`
   will not boot an A16 image.
3. `gsettings set org.gnome.desktop.session idle-delay 0` before the first boot, to remove #37's
   documented DPMS trigger from the picture.
4. Leave `ro.hardware.gralloc` alone initially — Waydroid picks `gbm` itself on MAINLINE. Only if
   graphics fail, ladder it: `gbm` → `minigbm_gbm_mesa` → `minigbm_intel`.
5. **Record the symptom this time.** The three branches are different problems:
   - *no window at all* → container or binder; `journalctl -u waydroid-container -b`
   - *window that never leaves the boot animation* → most likely the `cgroup:ro` chain from
     [docs/61](61-restartd-breaker-boot-loop.md), which is upstream's LXC config and is **not**
     Android-version-specific. Confirm with
     `waydroid shell -- sh -c 'getprop | grep "init\.svc\." | grep -v running'`; anything `STOPPING`
     is it, and `waydroid-ext-restartd` is noarch
   - *window appears then dies or restarts* → #37, and step 3 is the test
6. If the host is SELinux-enforcing, check `dmesg | grep security_context_str_to_sid` for
   `errno=-22`. A context the host cannot parse never becomes an AVC, so `ausearch` is clean and
   this is the only place it shows ([docs/55](55-appfuse.md)). A newer Android makes this *more*
   likely, not less.

## What this note does not establish

- **Nothing here was run on the Dell.** The previous ATV attempt's symptom was not recorded, which
  is why step 5 exists.
- ~~**Whether `sensord` and `wifid` work against an Android 16 image is unknown**, and it is the
  question that decides whether porting to A16 is worth doing at all.~~ **Answered 2026-10-08 from
  the image itself, in [64](64-vidiot01-atv-host.md): `wifid` is a re-measurement, `sensord` is a
  rewrite.** Neither answer needed a boot.
- Whether the current lineage-20 OTA build still matches our two `derive` rows was not checked —
  ATV's OTA index was reachable but Waydroid's own was not, from here. `--check-upstream` on the
  target answers it in one command and is cheaper than guessing.
