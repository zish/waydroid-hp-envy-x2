# 50 — Bluetooth: managing BlueZ from inside Android

*2026-09-21. Built and working end to end, including pairing a real device — a Galaxy S24 Ultra
was paired through the app by the owner the same day.*

Under cage ([docs/25](25-waydroid-in-cage.md)) this machine has no host UI at all. There is no
GNOME Settings, no blueman, no tray — so pairing a headset or replacing the keyboard means
ssh-ing in and running `bluetoothctl`. That is the gap this closes: an Android app that drives
the host's BlueZ, and a host daemon underneath it.

Two pieces:

| | |
|---|---|
| [artifacts/bluetooth/](../artifacts/bluetooth) | `waydroid-btd`, a root Python daemon. D-Bus to BlueZ on one side, newline-delimited JSON over TCP on the other |
| [bt-app/](../bt-app) | "Bluetooth", a dependency-free Kotlin app. No AndroidX, no Compose, no coroutines |

Verify with `bin/bluetooth-test.sh`.

## Android's own Bluetooth is not the route — but not for the reason first recorded

**The first version of this note got the evidence wrong, and the wrong evidence survived into a
draft of AGENTS.md.** It is recorded here rather than quietly fixed, because the mistake is one
that will be made again.

The probe was:

```
pm list packages | grep -i bluetooth   ->  (nothing)
ls /apex | grep -i bluetooth           ->  (nothing)
service list | grep -i bluetooth       ->  bluetooth_manager
```

and it was read as "there is no Bluetooth framework in this image". The second line is a false
negative: **the APEX is called `com.android.btservices`, not anything containing "bluetooth"**,
and it is present. It turned up by accident, in the `BOOTCLASSPATH` that `lxc-attach` prints
when `waydroid shell` runs. Grepping for the obvious word is not the same as looking.

What is actually in this image, checked properly:

| | |
|---|---|
| `com.android.btservices` APEX | **present** — `framework-bluetooth.jar`, `service-bluetooth.jar`, `libbluetooth_jni.so` |
| `android.hardware.bluetooth` feature | **declared**, in `/vendor/etc/permissions/handheld_core_hardware.xml` |
| Bluetooth permissions and split-permissions | **present**, in `platform.xml` |
| `privapp_allowlist_com.android.bluetooth.xml` | **present** — the image expects the app to exist |
| `bt_stack.conf`, `bt_did.conf`, LE audio configs | **present** |
| `BluetoothManagerService` | **running, and trying** — `dumpsys bluetooth_manager` shows `mEnable:true`, `Enabled due to SYSTEM_BOOT`, and then `Bluetooth Service not connected` for the 36 hours since |
| **`Bluetooth.apk` / `com.android.bluetooth`** | **absent.** `find /system /system_ext /product /apex -iname '*Bluetooth*apk'` returns nothing |
| **any vendor Bluetooth HAL** | **absent.** Nothing in `/vendor/bin/hw/` or `/vendor/lib64/hw/` |

So this is not the Wi-Fi situation from [docs/28](28-wifi-feasibility.md), where everything was
present and dormant behind a missing feature XML. Here the feature is *already declared* and the
framework is *already loaded* — and it has been failing to bind to a service that does not exist
since the machine booted. The hole is bigger than a HAL: it is an entire privileged system APK.

**Why that does not change the decision.** Sourcing `com.android.bluetooth` means an AOSP build
matching this image, which is the one thing this project has avoided everywhere —
[docs/08](08-camera-fixed.md) fixed the camera with the NDK precisely to stay out of an AOSP
tree. And even with the APK in place, Android's stack needs an HCI transport: a vendor
`android.hardware.bluetooth` HAL over a real controller. That means handing `hci0` to the
container, which is rejected below, or writing an HCI proxy HAL — far more work than a
management app, and it still takes the radio away from the host at the end of it.

The conclusion survives the correction. The reasoning is different, and better founded.

## Handing the controller to the container was rejected

For the reason [docs/28](28-wifi-feasibility.md) rejected it for Wi-Fi, and which
[docs/34](34-wifi-second-radio.md) then confirmed by buying a second radio: `hci0` is this
machine's only Bluetooth controller and the HP keyboard the owner types on is paired to it.
Giving it to Android costs the host its input device to save almost none of the work. Wi-Fi had
a way out — buy a second radio — and it is available here too, a USB Bluetooth dongle costs
nothing. It does not help: the missing piece above is `Bluetooth.apk`, not a radio, so a second
controller would sit there with no stack to drive it.

## The design

```
    Android                          │  host
                                     │
    ┌───────────────────┐            │   ┌──────────────────┐        ┌──────────┐
    │ Bluetooth (app)   │  TCP/JSON  │   │  waydroid-btd    │ D-Bus  │ bluez    │
    │ lan.syshlt.       │ ──────────►│──►│                  │ ──────►│ hci0     │
    │ bluetooth         │◄────────── │◄──│  org.bluez.Agent1│◄────── │          │
    └───────────────────┘   events   │   └──────────────────┘        └──────────┘
      192.168.240.112               │     192.168.240.1:7712
```

The container reaches the host at the `waydroid0` bridge address, measured at 0.06 ms, and
firewalld already has `waydroid0` in the **`trusted`** zone — the nft ruleset jumps
`iifname "waydroid0"` straight to `*_trusted` — so **no firewall rule was added or needed**.

### Why TCP and not binder

Every other host daemon here ([sensors/](../sensors), [wifi/](../wifi)) speaks libgbinder,
because its client is the Android *framework*, which can only be reached that way. This
daemon's client is an ordinary app, and an ordinary app cannot reach an arbitrary binder name:

- `ServiceManager.getService()` is non-SDK on Android 13;
- the name would need an entry in an overlay `service_contexts`;
- `untrusted_app` would need an SELinux `find` allow rule;
- and [docs/35](35-wifi-stage5.md)'s `dontaudit`ed binder-transfer trap is waiting underneath
  all of it.

A socket costs none of that. It is also testable with `nc` from the host, which binder is not.

### The wire

Newline-delimited JSON, one long-lived connection, commands up and events down. Live push
rather than polling is what makes a scan list and a pairing passkey usable — a 1 s poll on a
passkey prompt is the difference between a dialog and a bug report.

```
→ {"id":2,"cmd":"auth","token":"…"}
← {"id":2,"ok":true,"version":1}
← {"ev":"ready","adapter":{…},"devices":[…]}
→ {"id":4,"cmd":"scan","on":true}
← {"ev":"device","device":{"addr":"16:0C:17:2A:6D:C3","alias":"X6","rssi":-62,…}}
← {"ev":"agent","req":3,"kind":"confirm","passkey":481920,"alias":"WH-1000XM4"}
→ {"id":9,"cmd":"agent-reply","req":3,"accept":true}
```

Commands: `auth`, `ping`, `state`, `power`, `pairable`, `discoverable`, `alias`, `scan`,
`pair`, `cancel-pair`, `connect`, `disconnect`, `trust`, `block`, `rename`, `remove`,
`agent-reply`. Events: `ready`, `reset`, `adapter`, `device`, `device-removed`, `agent`,
`agent-show`, `agent-cancel`.

Property projections are explicit allow-lists in the daemon rather than "send whatever BlueZ
has", so the wire does not change shape when BlueZ adds a property — 5.87 already has several
that exist only on some transports.

### TLS is optional and pinned, not CA-validated

`--tls` generates a self-signed certificate, and the daemon publishes its **SHA-256** alongside
the token. The app trusts exactly that certificate and nothing else. There is no name to verify
on a bridge address and no CA to verify against, so pinning is both simpler and strictly
stronger than trusting an authority that would sign anything. Default is plaintext: on a
trusted-zone bridge with a token, TLS buys confidentiality against something that would already
have to be inside the container.

## The pairing agent is the part that has to be a daemon

Reading BlueZ is easy — `busctl --json` would have done it. Pairing is not, and it is what
forces every structural choice here.

A pairing prompt is BlueZ calling **out** to an `org.bluez.Agent1` object that somebody has
exported and registered. That means the daemon must be a D-Bus **server**, not just a client,
which rules out `busctl` outright and rules out scraping `bluetoothctl` for a worse reason:
`bluetoothctl` registers *its own* agent, so whichever of us BlueZ made default would answer
the prompt — possibly on a terminal nobody is looking at.

The agent is registered with capability **`KeyboardDisplay`**, which is what makes BlueZ choose
numeric comparison ("do both screens show 481920?") for modern devices and fall back to passkey
entry for old ones. `NoInputNoOutput` would pair silently and the app would never get to show
anything, which is the whole point of it existing. `RequestDefaultAgent` is also called, and the
daemon logs it loudly when that fails, because failing it silently means pairing prompts
disappear into somebody else's `bluetoothctl`.

### Pair() cannot be called synchronously

This is the trap that would have cost a session. `Device1.Pair()` blocks until pairing
completes, and the agent callbacks it raises arrive **on the same D-Bus connection**. Call it
synchronously from the main loop and it deadlocks against its own prompt: the reply to
`RequestConfirmation` can never be delivered, because the thread that would deliver it is
blocked inside `Pair()`.

So every device verb — `Pair`, `Connect`, `ConnectProfile`, `Disconnect` — is issued with
`reply_handler`/`error_handler` and answers the client later. The default dbus-python reply
timeout of 25 s is also too short for a device that is asleep; pairing gets 180 s, connecting
60 s.

## Credential delivery: a file, and why that works here

The app is handed everything it needs — address, port, token, and the certificate pin when TLS
is on — as one JSON file dropped into its own app-private directory:

```
~jmelanso/.local/share/waydroid/data/data/lan.syshlt.bluetooth/files/btd.json
```

That works because of a fact worth writing down on its own: **SELinux is `Disabled` inside the
container.** `getenforce` in `waydroid shell` says so. The host labels the whole Waydroid data
tree `data_home_t` uniformly and Android never consults it, so a root-written file there is
readable by the app with nothing to get right — no labelling, no provider, no content URI.

The alternative was the [docs/46](46-removable-media.md) pattern, `am broadcast` into the app.
It is worse here for one reason: a broadcast only lands if the app is running when it is sent,
where a file is still there after a reboot, an app restart or a daemon restart.

Two details that are load-bearing:

- The daemon creates `files/` if Android has not yet (it is created lazily on the first
  `getFilesDir()`) and immediately `chown`s it to the package directory's owner.
  [docs/46](46-removable-media.md) already paid for the version of this bug where a root-owned
  directory left the app unable to write its own files.
- Publication is retried every 30 s rather than done once, so installing the app after the
  daemon is already running works without restarting anything. `bt-app/build.sh --install`
  waits for exactly this.

## The Quick Settings tile

*Added 2026-09-21, at the owner's request: "could we put this app in place of the Bluetooth
option in the pull-down?"*

Yes, and cheaply. The stock `bt` tile is **inert in this image** — `dumpsys bluetooth_manager`
reports `state: OFF, address: null` because there is no `com.android.bluetooth` behind it — so
it is a control that can only fail when tapped. Replacing it costs nothing that works.

### The lever is a setting, not a resource

SystemUI reads the shade's tile list from the secure setting `sysui_qs_tiles`:

```
before  wifi,bt,dnd,flashlight,rotation,battery,airplane,night,screenrecord,reduce_brightness
after   wifi,custom(lan.syshlt.bluetooth/lan.syshlt.bluetooth.BtTileService),dnd,…
```

It is an ordinary writable string, it takes effect live, and **nothing has to be restarted** —
no overlay file, no `waydroid-container` restart, and therefore no drop to the SDDM greeter,
which is the usual price of changing anything inside the image. `bin/bt-tile.sh` does the edit
with `--install` / `--remove` / `--status`, saving the original list to
`/var/lib/waydroid-btd/qs-tiles.orig` once so the revert is exact rather than reconstructed.

The setting lives in Android's own settings database, so it survives reboots and app reinstalls
by itself. It does **not** survive wiping `/data`, and it is not managed by
`waydroid-overlay-sync`, so that script is the only record of the change.

**What it does not do:** removing `bt` hides the stock tile from the shade but leaves it in the
edit-tiles tray underneath, because that tray comes from a SystemUI resource. Making it
genuinely unavailable needs a resource overlay — a great deal of machinery for a dead tile
nobody will go looking for.

### A tile is bound only while you are looking at it

`TileService` gets `onStartListening` when the shade opens and `onStopListening` when it closes.
So the tile connects, reads one `ready` snapshot and disconnects, several times a day, rather
than holding a socket — and it deliberately does **not** scan, since the daemon stops discovery
when the last client leaves, which would be every time the shade closed.

That leaves a few hundred milliseconds with nothing to show, so the last painted state is cached
in `SharedPreferences` and redrawn immediately. Without it every pull-down flashes "unavailable"
first, which reads as broken.

### `cmd statusbar` is how this gets tested without a human

```
cmd statusbar collapse | expand-settings | add-tile | remove-tile | click-tile COMPONENT
```

Two things about it. **`expand-settings` returns 1 if the shade is not collapsed first** — it
looks like a permission failure and is not. And **`click-tile` must not be used here**: our
tile's click toggles the adapter, and powering `hci0` off drops the HP keyboard the owner types
on and the phone paired to it. Binding the tile (`expand-settings`) exercises everything except
the one line that sends `power`.

### The trap: Restricted Networking Mode, and a misdiagnosis

Mid-test the tile stopped reaching the daemon, and logcat showed our process opening sockets on
a doubling backoff — 1 s, 2 s, 4 s, 8 s, 15 s — while the daemon's journal stayed empty. The
network was provably fine: the daemon was listening on `192.168.240.1:7712`, the container could
ping it in 0.09 ms, `waydroid0` was in firewalld's `trusted` zone, and `dumpsys connectivity`
showed a `VALIDATED` default network with the right route.

The cause is device-wide and was not obvious:

```
settings get global restricted_networking_mode   ->  1

UID=10213 blocked_state={blocked=RESTRICTED_MODE,
                         allowed=FOREGROUND|TOP|RESTRICTED_MODE_PERMISSIONS|METERED_FOREGROUND}
```

**Restricted Networking Mode is on**, so this app gets network only while it is foreground. A
foreground `Activity` (`procState=TOP`) connects; a plain backgrounded one does not.

**The first diagnosis was wrong, and is recorded because the wrong answer was plausible.** It
looked like app-standby: the failures began after the app had been backgrounded, and launching
it visibly "fixed" them, with `Firewall rule changed: 10213-standby-default` landing at exactly
that moment. An A/B settled it instead of the story:

| | tile connects? |
|---|---|
| standby bucket 45 (`restricted`), not battery-whitelisted | **yes** |
| standby bucket 45, `deviceidle whitelist +pkg` | yes |

The bucket was never the blocker, so the `deviceidle` whitelist is not needed and was removed
again. What was actually retrying on that backoff was a **backgrounded Activity's** client, not
the tile: SystemUI binding a `TileService` elevates the process state enough to satisfy the
`FOREGROUND|TOP` allowance, which is why the tile works and the background Activity did not.

Two things to carry forward. **Anything here that wants a long-lived background connection will
be blocked** — a plain background service is not an option on this image without turning
Restricted Networking Mode off device-wide, which is the owner's call and not a decision to make
sideways. And the tile now stops any previous client in `onStartListening`: SystemUI is not
obliged to pair that call with an `onStopListening`, and a leaked `BtClient` is precisely
something that would sit in a blocked background process retrying forever.

## Corrections — one assumption that was wrong

**BlueZ is not polkit-gated.** The draft of this daemon carried a comment asserting that
pairing and adapter methods need root via polkit, by analogy with udisks2 in
[docs/46](46-removable-media.md). Checked, and false:

- there is no `org.bluez` polkit action on this host — `/usr/share/polkit-1/actions/` contains
  only `org.blueman.policy`, from a package that is not even in use;
- `/usr/share/dbus-1/system.d/bluetooth.conf` contains
  `<policy context="default"><allow send_destination="org.bluez"/></policy>`, so **any** user
  may power the adapter, scan and pair.

So the daemon runs as root for exactly **one** reason: the connection profile goes into a
directory owned by the Android app's uid and mode 0700. Run it with `--no-profile` and it could
be a `systemd --user` unit. This matters because the wrong reason would have justified the
wrong things later.

A related detail that *is* root-only: `bluetooth.conf` allows `send_interface="org.bluez.Agent1"`
only under `<policy user="root">`. That governs `bluetoothd` (which is root) calling *us*, so it
does not constrain the daemon — but it is the kind of line that looks like a blocker on a first
read.

## Other things ruled out

| | |
|---|---|
| `bluetoothctl`, scraped | a readline UI whose output is not a contract, and it registers a competing agent |
| `busctl --json` | reads fine, but cannot *export* `org.bluez.Agent1`, which is half the job |
| a `systemd --user` unit | not for the polkit reason above, which does not apply — only because of the profile write |
| a new Android Bluetooth HAL | there is no framework above it in this image to consume one |
| bluez-alsa | a different question entirely, already answered in [docs/44](44-audio-alsa-backend.md): WirePlumber holds BlueZ's media endpoint and only one process can |

## Implementation notes worth keeping

- **`dbus.Boolean` subclasses `int` and `dbus.String` subclasses `str`.** The order of the type
  tests in `unwrap()` is load-bearing: check `Boolean` before any integer test or every boolean
  on the wire silently becomes `0`/`1`.
- **PyGObject 3.56 deprecated `GLib.unix_signal_add`** loudly enough to put a warning in the
  journal on every start. Fedora 44 has `GLibUnix.signal_add`; the daemon prefers it and falls
  back.
- **Binding is retried, not required.** `waydroid0` does not exist until
  `waydroid-container.service` has run, so at boot the daemon can easily be up before the
  address it wants. It waits rather than failing the unit, which is why the ordering in the unit
  file is a preference and not a dependency.
- **The app holds no state of its own.** Every view is a rendering of the last snapshot plus the
  events since, and a reconnect throws the lot away and starts from a fresh `ready`. A daemon
  restart, a `bluetoothd` restart and a flapping link therefore all converge without any
  reconciliation code.
- **Writes cannot happen on the UI thread** — Android throws `NetworkOnMainThreadException` for a
  socket write there — hence the separate writer thread draining a queue.

## Verification

```
ssh 10.42.0.137 'sudo sh -s' < bin/bluetooth-test.sh
```

Measured on 2026-09-21 against the real controller (`60:57:18:0A:E8:BB`, Intel 8087:0a2a on USB
`1-4`):

| | |
|---|---|
| unauthenticated command | refused |
| token | accepted, `ready` delivered with the adapter and both paired devices |
| adapter properties | address, alias, powered, discoverable, pairable, UUIDs |
| `alias` write | applied |
| discovery | **11 devices in 12 s**, with names and RSSI |
| already paired, seen correctly | HP Wireless Bluetooth backlit keyboard (connected), Dell PN7522W |
| the app, end to end | launches, renders, and connects **from inside the container** (`client 192.168.240.112:51326 connected`) with nothing in logcat |
| discovery stops with the last client | `last client left; stopped discovery` |
| an unknown address | clean error, no hang |
| an **async** verb (`disconnect`) | replies — which is the proof the `reply_handler` path completes rather than deadlocking, the failure mode described above |
| `trust` round-trip | set, the property change echoed back as a `device` event, restored |
| a stale `agent-reply` | refused, `no pending request 4242` |

The Quick Settings tile, from a cold `am force-stop` with its cache wiped, cycling the shade
three times (`cmd statusbar expand-settings` / `collapse`):

| | |
|---|---|
| shade open | exactly **1** client on port 7712, every cycle |
| shade closed | **0** clients, every cycle — nothing leaks |
| bound by | `com.android.systemui`, one binding |
| painted state | `state=2` (active), subtitle **"2 connected"** — the keyboard and the phone |
| cache after closing | unchanged, *after* the `report()` fix; before it, every close wrote "Host daemon unreachable" and the next pull-down painted it |

TLS was exercised separately, as a second instance on port 7713 while the main daemon was
stopped:

| | |
|---|---|
| self-signed certificate and token | generated on first start into the state directory |
| a plaintext client against the TLS port | refused — `SSL: WRONG_VERSION_NUMBER`, logged and the connection dropped |
| pin published to the app | matches SHA-256 of the served certificate |
| auth and `ready` over TLS | adapter and 11 devices, identical to plaintext |

### The pairing agent, tested without a device

`bin/bluetooth-test.sh` reports the pairing leg SKIPPED, because an agent prompt only exists
when a real device is in pairing mode and somebody is at the screen to answer it —
`bin/brightness-test.sh` has the same shape for the same reason, and a test that needs a human
is better named than faked.

But the *plumbing* underneath it does not need a device. `org.bluez.Agent1` is an ordinary D-Bus
interface on an object we export, so it can be driven directly, exactly as `bluetoothd` would,
touching none of BlueZ's pairing machinery and none of the owner's existing pairings. All five
paths were exercised that way on 2026-09-21:

| called on the agent | app saw | returned to the caller |
|---|---|---|
| `RequestConfirmation`, accepted | `kind=confirm, passkey=481920, alias="Dell PN7522W"` | success |
| `RequestConfirmation`, refused | same | **`org.bluez.Error.Rejected`** — the name BlueZ expects |
| `RequestPasskey`, answered `"042195"` | `kind=passkey` | `uint32 42195` |
| `DisplayPasskey` (one-way) | `ev=agent-show, kind=display-passkey` | returned immediately, as it must |
| `Cancel()` while one was outstanding | `ev=agent-cancel, reason=cancelled` | **`org.bluez.Error.Canceled`** |

Leading zeros in a passkey are display-only: BlueZ's passkey is a number, so `"042195"` is
`42195` on the wire and the app formats it back with `%06d`.

### And then a real device, 2026-09-21

The owner paired a **Galaxy S24 Ultra** through the app. It is the first device ever paired to
this machine through anything other than `bluetoothctl`, and it landed complete:

```json
{ "alias": "Jeremy's S24 Ultra", "addr": "6C:AC:C2:F2:22:FB", "icon": "phone",
  "paired": true, "bonded": true, "connected": true, "trusted": true,
  "battery": 80, "legacy_pairing": false, "services_resolved": true, "uuids": [ … 20 … ] }
```

Three things are worth reading off that:

- **`bonded: true`**, not merely paired — the link key was stored, so it survives a reboot.
- **`legacy_pairing: false`** means Secure Simple Pairing, which is the numeric-comparison flow.
  That is exactly what the `KeyboardDisplay` capability was chosen for, and it means the
  `RequestConfirmation` path — the one tested synthetically above — is the one that actually ran.
- **`battery: 80`** comes from `org.bluez.Battery1`, which the daemon already projects, so the
  app shows the phone's charge with no extra work.

`trusted: true` did not come from here: the daemon never sets `Trusted` by itself, so that flag
was either tapped in the app's device menu or set previously from elsewhere.

One aside for [docs/44](44-audio-alsa-backend.md): the phone advertises `0000110a` (**A2DP Audio
Source**) and `0000111f` (Handsfree Audio Gateway), so bigtab01 is the *sink* of that pair. That
is a phone-to-laptop audio path, and it goes to PipeWire on the host — nothing to do with
Android-in-Waydroid's audio, but it is now one tap away and worth not confusing later.

**This also exposed a real gap, now fixed.** A successful pairing left *nothing* in the journal:
the daemon logged agent timeouts and failures but not requests or answers, so after the fact
there was no way to tell whether the prompt had come from us or from a stray `bluetoothctl`.
It now logs the request, and who accepted or refused it.

**One trap, and it was in the test rather than the daemon.** The first run of the `Cancel()` case
reported `org.freedesktop.DBus.Error.NoReply`, which looks exactly like the daemon failing to
answer. It was not: dbus-python's `SystemBus()` is a **shared singleton**, and the test was making
two *blocking* calls overlap on that one connection — the outstanding `RequestAuthorization` from
a worker thread and `Cancel()` from the main thread. Re-run with
`dbus.SystemBus(private=True)` for the canceller and it returns `org.bluez.Error.Canceled`
correctly. Worth remembering before debugging a daemon that is behaving perfectly.

## Still open

- **Only the numeric-comparison pairing flow has met a real device.** The S24 Ultra used Secure
  Simple Pairing; the passkey-entry and PIN flows that old headsets and car kits use have been
  tested only synthetically. They are the same code path up to the dialog, but the dialog itself
  is different.
- **`remove` has never been run against a real bond**, and `connect`/`disconnect` only on no-op
  and error paths. The async machinery under them is proven, but nothing has been deliberately
  disconnected or forgotten through the app.
- **The controller does not survive s2idle**, and that is not this daemon's fault.
  [docs/27](27-android-power-button.md) records `bluetoothd: Controller resume with wake event
  0x0` and a keyboard that is fully down in s2idle; [docs/17](17-hybrid-sleep.md) records that
  the radio is deliberately rfkill'd across the sync wakes. After a resume the app may show a
  dead adapter until BlueZ recovers. No automatic trigger, same shape as the T3U wedge in
  [docs/35](35-wifi-stage5.md).
- **Audio does not follow.** Pairing a headset through this app connects it *on the host*, where
  PipeWire will route it — and Android's audio reaches PipeWire through the pulse socket
  ([docs/44](44-audio-alsa-backend.md)), so it should follow. Untested, and goal 5 is parked.
- **Input does not need to follow**, and is worth understanding rather than fixing: a Bluetooth
  keyboard or mouse paired on the host arrives as a host evdev device and reaches Android the
  way the built-in keyboard already does.
- **Packaged as `waydroid-ext-btd`** on 2026-09-22 — `packaging/mods/btd.mod`, a full
  `rpmbuild -ba` with no new rpmlint findings. Only the *host* half: the app is deliberately a
  separate modification, since an APK has its own build and release cadence and should not
  reissue the daemon every time it changes. That app modification does not exist yet.
- **No BLE GATT.** The daemon exposes devices, not services. Nothing needs it yet.
