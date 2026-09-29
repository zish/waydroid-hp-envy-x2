# 57 — What to send upstream, in the order worth sending it

*Opened 2026-09-29, at the owner's request, after an inventory of everything this project fixed
that needs none of our APKs.* [docs/09](09-upstream-report.md) tracks the camera report and
[docs/26](26-upstream-container-stop.md) the container-stop patches; this note is the queue above
both of them, and the place to record what has been filed and what came back.

**The filter that produced this list**: a fix belongs here if it is a defect in Waydroid, its
images, or its own packaging, and if reporting it needs none of [bt-app](../bt-app),
[media-app](../media-app), [pw-app](../pw-app) or [sensor-app](../sensor-app). Everything that is
*ours* rather than upstream's — the sensors IIO backend, the Wi-Fi daemon, the `ILight` server,
the removable-media mechanism, mDNS reflection — stays in this project and ships as RPMs and DEBs.
That was decided the same day and is not revisited here.

## The one thing that outranks the whole list

**Answering @overcookedlobster on [waydroid#2339](https://github.com/waydroid/waydroid/issues/2339).**
Drafted in [artifacts/upstream/2339-reply-2.md](../artifacts/upstream/2339-reply-2.md).

Their 2026-09-17 comment proves, with a cleaner probe than ours, the thing
[docs/07](07-phase1-android-mesa.md) measured: the bundled Mesa `libgbm` cannot allocate any YUV
format. They then conclude the R8 fallback cannot carry a camera, and route around it by
transplanting `minigbm_intel` from WayDroid-ATV — which dies in SurfaceFlinger because the image's
Mesa cannot render Intel-allocated buffers.

**We have a working camera on that fallback path.** That is a refutation by measurement, in a
thread with three independent reporters, one of whom is part-way down a dead end. It is worth more
than anything below because it is the only item where somebody outside this project is actively
waiting on an answer.

It also retires a hedge. [docs/09](09-upstream-report.md) held "their deeper cause is identical" as
an *inference* because no other reporter's log carried `Failed to map the buffer`.
@mcarraglia's 2026-06-30 comment carries it, on Raptor Lake with a ProXtend UVC device. **Upgraded
to cross-hardware confirmation.** Note their report reproduces at forced YUYV 640×480, so it is the
zero-layout failure and not rank 6 below.

## In flight

| | What | State |
|---|---|---|
| [minigbm#3](https://github.com/waydroid/android_external_minigbm/issues/3) | the gbm import defect | Open, unlabelled, 2 comments, no maintainer engagement 24 days on. Our 2026-09-27 reply asked the outside reporter for two things — the `.so` hashes and a clamp-free test — and neither has come back |
| container stop | [docs/26](26-upstream-container-stop.md), two patches | **Being submitted as a PR.** Re-verified 2026-09-29: still unclaimed, both patches still apply cleanly to `main` at `c78a305a38a9` |
| [#2389](https://github.com/waydroid/waydroid/pull/2389) review comment | [artifacts/upstream/comment-2389.md](../artifacts/upstream/comment-2389.md) | **Retired.** The PR was closed unmerged 2026-09-26. The observation is kept for if that hardening is re-proposed; the `GetSession` contract it protects is why [docs/25](25-waydroid-in-cage.md)'s wrapper probes `NameHasOwner` |

**#2389's closure is the most useful thing upstream told us this month, and it was four words.**
28 files in one commit, and the entire maintainer review was *"impossible to review"*. Everything
below should be filed as one concern per report, and patched as one concern per commit. Our two
container-stop patches are 12 and 33 lines.

## The queue

Ranked on blast radius × how ready the report is × how likely this maintainer is to take it. The
numbers are the sending order, not an importance score — rank 3 is ahead of rank 4 because it is
one line, not because it matters more than a wrong battery reading.

### 1. `lxc.mount.auto = cgroup:ro` means no Android service can ever restart

[docs/43](43-app-freezer.md), [docs/48](48-battery-frozen-and-netd-stale.md). The widest-reaching
item here. `libprocessgroup` never created the per-process cgroups, so `KillProcessGroup()` signals
nobody, init parks the service in `STOPPING` waiting for a `SIGCHLD` that never comes, and nothing
recovers. Six services were wedged on bigtab01; it cost us Wi-Fi for 38 hours presenting as
"connected, no internet", and it silently wedges `audioserver`, `cameraserver`, `media`, `idmap2d`
and `mediadrm` too. Every Waydroid user has this and almost none know, because the tell —
`init.svc.<name>` — is somewhere nobody looks.

File as a bug with the netd chain as the worked example. **Do not lead with a proposed fix**: the
mount is load-bearing for reasons upstream understands better than we do, and the freezer framing
([docs/43](43-app-freezer.md)) makes it look like a feature request when it is a correctness bug.
Our `artifacts/restartd/` is a mitigation and should be mentioned as one, not offered.

### 2. The 32-bit PID cliff

[docs/51](51-pid-namespace-32bit-cliff.md). Total loss of the device after roughly a day of uptime,
traced end to end from a climbing `pid_max` to a spinning boot animation. Best severity-to-effort
ratio in the list, and [waydroid#2071](https://github.com/waydroid/waydroid/issues/2071) already
exists to attach to — it reports the same failure found through GitLab Runner PID churn and
recommends a host-wide change, where `artifacts/pidguard/` caps the namespace instead. Comment on
2071 rather than opening a second issue.

### 3. `RLIMIT_NICE = 0` drops ~1,028,179 binder priority inheritances a boot

[docs/40](40-binder-nice.md). One line, `LimitNICE=40`, in the packaged
`waydroid-container.service`. About 44 events a second, each one a lost inheritance rather than
merely a log line — which is why the binder debug mask is the one fix that fixes nothing. Measured
~120 messages/minute → 0.

**Send this first regardless of its rank.** One line, one file, a before-and-after measurement, and
no design argument to have. After #2389 it is worth establishing that we submit reviewable patches
before we submit a contentious one.

### 4. The battery, both halves as one report

[docs/10](10-battery-fixed.md), [docs/48](48-battery-frozen-and-netd-stale.md). Every user's
battery reading is a hardcoded lie — `healthd_board_battery_update()` overwrites every field with
85%, 3600 mV, CHARGING, AC+USB online, unconditionally, with no property check and no branch. And
once that is fixed the value latches, because the periodic poll is disabled **twice
independently**: the service's `.rc` carries no `capabilities` line so
`timerfd_create(CLOCK_BOOTTIME_ALARM)` fails `EPERM` against `CapEff: 0`, and `healthd_board_init`
writes a 64-bit `-1` over both `periodic_chores_interval_*`.

**File the halves together.** Fixing either alone changes nothing visible, so splitting them
invites a partial fix that reads as broken. Carry the verification method too — the mechanism, not
the symptom: `/proc/<health-pid>/fdinfo/<timerfd>` from inside the container must show
`clockid: 7` and `it_interval: (60, 0)`. The first fix looked correct until that was read.

Lands in `android_hardware_waydroid` and needs an image rebuild, so it moves on a slower track than
anything in Python or a unit file. That is the only reason it is not rank 1.

### 5. Every stop path is `lxc-stop -k`

[docs/23](23-graceful-shutdown.md). SIGKILL to the whole container; Android is never told, so no
`ACTION_SHUTDOWN`, no PackageManager or settings flush, no `sync()`. Upstream already landed the
guest half in
[android_vendor_waydroid#50](https://github.com/waydroid/android_vendor_waydroid/pull/50), so this
is completing something they started. Good accept odds. Mention that Android's processes live in a
top-level `lxc.payload.waydroid` rather than the service's cgroup, which is what makes host
shutdown worse than it looks.

### 6. The external camera HAL's conversion fails above 1280×720

[docs/11](11-camera-facing.md), `packaging/mods/camera-hal.mod`. The HAL picks the largest
advertised mode, starts 1920×1080@30 MJPG, and fails in conversion — LED on, preview black. In the
conversion path, not hardware-specific.

**Keep it strictly separate from the gbm bug.** `format coversion failed!` has two causes and
@mcarraglia's identical string at 640×480 proves it; conflating them muddies both reports.

### 7. `ANDROID_LENS_FACING` is hardcoded to `EXTERNAL`

[docs/11](11-camera-facing.md). Apps enumerating for a rear camera find none; Google Lens
dereferences the result without a null check and dies during enumeration, before ever issuing a
`CONNECT`. @overcookedlobster independently flagged this on 2026-09-17, so there is momentum.
Propose it as a property, not a constant — on a single-camera device `BACK` and `FRONT` are both
lies and `EXTERNAL` satisfies nothing, which makes it a configuration question.

Their comment names two more edges in the same HAL worth folding in: `kSupportedFourCCs` is only
`{MJPEG, Z16}`, and `kMaxBytesPerPixel` rejects v4l2loopback's stock 4 B/px MJPEG.

### 8. `lxc.net.0.name` is not configurable, and `waydroid upgrade` erases the edit

[docs/34](34-wifi-second-radio.md). Small, concrete, obviously correct, and the one durability hole
left in the Wi-Fi work. Matters to anyone doing anything with the container's network.

### 9. Logout binds the compositor socket by inode

[docs/24](24-graceful-logout.md). `config_session` carries
`lxc.mount.entry = /run/user/1000/wayland-1 run/xdg/wayland-0`; the compositor unlinks the socket
on exit and the container holds the dead inode, so logging back in does not restore Android's
display — only `session stop && session start` does. Compounded by `KillUserProcesses=no`, which
means a session started over ssh is never signalled at all.

File as a diagnosis, not a proposal. The fix is invasive and upstream closed
[#774](https://github.com/waydroid/waydroid/issues/774) with a one-liner.

### 10. The three `dontaudit`/`noaudit` SELinux binder traps

[docs/35](35-wifi-stage5.md), [docs/40](40-binder-nice.md), [docs/42](42-backlight-selinux.md).
`binder { transfer }` denied from `container_runtime_t` so calls carrying no binder succeed while
every callback-passing one fails with a bare `DeadObjectException`; `CAP_SYS_NICE` asked for with
the `noaudit` variant; the backlight write denied with nothing in the log. In all three `ausearch`
is empty, which is what makes them cost days.

Highest value per word for anyone building a host-side HAL, and the least likely to land as a
tracker issue — it is not a bug in Waydroid. **This wants the wiki or a docs PR, not the issue
tracker**, which is why it is last rather than because it matters least.

## Deliberately not in this queue

| | Why |
|---|---|
| Widevine L3 | A recipe for a Google prebuilt, not a patch. Licence question nobody upstream needs |
| Netflix container detection | A finding, and unfixable — the app terminates itself deliberately. [docs/22](22-netflix-container-detection.md). Worth linking when someone asks, not worth filing |
| The Wi-Fi feature XML alone | Shipping it without a wificond behind it leaves Android worse than stock. Upstreamable only as the whole subsystem, which is ours |
| Audio backend selection | Scoped, nothing built, and nothing about audio has been tested on this machine at all. [docs/44](44-audio-alsa-backend.md) |
| Everything under "mechanisms" | Ours. RPMs and DEBs |
