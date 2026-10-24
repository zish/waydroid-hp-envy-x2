# 64 — vidiot01 becomes the ATV host, and what the A16 image actually contains

*2026-10-08. The owner deployed WayDroid-ATV's Android 16 images to `/etc/waydroid-extra/images` on
`vidiot01` and moved the ATV track there from `jeremy-laptop02`. This note records the new host as
**measured** rather than as reported, the answers to the two questions
[63](63-second-host-and-android-16.md) left open — both answerable by opening the image rather than
by booting it — and then the boot itself: **Android 16 boots on `vidiot01`, and the binder SELinux
module is what makes it boot.** Three pre-flight findings are recorded too, including one of mine
that was wrong in a way worth keeping.*

## One-paragraph summary

`vidiot01` is a materially different machine from the Dell that [63](63-second-host-and-android-16.md)
was written around, and the differences cut both ways: it is **traditional Fedora 43 Workstation, not
Silverblue**, so package installs need no `rpm-ostree` round-trip and scriptlets run against the
booted system — but its images sit in a **preinstalled** path, so `waydroid upgrade` refuses exactly
as it does on bigtab01, and 63's claim that image upgrades would work on the second host **does not
carry over**. It is also not a spare machine: it runs this project's dev container on host
networking *and* the `vidiot` AP that other devices use, so NetworkManager there is off-limits. The
image is confirmed to be the **20260803 unofficial build from ATV issue #37** — the one 63's step 1
names as the fallback — and reading it without booting it settled both open questions. **`sensord`
is the loser: the A16 vendor image contains no HIDL sensors HAL at all**, and the seam
[14](14-sensors.md) is built on is gone image-side. **`wifid` is the survivor, and its one required
change is small**: Waydroid moves `service_manager_protocol` from `aidl3` to `aidl6` at API 36,
`wifi/service.cpp` hardcodes `aidl3`, and the host's libgbinder already implements `aidl6`. As a
bonus, `/vendor/apex/` holds exactly five APEXes which map **one-to-one** onto five of the six
crash-looping services in [`waydroid_binder.cil`](../artifacts/binder/waydroid_binder.cil),
independently corroborating that module's diagnosis from the image side. **And the module is now
verified**: an A/B pair with the host Enforcing throughout gives no boot in 240 s and 657
`spc_t → container_runtime_t` binder denials without it, against `sys.boot_completed` in **18
seconds** and **zero** denials with it. Fedora's own `waydroid` policy module turns out to grant
those binder permissions to three source domains and **not to `spc_t`**, so this is a gap in the
distribution's policy worth sending upstream rather than a local workaround. **The GUI then works
end to end**: the container's hwcomposer is a Wayland client that creates a real `xdg_toplevel`,
Mutter configures it maximised at 1920x1048, and frames are confirmed on screen by
`wp_presentation_feedback` — the one thing that made this look broken for an afternoon was a
blanked laptop panel, which discards every frame while leaving every other signal healthy.

## Why the target moved, and the constraint that comes with it

The owner's decision, 2026-10-08. `jeremy-laptop02` is not retired, but the ATV work happens on
`vidiot01` from here.

**`vidiot01` is not a test bench, and this is a hard constraint rather than a caution.** It is:

- the host running this project's `code-server` container, on **host networking** — the container's
  `127.0.0.1` is the host's, which is how it is reached at all (`ssh vidiot01`, key-based, user
  `jmelanson`); and
- the NetworkManager **`Hotspot1`** profile serving the `vidiot` SSID at `10.42.0.1/24` — the AP
  that [45](45-mdns-reflection.md) documents and that other devices on the LAN are live clients of.

So a NetworkManager change there can drop third-party devices off the air *and* sever the only
access path to the machine, in the same action. Nothing in the ATV work touches `nmcli`, the
`waydroid0` bridge is created with plain `ip link` (below), and the scoped `sudoers` drop-in written
for this work deliberately grants no NetworkManager command and no `setenforce`.

Baseline recorded before anything was changed:

```
Hotspot1:wlp0s20f3:802-11-wireless:activated     10.42.0.1/24
Wired connection 1:enp9s0:802-3-ethernet:activated   10.21.0.213/24
```

## vidiot01, as measured

Everything in this table was read off the machine on 2026-10-08, not reported.

| | |
|---|---|
| OS | **Fedora Linux 43, Workstation Edition** — **traditional, not ostree** (`/ostree` absent, no `rpm-ostree`) |
| Kernel | `7.2.9-100.fc43.x86_64` |
| SELinux | **Enforcing**, policy `targeted`, `deny_unknown` allowed |
| CPU | Intel **Core i5-9300H** (Coffee Lake-H), 8 threads — `sse4_2 ssse3 popcnt avx2 fma aes`, x86-64-v3 |
| RAM | 31 GiB |
| iGPU | `00:02.0` Intel **CoffeeLake-H GT2 [UHD Graphics 630]**, `8086:3e9b` — **Gen9.5**, `i915` |
| dGPU | `01:00.0` NVIDIA **GP107M [GeForce GTX 1050 3 GB Max-Q]**, `10de:1c91`, driver **`nouveau`** |
| Panel | `eDP-1`, on the **Intel** (`card1`) |
| Mesa | `25.3.6-3.fc43` (`mesa-dri-drivers`, `mesa-vulkan-drivers`) |
| Waydroid | `waydroid-1.6.3-1.fc43.noarch` — distro-packaged |
| LXC | `lxc-6.0.6-1.fc43` |
| libgbinder | **`1.1.47-2.fc43`** |
| Desktop | **GNOME Shell on Wayland**, via **GDM** (`gdm-password`), `seat0`, socket `wayland-0`, user `jmelanson` |
| waypipe | `0.10.5`, installed |
| Clock | **EDT**, i.e. UTC−4 — the build container is UTC, so dates here come from the host |
| Prior Waydroid state | **none.** No `/var/lib/waydroid/waydroid.cfg`, no `~/.local/share/waydroid`, no `/var/lib/waydroid/overlay*` |
| `waydroid-container.service` | `enabled` and `active` — but with no `waydroid.cfg` it has nothing to start |

**ATV's required wipe is therefore already satisfied**, not by wiping but by never having been
initialised: 63's step 2 (`rm -rf ~/.local/share/waydroid`, `/var/lib/waydroid/overlay*`) is a no-op
here. There is no Android 13 `/data` to refuse to boot an A16 image.

GNOME-on-Wayland is the one thing that carries over from the Dell unchanged, which means the
**app-mode constraint recorded on 2026-10-07 stays exactly as written** — `cage` stays opt-in, the
`backlight` prediction about `systemd_logind_t` and GNOME's brightness keys is still live and still
unmeasured, and `waydroid session stop` + relaunch remains the cheap overlay-deploy path with no
greeter in it.

## What changes versus the Dell, and what does not

| | Dell (`jeremy-laptop02`, per 63) | `vidiot01` (measured) |
|---|---|---|
| OS | Fedora **Silverblue 44**, rpm-ostree | Fedora **43 Workstation**, traditional |
| Package iteration | Layered install + **reboot** | `dnf`, scriptlets run against the booted system, **no reboot** |
| `waydroid upgrade` | **Available** — fresh init lands in `/var/lib/waydroid/images` | **Refused** — images are in a preinstalled path |
| iGPU | CometLake-U GT2 `8086:9b41`, Gen9.5 | CoffeeLake-H GT2 `8086:3e9b`, **Gen9.5** |
| Discrete GPU | none | **GTX 1050 Max-Q on nouveau** |
| RAM | 16 GB | 31 GiB |
| Desktop | GNOME / GDM | **GNOME / GDM** |
| SELinux | Enforcing | **Enforcing** |
| Waydroid | 1.6.3 | 1.6.3 |
| Is the machine expendable? | yes | **no** — dev container host and live AP |

The **GPU generation question 63 raised is unchanged**: Gen9.5 is still older than every Intel GPU
in ATV's tracker (Gen12 in #37, Xe in #25/#36, Core Ultra in #41), and still *untested rather than
known-bad*. Swapping Comet Lake-U for Coffee Lake-H moves nothing — both are Gen9.5.

**Two of 63's "easier than bigtab01" claims need splitting.** The rpm-ostree one was about Silverblue
and is simply replaced by something better here (a traditional host is faster to iterate on, and
[47](47-package-split.md)'s ban on load-bearing scriptlets is a *portability* rule that costs
nothing to keep). The image-upgrade one was about where a *fresh init* lands images, and the owner
deployed to `/etc/waydroid-extra/images` instead, so it is void — see below.

## Three pre-flight findings

Each of these would have presented as a boot failure and cost a cycle to attribute.

### 1. ~~`waydroid0` does not exist, and nothing on this host creates it~~ — WRONG, corrected 2026-10-08

> **This finding was wrong, and the correction matters more than the finding did.** Waydroid
> *does* create the bridge, in **`/usr/lib/waydroid/data/scripts/waydroid-net.sh`**, which also
> sets `net.ipv4.ip_forward=1`, runs `firewall-cmd --zone=trusted --add-interface=waydroid0`,
> installs nft tables `inet lxc` / `ip lxc` with a **MASQUERADE** rule for `192.168.240.0/24`, and
> starts a **dnsmasq** DHCP server on `192.168.240.1`. The claim below that "Waydroid's own Python
> has no `iptables`/`nft`/bridge code at all" is true and irrelevant: the grep behind it was
> `--include=*.py`, and the networking lives in a **shell script**. Creating the bridge by hand
> first is harmless but pointless — `waydroid-net.sh` calls `stop force` on an existing
> `waydroid0`, deletes it, and recreates it.
>
> **Measured effect on the AP, after two boots:** none. `Hotspot1` stayed `activated` throughout,
> `10.42.0.1/24` is still on `wlp0s20f3`, its own dnsmasq is still running, the `vidiot` SSID is
> still beaconing in AP mode with **5 stations associated**, and firewalld kept `wlp0s20f3` in
> `nm-shared` while `waydroid0` went to `trusted`. The nft tables are disjoint —
> `nm-shared-wlp0s20f3` versus `lxc` — and `waydroid-net.sh` only ever flushes tables it named
> `lxc` itself. `ip_forward` was already `1`, because NetworkManager's shared mode needs it.
>
> So the coexistence is real, but it is **coexistence, not abstention**, and it should have been
> established by reading `waydroid-net.sh` before the first boot rather than by inspecting the
> damage afterwards. The original text follows.



The LXC template Waydroid will install, `/usr/lib/waydroid/data/configs/config_3`, hardcodes:

```
lxc.net.0.type = veth
lxc.net.0.link = waydroid0
```

On `vidiot01`: `ip link show waydroid0` → *does not exist*; there is no NetworkManager profile
mentioning waydroid; and `rpm -ql waydroid` ships **no** network unit, `.nmconnection`, or dnsmasq
config — only `waydroid-container.service` and `dev-binderfs.mount`. Waydroid's own Python has no
`iptables`/`nft`/bridge code at all. So **container start will fail to attach the veth** until the
bridge exists.

The safe way to create it, given the AP constraint, is a plain kernel bridge:

```
sudo ip link add waydroid0 type bridge
sudo ip link set waydroid0 up
```

NetworkManager sees that as *externally managed* — exactly how `docker0` and `br-c894cdd91d45`
already appear in `nmcli device status` — so **no connection profile is created, modified or
activated**, and `Hotspot1` is untouched. Android gets a bridge with no upstream and therefore no
internet, which is irrelevant to whether `sys.boot_completed` is ever set. Giving Android real
connectivity would mean NAT and a DHCP server on this host, and that is explicitly **not** being
done here.

> **Both of those last two sentences are wrong, corrected 2026-10-08.** NetworkManager *does*
> generate a profile for the bridge once it carries an address — `waydroid0`, `ipv4.method=manual`,
> `192.168.240.1/24`. It is written to **`/run/NetworkManager/system-connections/`**, i.e. runtime
> only: `/etc/NetworkManager/system-connections/` is unchanged and still holds exactly the six
> profiles it held before, so nothing survives a reboot and `Hotspot1` is not touched. And Android
> *does* get NAT and DHCP, because `waydroid-net.sh` sets both up — see the correction above. The
> safety conclusion holds; the mechanism described here did not.

### 2. The images are in a preinstalled path, so `waydroid upgrade` is refused

`tools/config/__init__.py` defines:

```python
"preinstalled_images_paths": [
    "/etc/waydroid-extra/images",
    "/usr/share/waydroid-extra/images",
],
```

`/etc/waydroid-extra/images` is the **first** entry, so `waydroid init` will find `system.img` and
`vendor.img` there, set `images_path` to it, set `system_ota`/`vendor_ota` to `None`, and **return
before any download** (`tools/actions/initializer.py`). That is what the owner wanted: init consumes
the deployed images rather than fetching ATV's OTA.

The cost is the same one bigtab01 pays. `tools/actions/upgrader.py`:

```python
if args.images_path not in tools.config.defaults["preinstalled_images_paths"]:
    helpers.images.get(args)
else:
    logging.info("Upgrade refused because Waydroid was configured to load pre-installed image from {}.")
```

and `tools/helpers/lxc.py` additionally sets `waydroid.updater.disabled=true`. So **63's "image
upgrades will work there" is void on `vidiot01`** — it was a property of a fresh init landing in
`/var/lib/waydroid/images`, not of the host. An image swap here is a manual file operation, as
[25](25-waydroid-in-cage.md) records for bigtab01. Moving the images to `/var/lib/waydroid/images`
and initialising from a channel would restore `waydroid upgrade`, at the cost of a download and of
discarding the specific 20260803 build — not obviously worth it.

### 3. The hybrid GPU does not bite, but only by PCI luck

The card numbering here is **inverted** relative to the usual assumption:

```
card0 -> DRIVER=nouveau  PCI_ID=10DE:1C91     (discrete, no panel)
card1 -> DRIVER=i915     PCI_ID=8086:3E9B     (integrated, drives eDP-1)
renderD128 -> pci-0000:00:02.0  (Intel)
renderD129 -> pci-0000:01:00.0  (NVIDIA)
```

A naive "use `card0`" would select the **discrete nouveau GPU that drives no display**. Waydroid
does not do that. `tools/helpers/gpu.py`:

```python
unsupported = ["nvidia"]
...
for node in sorted(glob.glob("/dev/dri/renderD*")):
    renderDev = os.path.basename(node)
    if getKernelDriver(args, renderDev) not in unsupported:
        return node, getCardFromRender(args, renderDev)
```

It iterates **`renderD*`**, which follows PCI order, so `renderD128` (Intel) is tried first; `i915`
is not in `unsupported`; and `getCardFromRender` then derives the card from **that same PCI device**,
yielding `card1`. So Waydroid selects the Intel for both the render node and the card, and
`gralloc.gbm.device=/dev/dri/renderD128`.

Two caveats worth keeping. **`unsupported` lists only `"nvidia"`, the proprietary driver — `nouveau`
is not excluded**, so if PCI enumeration ever put the NVIDIA first, Waydroid would pick it without
complaint. And `getVulkanDriver` tries to read Gen from
`/sys/kernel/debug/dri/<minor>/i915_capabilities`, which needs root and is wrapped in
`suppress(Exception)`; on failure it falls through to the `i915 -> "intel"` mapping, which is the
right answer for Gen9.5 either way. **The escape hatch, if any of this misfires, is the
`drm_device` key in `waydroid.cfg`**, which `getDriNode` honours ahead of the scan. This is read off
the code; it should be confirmed against the props Waydroid actually generates once init has run.

## The image, opened without booting it

`vendor.img` is ext2 and world-readable, so `debugfs` reads it directly, as a normal user, without
mounting anything. `system.img` is EROFS and **`erofs-utils` is not installed**, so system-side
claims below rest on `strings` rather than extraction.

| | |
|---|---|
| `ro.build.fingerprint` | `google/tangorpro/tangorpro:16/BP4A.260205.001/14624666:user/release-keys` |
| `ro.build.version.sdk` | **36** |
| `ro.build.version.release` | **16** |
| `ro.lineage.version` | **`23.2-20260803-UNOFFICIAL-WayDroidATV-waydroid_x86_64`** |
| `system.img` | EROFS, 1 806 557 184 B, `sha256 6daddfb8151b9802503e81da749de579e827c0350a8010549587a6f623360694` |
| `vendor.img` | ext2, 729 079 808 B, `sha256 4825610d83b30184879c8741706bb9e850af50468c8436949c9d9ee3ccebfa8b` |
| VINTF target level | **7** (`manifest_waydroid.xml`, `type="device"`) |

**This is the 20260803 build**, which is the image ATV issue #37 links as the fix for the
`hwcomposer.waydroid.so` / `Binder threadpool cannot be shrunk after starting` composer crash and
which was **never promoted to a release**. 63's step 1 says to start from 20260717 and fall back to
20260803 if the composer crash appears; the owner has started from the fallback, so **that failure
mode should be absent from the outset** and its appearance would be news.

It is also the exact image named in
[`waydroid_binder.cil`](../artifacts/binder/waydroid_binder.cil)'s header, so the binder diagnosis
measured on `jeremy-laptop02` is about *this* build and not a sibling.

### `/vendor/apex/` corroborates the binder diagnosis

`/vendor/apex/` contains exactly five APEXes:

```
com.android.hardware.gatekeeper.nonsecure.apex
com.android.hardware.memtrack.apex
com.android.hardware.security.authgraph.apex
com.android.hardware.security.secretkeeper.apex
com.android.hardware.sensors.apex
```

The binder module records **six** crash-looping services. Five of them map one-to-one onto that
list — `android.hardware.gatekeeper-service.nonsecure`,
`android.hardware.memtrack-service.example`,
`android.hardware.security.authgraph-service.nonsecure`,
`android.hardware.security.secretkeeper-service.nonsecure`, and
`android.hardware.sensors-service.example` — and the sixth, `media.swcodec`, is a system-side APEX.
The image even carries the init line:

```
service vendor.sensors-default /apex/com.android.hardware.sensors/bin/hw/android.hardware.sensors-service.example
```

So "the failing set is exactly the APEX-packaged HAL set" is now supported from **two independent
directions** — host AVCs on one machine, image contents on another. That does not make the module's
rule set proven (only a completed boot does that), but it removes the possibility that the six were
an unrelated coincidence.

## The two questions 63 left open, now measured

63 named these as "the real risk, and unmeasured … the question that decides whether porting to A16
is worth doing at all." Both are answered below from the image, without a boot.

### `sensord` — negative, and the reason is structural

| Evidence | Finding |
|---|---|
| `debugfs ls /bin/hw` | **no sensors service** in `/vendor/bin/hw` |
| `debugfs ls /lib64/hw`, `/lib/hw` | **no sensors HAL implementation** |
| `manifest_waydroid.xml` | declares only `vendor.waydroid.display` 1.2, `.task` 1.0, `.window` 1.2, `.clipboard` 1.0 — **no sensors entry** |
| `/vendor/apex/` + init rc | the sensors HAL that *does* exist is AOSP's **AIDL** `android.hardware.sensors-service.example`, APEX-packaged |
| `sensors/service.cpp:680` | ours is `gbinder_servicemanager_new2(device, "hidl", "hidl")`, serving `android.hardware.sensors@1.0::ISensors` |

[14](14-sensors.md)'s design rests on a seam with two halves: Waydroid's `container_manager.py`
starts a host `waydroid-sensord` from `PATH` (**still true on `main`**, re-confirmed in 63), and the
*guest* ships a stub HIDL sensors HAL that returns at its first line so ours can take over. **The
guest half is gone.** There is no HIDL sensors HAL in this vendor image and no VINTF declaration for
one, so there is nothing for a HIDL `ISensors@1.0` server to stand in for. Meanwhile `system_server`
aborts with *"Could not connect to declared sensors AIDL HAL after 20 retries"* — it wants the
**declared AIDL** HAL and will not fall back.

So on A16, once the binder policy is fixed, Android gets AOSP's *example* sensors HAL, which reports
no real hardware. Making `sensord` useful there means **writing an AIDL `ISensors` server** to
displace that APEX service, not re-pointing the existing one. The IIO reader in
[sensors/SensorIIO.cpp](../sensors/SensorIIO.cpp) is the reusable half and is interface-agnostic; the
libgbinder HIDL server around it is not. That is a port, and it is the single largest Android-side
cost of A16 found so far.

This is measured from the image, and the one thing it does **not** establish is whether a HIDL
`ISensors@1.0` server would still be *bindable* on A16 if something declared it —
`android.hardware.sensors@1.0.so`, `@2.0.so` and `@2.1.so` are all still present in `system.img`, so
the client-side plumbing has not been deleted. That is an interesting question and not the one that
decides anything, because nothing on the device declares it.

### `wifid` — survives, with one concrete and small change

The protocol question turns out to be two different things that 63's wording ran together.
`docs/31`'s `aidl3` is **libgbinder's wire protocol**, keyed to the Android API level by Waydroid's
`tools/helpers/protocol.py`; the supplicant's **AIDL interface version** is a separate number in
VINTF. Both were checked.

**Wire protocol**, from `protocol.py`. For API 36 the `else` branch applies:

| | bigtab01 (API 33) | A16 (API 36) |
|---|---|---|
| `binder_protocol` | `aidl3` | **`aidl3`** — unchanged |
| `service_manager_protocol` | `aidl3` | **`aidl6`** — changed |

`wifi/service.cpp` hardcodes both, deliberately, because libgbinder's built-in default for
`/dev/binder` is the much older `aidl`:

```c
#define SM_PROTOCOL     "aidl3"
#define RPC_PROTOCOL    "aidl3"
```

So `RPC_PROTOCOL` stays correct and **`SM_PROTOCOL` must become `aidl6`** on A16. The host side can
already do it: `libgbinder-1.1.47` exports `GBinderServiceManagerAidl2` through
**`GBinderServiceManagerAidl6`**, including `gbinder_servicemanager_aidl6_get_service` and
`_aidl6_list`. No library upgrade, no patch — a build-time constant, which should be read from
`waydroid.cfg` rather than hardcoded so the same binary serves both hosts.

**Interface versions**, from the vendor VINTF fragments:

| HAL | A16 / ATV 20260803 |
|---|---|
| `android.hardware.wifi.supplicant` | **AIDL version 4**, `ISupplicant/default` |
| `android.hardware.wifi.hostapd` | **AIDL version 3**, `IHostapd/default` |

`wpa_supplicant` and `hostapd` are both present in `/vendor/bin/hw`. Our surface was taken from
`android-13.0.0_r75` ([30](30-wifi-aidl-surface.md)), so the supplicant interface has moved and the
surface needs re-extracting against A16 — a known, mechanical procedure with an existing recipe,
unlike `sensord`'s problem. `wificond` is a system service rather than a VINTF HAL and is not in this
table.

Net: **`wifid` is a re-measurement, `sensord` is a rewrite.** That is a meaningfully better split
than 63's "the two features that took longest to build" implied.

## The three image-pinned packages, re-measured

63 grouped these as "void". With the image open, they separate into three different situations, and
only one is genuinely a dead end.

| Package | Pinned target | In A16 20260803 | Verdict |
|---|---|---|---|
| `battery` 2.0.0 | `/vendor/bin/hw/android.hardware.health@2.0-service.waydroid`, stock `de3cf6bc…`, offsets `6720`, `6730`–`6732`, `cbd1` | **ABSENT.** The HIDL health@2.0 Waydroid service does not exist. A16 ships `/vendor/bin/hw/android.hardware.health-service.example` (`sha256 57f92c74…`, 205 088 B) against `android.hardware.health-V4-ndk.so` | **Re-find, not re-derive.** The fix must be located afresh in a different, AIDL binary |
| `camera-hal` 2.0.0 | `/vendor/lib/camera.device@3.4-external-impl.so`, stock `95b1b3e4…`, offset `2c061` | **PRESENT at the same path.** New stock `sha256 b22267b200207c8de0605f0b6a254c6cd643f6af94ed92e41c9b4d9c04aecb50`, 378 772 B | **Re-derivable.** Same binary, same role; find the new offset for the `LENS_FACING` byte and update the row |
| `camera-gbm` 1.0.1 | `libgbm_mesa_wrapper.so`, both ABIs | **PRESENT, both.** `/vendor/lib` `sha256 ca451d89…` (18 524 B), `/vendor/lib64` `sha256 a1be9ca3…` (27 504 B) | **Present, but off the active path as configured.** The running container reports `ro.hardware.gralloc=minigbm`, *not* `minigbm_gbm_mesa`, and `init` rejects the gbm_mesa allocator outright: `Interface 'android.hardware.graphics.allocator@4.0::IAllocator/default' redefined in vendor.graphics.allocator-4-0-gbm_mesa but is already defined by vendor.graphics.allocator-4-0`. So `libgbm_mesa_wrapper.so` is inert here and the [08](08-camera-fixed.md) bug cannot be live in this configuration — it becomes relevant again only if the gbm_mesa gralloc is ever selected |

The `gralloc` question 63 could only speculate about is now settled on the image side. A16 ships
**both** variants:

```
/vendor/bin/hw/android.hardware.graphics.allocator@4.0-service.minigbm
/vendor/bin/hw/android.hardware.graphics.allocator@4.0-service.minigbm_gbm_mesa
/vendor/lib64/hw/gralloc.minigbm.so
/vendor/lib64/hw/gralloc.minigbm_gbm_mesa.so
/vendor/lib64/hw/android.hardware.graphics.mapper@4.0-impl.minigbm.so
/vendor/lib64/hw/android.hardware.graphics.mapper@4.0-impl.minigbm_gbm_mesa.so
/vendor/lib64/hw/hwcomposer.waydroid.so
/vendor/lib64/hw/hwcomposer.drm_minigbm.so
```

So the **`gbm_mesa` path [08](08-camera-fixed.md) fixed still exists**, and 63's ladder
(`gbm` → `minigbm_gbm_mesa` → `minigbm_intel`) is available in full. Note also that the VINTF
manifest declares graphics as **HIDL** — `allocator@2.0`/`@4.0`, `mapper@2.0`/`@4.0`,
`composer@2.4` — i.e. **gralloc4, not AIDL gralloc5**. That is consistent with Waydroid's
"Detect AIDL gralloc5" patch returning `False` for `MAINLINE` before it looks at anything, and it
means no gralloc5 work is implied by A16 here.

## The boot test: Android 16 boots on vidiot01, and the binder module is what does it

Run 2026-10-08, host **Enforcing throughout**, as an A/B pair so the fix is attributable rather
than assumed. This is the test [`waydroid_binder.cil`](../artifacts/binder/waydroid_binder.cil) was
waiting for, and it is green.

| | **BARE** (no module) | **MODULE** loaded |
|---|---|---|
| `sys.boot_completed` | **never set in 240 s** | **`1` after 18 seconds** |
| `init.svc.bootanim` | `running` — forever | **`stopped`** |
| Services `[restarting]` | `media.swcodec`, `statsd`, `vendor.authgraph`, `vendor.gatekeeper_nonsecure`, `vendor.memtrack-default`, `vendor.secretkeeper`, `vendor.sensors-default` | **none** |
| Binder AVCs | **657**, all `denied { call } spc_t → container_runtime_t` | **0** after the module was loaded |
| Kernel `transaction credentials failed` | present throughout, with `binder_debug: N callbacks suppressed` | **none after the module boot** |
| Focused window | — | `com.google.android.setupwizard/.user.WelcomeActivity` |

The denial reproduced on `vidiot01` is **character-for-character** the one measured on
`jeremy-laptop02`:

```
avc: denied { call } for pid=91149 comm="android.hardwar"
     scontext=system_u:system_r:spc_t:s0
     tcontext=system_u:system_r:container_runtime_t:s0
     tclass=binder permissive=0
```

and the domain split is confirmed directly rather than inferred — `ps -eo label` on `vidiot01`
puts `servicemanager` (the binder target, the `70707:0` in the kernel messages) and
`surfaceflinger` in `container_runtime_t`, with **38 processes in `spc_t`**.

A screencap of the booted system is at
[`artifacts/binder/a16-boot-vidiot01.png`](../artifacts/binder/a16-boot-vidiot01.png) — the Android
16 GAPPS setup wizard at 1920×1048 — taken because [53](53-release-readiness.md) is blunt about the
difference between "no errors" and "it works", and `getprop` alone is the former.

**What this does not establish, and the trap in reading it the other way.** `vidiot01` only ever
*logged* one of the four permissions, `call` in the `spc_t → container_runtime_t` direction. That is
not evidence that the other three are surplus — it is the same property the module is written
around: SELinux stops at the first failure, so the rest of the chain is never attempted and can
never be logged. Those three were each proven individually on `jeremy-laptop02`, at the cost of a
boot apiece, and a single green boot here cannot retroactively isolate which of the four it needed.

### Fedora's own policy has this gap, so this belongs upstream

`vidiot01` already had a **`waydroid` SELinux module loaded** at priority 200, from
`selinux-policy-43.10-1.fc43` — and it already grants binder permissions. Decompiled off the live
system with `semodule -E waydroid` piped through `/usr/libexec/selinux/hll/pp`:

```
(allow waydroid_t container_runtime_t (binder (call transfer)))
(allow container_runtime_t waydroid_t (binder (call)))
(allow container_runtime_t self (binder (call set_context_mgr transfer)))
(allow container_runtime_t unconfined_service_t (binder (call)))
(allow container_runtime_t unconfined_t (binder (call transfer)))
(allow unconfined_service_t container_runtime_t (binder (call transfer)))
(allow unconfined_t container_runtime_t (binder (call transfer)))
```

Three source domains are anticipated — `waydroid_t`, `unconfined_t`, `unconfined_service_t` — and
**`spc_t` is not among them**. There are no `dontaudit` rules for the `binder` class. So this is a
hole in the *distribution's* policy, not a quirk of one machine, which makes it worth proposing to
`selinux-policy` rather than carrying as a local module forever. It probably went unnoticed because
`waydroid_t`, the domain that module is built around, is **not** the domain Waydroid actually runs
in under LXC: there the container is `container_runtime_t` and the APEX HALs are `spc_t`. That also
means the eventual upstream fix is a `selinux-policy` change, and
[57](57-upstream-queue.md) is where it should be queued.

### One tooling trap worth keeping

**`ausearch` does not surface these records on this host.** `ausearch -m avc -ts today` reports
`<no matches>` while `/var/log/audit/audit.log` holds hundreds of them — binder denials raised from
kernel binder threads carry no `SYSCALL` record for `ausearch` to anchor to. The first version of
the harness used `ausearch` and reported **zero denials on a boot that produced 657**. Grep the log
directly and bound the window by line count. [63](63-second-host-and-android-16.md)'s step 6 warns
about a different way for denials to stay invisible (an unparseable context, `errno=-22`); this is a
second, independent one, and it reads identically from the outside.

## The GUI works end to end, verified 2026-10-08

Android 16 does not merely boot on vidiot01 — it reaches the GNOME desktop as a real window, on the
live Wayland session of user `jmelanson` (GNOME 49 / Mutter, Fedora 43).

The Wayland client is the **hwcomposer inside the container**, not anything host-side.
`/vendor/lib64/hw/hwcomposer.waydroid.so` statically links libwayland — it has no `libwayland-client`
`DT_NEEDED` — and serves the `vendor.waydroid.{display,window,task,clipboard}` HIDL interfaces that
the framework drives. Traced with `strace -f` on the container's `init` and decoded off the wire:

```
connect(5, {sa_family=AF_UNIX, sun_path="/run/xdg/wayland-0"}, 21) = 0
C->S  wl_registry#2    bind            -> xdg_wm_base v1 as obj 10
C->S  wl_compositor#4  create_surface  -> obj 24
C->S  xdg_wm_base#10   get_xdg_surface -> obj 27 (for wl_surface 24)
C->S  xdg_surface#27   get_toplevel    -> obj 28
C->S  xdg_toplevel#28  set_title       = 'Waydroid'
C->S  xdg_toplevel#28  set_app_id      = 'Waydroid'
S->C  xdg_toplevel#28  configure       = 1920x1048 states=['MAXIMIZED']
C->S  xdg_surface#27   ack_configure
```

Mutter advertises 40 globals; the hwcomposer binds 16, including `xdg_wm_base`,
`zwp_linux_dmabuf_v1`, `wp_viewporter`, `wp_presentation` and `wl_subcompositor`. Rendering uses a
toplevel plus subsurfaces with `wp_viewport.set_destination(1920, 1048)` and dmabuf buffers passed by
`SCM_RIGHTS`. There is **no `wl_display.error` event anywhere in the stream**.

### The failure mode that is not a failure

With the laptop panel asleep this is indistinguishable from a broken GUI by every host-side signal:
the window is configured, frame callbacks keep firing, and the client keeps committing. The one
measurement that separates the two cases is `wp_presentation_feedback`:

| panel state | PRESENTED | DISCARDED |
|---|---|---|
| `eDP-1 enabled=disabled dpms=Off`, session `LockedHint=yes` | 0 | 380 |
| `eDP-1 enabled=enabled dpms=On`, session unlocked | 298 in 5 s | 0 |

vidiot01 is an Acer Nitro AN515-54 whose only connected output is `eDP-1` (HDMI-A-1 is
disconnected), and GNOME's `idle-delay` is 900 s with `lock-enabled true`. After fifteen idle minutes
there is no enabled CRTC, so Mutter discards every frame while still behaving normally in every other
respect. **Check `/sys/class/drm/card1-eDP-1/{status,enabled,dpms}` and
`loginctl show-session 2 -p LockedHint` before debugging a GUI fault on this host.**

### Two traps worth keeping

- **The hwcomposer appears to log nothing at all.** libwayland's `wl_log` writes to **stderr**, and
  Android `init` hands services `/dev/null` for fds 1 and 2, so even a hard connection failure is
  invisible in `logcat`. Silence from the composer is not evidence; trace the syscalls instead.
- **Host-side socket tools cannot see into the container.** AF_UNIX sockets are network-namespace
  scoped, so `ss -x` and `/proc/net/unix` on the host show nothing of the container's end of the
  connection. Worse, comparing a client socket inode against the *server-side* inodes that `ss -x`
  prints can never match, and reads as a confident negative. Use
  `nsenter -t <pid> -n cat /proc/net/unix`, or trace `connect()` directly.

## Status and what is not established

**The binder module is verified; the rest of the A16 port is not.** Waydroid is initialised, the module is loaded, and
Android 16 boots to the setup wizard. Nothing beyond that has been exercised.

Also not established:

- **Whether anything past first boot works.** The setup wizard has not been completed, so there is
  no launcher, no app has been run, and nothing has been asked of the camera, audio, sensors or
  Wi-Fi. Graphics, by contrast, are now verified end to end — see the GUI section above.
- **Which Vulkan driver Waydroid actually selects.** The gralloc half is now measured, not inferred:
  the running container reports `ro.hardware.gralloc=minigbm` with
  `gralloc.gbm.device=/dev/dri/renderD128`, and `vendor.gralloc-2-0` is `stopped`. Vulkan is still a
  read of the generated props that has not been done. What *is* confirmed from the
  live `waydroid.cfg` is the protocol prediction above: **`binder_protocol = aidl3`,
  `service_manager_protocol = aidl6`**, exactly as `protocol.py`'s API-36 branch implies, which is
  the `wifid` change made concrete.
- **Whether ATV issue #37's composer crash is really absent.** The 20260803 image is supposed to fix
  it and nothing resembling it appeared. One half of the trigger has now been exercised by accident:
  a DPMS **off to on** transition happened with a composer instance running, and it survived — the
  surfaces resumed presenting with no crash and no restart. The **on to off** direction has still not
  been observed, because every composer instance so far was started while the panel was already
  blanked. [63](63-second-host-and-android-16.md)'s step 3 (`idle-delay 0`) was never applied.
- **Whether the four permissions are each necessary on this host** — see the trap noted above.
- **Anything inside `system.img`** beyond what `strings` shows — `erofs-utils` is not installed, so
  the system side has not been extracted the way the vendor side has.
- **The `backlight`/`systemd_logind_t` prediction**, unchanged from 63 and still one keypress away.
- The `sensord` AIDL port is **scoped, not attempted**.
