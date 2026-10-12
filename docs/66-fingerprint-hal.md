# 66 — A fingerprint HAL fed by libfprint: Chipsailing on bigtab01, Goodix on vidiot01

**Date:** 2026-10-10. **Status:** feasibility only, nothing deployed, no code written. Opened at the
owner's request as two roadmap items — a HAL for the **Chipsailing CS9711** (`2541:0236`) on
bigtab01's Android 13, and one for the **Shenzhen Goodix** reader (`27c6:538d`) on vidiot01's
Android 16, reusing the libfprint work already done for both.

They are one item. libfprint is already the abstraction over the two readers, so the Android side
cannot tell them apart and should never be written twice — the same relationship `WifiBackend` has
to NetworkManager in [31](31-wifi-stage2.md). That seam is what lets the reader be chosen per host
rather than per Android version, which is exactly what the hardware turned out to require: see
*Where the readers are* below.

Everything measured below was read off both machines and both images on 2026-10-10.

## The short answer

**Yes, and the Android side starts from the best possible position.** On both images the entire
biometric framework is present, running, and serving zero sensors. That is the
[31](31-wifi-stage2.md) stage-0 situation exactly: one overlay XML wakes a dormant framework, and
the first failure after it is informative rather than silent.

**The host side holds the two surprises, one in each direction.** Stock Fedora's libfprint knows
**neither** reader, so the owner's own libfprint work has to be on the host before anything
Android-side can be verified — but that work is a packaging project with CI in which the Goodix fork
already builds and tests, so deploying it is an install rather than a project. The other surprise is
where the readers are: the Goodix is integrated in a personal laptop and cannot move, the Chipsailing
is external USB and can, and **the Android side cannot tell them apart** — so the CS9711 is the
reader for both Waydroid hosts and the A16 half needs no Goodix at all.

## The Android framework is awake and empty — on both images

| | **bigtab01 — A13, SDK 33** | **vidiot01 — A16, SDK 36.1** |
|---|---|---|
| `biometric` (`IBiometricService`) | registered | registered |
| `auth` (`IAuthService`) | registered | registered |
| `lock_settings` | registered | registered |
| `dumpsys biometric` → `Sensors:` | **empty** | **empty** |
| `android.software.secure_lock_screen` | declared | declared |
| `android.hardware.fingerprint` feature | **absent** (of 76 features) | **absent** (of 85) |
| Fingerprint feature XML | **absent** — 22 files in `/system/etc/permissions`, 24 in `/vendor/etc/permissions`, none of them fingerprint | **absent** — 19 and 26 respectively |
| Fingerprint HAL binary | **absent** from `/vendor/bin/hw` (18 services) and `/system/bin/hw` (3) | **absent** from `/vendor/bin/hw` (20 services) and `/system/bin/hw` (2) |
| `…biometrics.fingerprint-V*-ndk.so` in image | **absent** | **absent** |
| `hwservicemanager` / `servicemanager` | both running | both running |
| Lockscreen credential settable | gatekeeper HIDL 1.0 service running | `vendor.gatekeeper_nonsecure` running; `cmd lock_settings get-disabled` → `false` |

**The framework's own code for both dialects is in the image.** Measured by streaming the dex out of
the jars and testing for the interface strings — `unzip -p …/services.jar 'classes*.dex' | grep -ac
<string>`, which is a presence test on binary, not a class census:

| String | A13 `services.jar` | A13 `framework.jar` | A16 `services.jar` | A16 `framework.jar` |
|---|---|---|---|---|
| `android.hardware.biometrics.fingerprint.IFingerprint` (AIDL) | 3 | 0 | 2 | 3 |
| `android/hardware/biometrics/fingerprint/ISession` | 1 | 0 | 1 | 1 |
| `IBiometricsFingerprint` (HIDL) | 4 | 0 | **5** | 0 |
| `onPointerDownWithContext` (AIDL V3+) | 3 | 0 | 1 | 3 |
| `FingerprintService` | 6 | 6 | 5 | 7 |

So **both images carry the AIDL path and the HIDL wrapper**, and `hwservicemanager` is alive on both.
That is more room than expected on A16 and should not be leaned on: HIDL biometrics is deprecated
upstream, the A16 vendor image declares no biometric HAL of any kind, and one AIDL implementation
serves both images. **Write AIDL.** The HIDL residue is worth knowing only as a fallback if the AIDL
path turns out to need something the A13 framework will not give.

**The shortcut everybody reaches for first does not exist here.** AOSP's virtual/example fingerprint
HAL — the one driven by `persist.vendor.fingerprint.virtual.*` properties, which would have been a
near-free seam to drive from the host — is **not in either image**. Neither contains any fingerprint
HAL binary at all. Recorded so nobody spends an afternoon looking for it.

## The host side, and the claim that needed checking

Both hosts run the same stock packages: **libfprint 1.94.100-1**, fprintd 1.94.5 (fc44 on bigtab01,
fc43 on vidiot01, same upstream version). The Fedora changelog shows 1.94.100 as a plain upstream
rebase, August 2026.

**Stock libfprint knows neither reader.** The library's device tables were scanned directly for the
`(product, vendor)` 32-bit pairs, with two known-supported readers as controls:

| Device | Hits in `libfprint-2.so.2` |
|---|---|
| Chipsailing `2541:0236` | **0** |
| Goodix `27c6:538d` | **0** |
| Goodix `27c6:5840` (control) | 1 |
| Elan `04f3:0c4b` (control) | 1 |

The controls land exactly once each, in `pid,vid` order, which is what validates the method. Driver
name strings in that library include Goodix MOC, Synaptics, Focaltech MOC, Realtek MOC, Egis and
Elanmoc — and **no Chipsailing string of any kind**. `fprintd-list` on vidiot01 answers *No devices
available*.

**One false lead, found and worth recording.** `/usr/lib/udev/hwdb.d/60-autosuspend-fingerprint-reader.hwdb`
lists `usb:v2541p0236*` and `usb:v27C6p538D*` — both target readers, by exact ID, on both hosts. It
looks like proof that stock libfprint supports them. It is not: `rpm -qf` says that file belongs to
**`systemd-udev`**, not to libfprint, and it is an autosuspend quirk list covering readers regardless
of whether any Linux driver exists. An early draft of this note had the opposite conclusion from
that file alone.

So the host side of both items depends on the owner's own libfprint work, and
[54](54-no-vendored-binaries.md) settles how it ships regardless: built from source at package time,
never carried here as a binary.

## Where the libfprint work is, and the constraint it carries

`../libfprint-goodix-538d-redhat` (owner, 2026-10-10). It is not a libfprint checkout — it is an
**RPM packaging project with CI**, which is a better starting point than one. Read as of its
`master` tip `a93ea07`:

| | |
|---|---|
| Pinned sources (`upstreams.json`) | **two separate forks** |
| `goodix` | `syshlted/libfprint-goodix-538d` @ `26a8bd3`, from `lbssousa/libfprint`, base **v1.94.100** |
| `cs9711` | `syshlted/libfprint-Chipsailing-CS9711` @ `5b98abc`, from `archeYR/libfprint-CS9711`, base **v1.94.10** |
| Packaged | **Goodix only** — `packaging/libfprint/libfprint.spec`, `Name: libfprint`, `1.94.100-101.goodix538d`, with upstream's test suite run in `%check` against `known-test-failures.txt` |
| CS9711 | source pinned and runnable, **no spec yet** |
| Dev rig | `scripts/fprint-dev.sh NAME {enroll,verify,identify,img-capture}` builds the pinned source in a **rootless podman container** and runs libfprint's own examples against the real sensor, no install and no fprintd; `fprint-timing.sh` reports where a verify spends its time |
| Device access | `packaging/udev/71-libfprint-plus-dev.rules` — `uaccess` for both `27c6:538d` and `2541:0236` |

**The constraint is in the spec's `Name:`.** Both forks are libfprint, so each builds a package that
*replaces* the distro one — which means **one host gets one reader**. That does not touch the
daemon, which stays reader-agnostic because libfprint is, but it does mean a single machine cannot
serve both readers until the two drivers live in one tree. Nothing in this work needs them merged;
it needs the choice made per host and written down.

Two consequences worth having before planning stage 0. The packaged half is **further along than
this note assumed** — the Goodix fork already builds, tests and lints, so "deploy the owner's
libfprint" is an install rather than a project. And the CS9711 half needs **a spec written** in the
same shape, which is a known quantity: one more `%global commit`, one `Source0`, and the release
tag convention already in use. Note also that the dev rig needs **podman**, which the dev box does
not have and cannot get ([06](06-next-session.md)'s dev-box section) — it runs on the Fedora hosts,
both of which have it.

## Where the readers are, and the pairing that follows from it

Measured with `lsusb` and `lsusb -t` on both hosts, 2026-10-10:

| | Attached USB devices |
|---|---|
| **bigtab01** | root hubs, **Yubikey 4/5 U2F** `1050:0402`, Intel Bluetooth `8087:0a2a`, HP TrueVision webcam `064e:c353` |
| **vidiot01** | root hubs, Quanta webcam `0408:a060`, Intel Bluetooth `8087:0aaa`, two USB mass-storage bridges |

No `2541:0236` and no `27c6:538d`, and on vidiot01 no fingerprint device on either root hub at all.
**The owner settled where they are on 2026-10-10: the Goodix is integrated in a personal laptop,
which is neither of these two machines.** An integrated reader does not move, and the Chipsailing
does, which inverts the pairing the two roadmap items started from:

- **The CS9711 is the reader for both Waydroid hosts.** It is external USB, so it can be plugged
  into bigtab01 for the A13 work and into vidiot01 for the A16 work — and because the Android side
  cannot tell the readers apart, **the A16 half needs no Goodix at all.** That removes the only hard
  hardware blocker on this item.
- **The Goodix stays a libfprint-side concern** until Waydroid A16 ever runs on the laptop that has
  it. Its fork is the one that is already packaged, so it keeps earning its keep on the host side
  regardless; it simply is not the reader this HAL gets verified against.

What is still needed before stage 0 is physical: the CS9711 plugged into whichever host is being
worked on. Everything up to the daemon's registration can be built without it; nothing past that can
be trusted without it.

## The shape: a host daemon, as usual

`waydroid-fprintd`, in the mould of `sensors/` and `wifi/`: a host daemon that registers
`android.hardware.biometrics.fingerprint.IFingerprint/default` on `/dev/binder` over libgbinder,
declared through a VINTF fragment in the vendor overlay, with libfprint behind a backend seam. Split
the packaging the way Wi-Fi's is — `waydroid-ext-fprintd` for the daemon,
`waydroid-ext-fingerprint-framework` for the overlay XML and the VINTF fragment — so the framework
half can land and be observed on its own.

Four decisions to take before code, in descending order of how expensive they are to change:

**1. Sensor strength, and the ladder it buys.** `getSensorProps` declares the sensor as
`CONVENIENCE`, `WEAK` or `STRONG`. Only a STRONG sensor can release keystore keys, and only a STRONG
sensor needs a verifiable `HardwareAuthToken`. **Start at CONVENIENCE**: unlock works, nothing
expects crypto, and the auth-token problem below is deferred rather than hit head-on. Promote to
STRONG once [65](65-tpm-keystore.md) stage 5 lands. Verify the strength semantics against this
image's bytecode before relying on the deferral.

**2. The auth-token problem, which is why these two notes reference each other.** A STRONG HAL must
return a `HardwareAuthToken` HMAC'd with the key established through `ISharedSecret` /
`computeSharedHmac`, and only participants in that negotiation can produce one. A16 already runs the
negotiation between `vendor.gatekeeper_nonsecure` and `vendor.keymint-default`
([65](65-tpm-keystore.md)); A13 runs the equivalent inside HIDL keymaster 4.0. **Prediction, to be
tested rather than believed: fingerprint *unlock* will work with an unverifiable token, and
auth-bound keys — anything built with `setUserAuthenticationRequired(true)` — will not.** Test it by
unlocking first and then running one `setUserAuthenticationRequired(true)` key operation in a probe
APK; if the prediction holds, the fix is to own keymint, which is [65](65-tpm-keystore.md).

**3. Who owns the reader: `fprintd` or us.** Going through fprintd's D-Bus API inherits its template
store, its per-user model and its polkit gating, and leaves host login/sudo fingerprint auth
working. Taking the device directly with libfprint gives full control of enrolment and timing and
**takes the reader away from the host's login stack**, which on bigtab01's kiosk may be no loss and
on vidiot01 — a GNOME workstation someone logs into — would be. Default to fprintd and treat direct
libfprint as the fallback if its API cannot express what `ISession` needs.

**4. Match-on-chip versus image matching — and the two readers differ, which the daemon must not.**
Measured from the packaging project: the **CS9711 is an image sensor matched in software**, its fork
pinned to **SIGFM** (SIFT-based) matching in plain C with OpenCV deliberately dropped from the
requirements; the **Goodix 538d is match-on-chip**, templates living on the sensor in a fixed and
small number of slots. So the authoritative template store is in a different place for each, and
`enumerate`, `remove` and `getAuthenticatorId` have to agree with whichever one is in play, with the
Android-user → host-template mapping decided once rather than per call. The CS9711's software
matching also puts the match on the host CPU — on bigtab01 that is a two-core Broadwell, so take
`fprint-timing.sh` numbers on *that* machine before promising a responsive unlock, rather than
numbers from the laptop the driver was developed on.

## Traps that are already paid for, and will still bite

- **The binder `transfer` denial applies here, on both images.** `IFingerprint::createSession()`
  takes an `ISessionCallback` binder from Android *and* returns an `ISession` binder, so binders
  cross in both directions on the very first useful call. That is the permission the host policy
  allows for `call` and denies-and-`dontaudit`s for `transfer`: a bare `DeadObjectException` with a
  clean `ausearch`, which cost [35](35-wifi-stage5.md) a day. Ship `SELinuxContext=` in the unit from
  the first commit, and have the test script check it first, as `bin/wifi-test.sh` does.
- **An overlay file is not deployed until the container *service* restarts** — [32](32-wifi-stage3.md).
  A stage-0 XML can sit there looking deployed and doing nothing for a day.
- **Setting a lockscreen credential changes how the machine comes back.** Android requires a PIN,
  pattern or password before any fingerprint can be enrolled. On bigtab01 that means the kiosk
  session will demand it after every sleep, and [52](52-launcher-lock-and-wake.md) is the record of
  how confusing a locked Android looks there. Decide that with the owner at the machine, not
  remotely.
- **Whether the AIDL path needs a framework resource.** A13's `FingerprintService` reaches HIDL
  sensors through `config_biometric_sensors` in `framework-res`, which would mean an RRO; the AIDL
  path should need nothing but a declared instance. **Pin it from `services.jar` bytecode** with
  [30](30-wifi-aidl-surface.md)'s technique before assuming the cheap answer, because the expensive
  answer is an overlay APK.

## Staging

0. **Host first, no Android.** Write the CS9711 spec in `../libfprint-goodix-538d-redhat` alongside
   the Goodix one, build it, install it on the Waydroid host being worked on, and prove
   enrol-plus-verify — first with `fprint-dev.sh cs9711 enroll` / `verify`, which needs no install at
   all, then through `fprintd` once packaged. Needs the reader plugged into that host. Deliverable: a
   `bin/fprint-test.sh` that names the broken link rather than just failing, in the style of
   `bin/media-test.sh`, plus a `fprint-timing.sh` run on the target machine.
1. **The feature XML alone**, into `artifacts/overlay/system/etc/permissions/`. Expect
   `android.hardware.fingerprint` in `pm list features`, `FingerprintService` to come up, and an
   informative complaint about having no HAL. This is stage 0 of the Wi-Fi work repeated, and it
   costs one file.
2. **Register `IFingerprint` with `getSensorProps` only**, CONVENIENCE strength, no enrolment. Expect
   Settings to show a fingerprint entry and `dumpsys biometric` to list a sensor — the inverse of the
   empty `Sensors:` measured above, which is what makes it a clean A/B.
3. **Enrolment through the backend**, with the user mapping and `getAuthenticatorId` settled.
4. **Authentication**, with a deliberately unverifiable auth token, to measure exactly what that
   costs. Record the answer either way.
5. **STRONG, with a real token**, after [65](65-tpm-keystore.md) stage 5.
6. **The second reader.** If the seam is right this is a package rebuild and no Android-side change.
   If it is not, better to find out here than to have written two HALs.

## Open questions

1. **Which Android version goes first?** A13 on bigtab01 has the stronger reason — a kiosk tablet
   with a lockscreen — and the weaker keystore story; A16 on vidiot01 is the portability target and
   is where the AIDL-only decision is forced. Doing A13 first and porting is the cheaper order;
   doing A16 first proves portability earlier. Either way it is the same reader now.
2. **Do the two forks ever get merged?** Not needed for this work, and the day one host should serve
   both readers it becomes the only way. Worth knowing whether that is on the owner's list, because
   it changes whether the daemon may ever assume one device class per machine.
3. **Does the Goodix reader's host ever run Waydroid?** If that laptop stays a libfprint development
   machine, the Goodix half of this item is complete the moment its fork is packaged — which it
   already is — and there is nothing Android-side left owing on it.
