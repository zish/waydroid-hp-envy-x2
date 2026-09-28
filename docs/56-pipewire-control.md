# 55 — PipeWire: controlling the host's graph from inside Android

*2026-09-25. Built; host-side measurements taken on bigtab01 the same day. Not yet run against
the container — the end-to-end legs are listed under [Verified vs hypothesis](#verified-vs-hypothesis).*

Under cage ([docs/25](25-waydroid-in-cage.md)) this machine has no host UI, so changing a sink,
making a link or lowering the graph quantum means ssh-ing in and running `pw-link`. That is the gap
this closes: an Android app that drives the host's PipeWire graph, and a host daemon underneath it.

Two pieces, and a third that is deliberately absent:

| | |
|---|---|
| [artifacts/pipewire/](../artifacts/pipewire) | `waydroid-pwd`, an unprivileged Python daemon. `pw-dump -m` on one side, newline-delimited JSON over TCP on the other. Plus `waydroid-pwd-publish`, the forty root lines |
| [pw-app/](../pw-app) | "Patchbay", a dependency-free Kotlin app. No AndroidX, no Compose, no coroutines |
| *no overlay component* | nothing changes inside the image: no vendor `.so`, no HAL, no feature XML, no SELinux policy, no mount |

Verify with `bin/pipewire-test.sh`. If the audio itself sounds wrong, `bin/pw-audio-diag.sh` is the
read-only companion that looks for an accumulating fault rather than a broken link.

## This is the control plane. docs/44 is the data plane

The question that starts this looks like the one [docs/44](44-audio-alsa-backend.md) already
answered — *should something in the guest speak PipeWire?* — and the answer there was no, firmly:
`pipewire-pulse` already terminates the PulseAudio protocol natively, the PA protocol is stable
where PipeWire's is not, and a native client would buy a few milliseconds against a HAL that spends
85 ms.

**That conclusion is about moving samples, and it does not transfer to controlling the graph.** The
PulseAudio protocol carries sinks, sources, sink-inputs, cards and per-stream volume — that is a
mixer, roughly `pavucontrol`. It has no concept of a **port** and no concept of a **link**. So
where the data plane had a working incumbent to improve on, the control plane has nothing at all:
today the container cannot see the graph, let alone edit it.

The practical consequence is the nicest thing about this work. A control surface needs **no overlay
file, no vendor `.so`, no HAL change, no policy XML, no `/dev/snd`, no SELinux work and no mount**.
It is a host daemon and an ordinary APK. It is independent of every stage of docs/44's roadmap and
could have been built before any of it.

It is also not a substitute for that roadmap, and the boundary is worth stating plainly: **Android
still appears in the graph as one client behind an 85 ms HAL and a stereo-only policy XML.** This
app routes the host's graph beautifully and changes nothing about Android's own audio path. Per-track
routing out of Android apps is docs/44's routes 2 and 4, not this.

## What the host offers, measured

Read-only on bigtab01, 2026-09-25, over non-PTY ssh ([docs/02](02-ssh-access.md)'s hang is resolved;
`bin/rsh` was not needed).

| | |
|---|---|
| PipeWire / WirePlumber | **1.6.8 / 0.5.14**; `pipewire`, `pipewire-pulse` and `wireplumber` user units all `active` |
| tools | `pw-dump`, `pw-cli`, `pw-link`, `pw-mon`, `pw-metadata`, `pw-loopback`, `pw-top` (`pipewire-utils`), `wpctl` (`wireplumber`). **`qpwgraph` is not installed** |
| graph size | 63 objects: 7 Node, 11 Port, 5 Client, 5 Device, 5 Metadata, 14 Module, 13 Factory, **0 Link** |
| `link-factory` | present. `libpipewire-module-{loopback,filter-chain,echo-cancel,combine-stream}.so` all installed |
| sockets | `/run/user/1000/pipewire-0` **and `pipewire-0-manager`**, both `srw-rw-rw-` |
| MIDI, already there | `Midi-Bridge` (ALSA seq "Midi Through") and `bluez_midi.server` (BLE MIDI 1) |
| quantum | `clock.quantum 1024`, `min 32`, `max 2048`, `force-quantum 0`, `rate 48000`, `allowed-rates [48000]` — matches docs/44 |
| bridge | `waydroid0` = 192.168.240.1/24, firewalld zone **`trusted`**, container answers in 0.061 ms |
| ports | btd holds `192.168.240.1:7712`; **7713 was free** and is what this uses |

Zero links, with ports present on both the sink and the source, is not a fault: WirePlumber
suspends idle nodes and nothing was playing. It is worth knowing before reading an empty patchbay as
a bug.

## The five findings that decided the design

### 1. `pw-dump -m` is already a delta protocol

This is the one that removed most of the work. `pw-dump --monitor` emits a **sequence of complete
top-level JSON arrays** — an initial full snapshot, then one array per change batch — and object
removal arrives as:

```json
[
  {
    "id": 62,
    "info": null
  }
]
```

Crucially the framing is column-anchored: `[` and `]` are in column 0 and everything nested is
indented by at least two spaces. So a top-level array is exactly the lines from a `[` at column 0
through the next `]` at column 0, and **no incremental JSON parser is needed** — accumulate to a
bare `]` and `json.loads`. Verified by watching five arrays over six seconds while transient clients
came and went.

So the entire graph mirror is a subprocess and a line loop: no libpipewire, no ctypes, no bindings,
and **no version coupling to whatever PipeWire the host runs** — which is the objection docs/44
raised against a guest-side client, sidestepped rather than argued with.

### 2. `pw-link`'s names are unparseable. Its ids are not

```
$ pw-link -o
Midi-Bridge:Midi Through: Port-0 (capture)
alsa_output.pci-0000_00_1b.0.analog-stereo:monitor_FL
```

The `node:port` separator also occurs **inside** the port name, so splitting on `:` is wrong and
splitting on the first or last `:` is wrong differently. There is no escaping.

`pw-link` takes numeric ids though (`-I/--id` to list them, `pw-link -d <link-id>` to disconnect),
so the rule throughout is: **enumerate with `pw-dump` (structured), act with ids.** Names are still
what a *saved patch* must key on later — ids churn — but they are never used to address anything.

Also measured, and load-bearing: `-L, --linger` is **the default**, so a link outlives the `pw-link`
that created it. Without that this whole verb would be a no-op that looked like it worked.

### 3. Every client is `unrestricted`

`/usr/share/pipewire/pipewire.conf` line 191:

```
#access.socket = { pipewire-0 = "default", pipewire-0-manager = "unrestricted" }
#access.legacy = true
```

Both commented out, and the comment above them says `access.legacy` is "enabled by default if
access.socket is not specified". There is no `/etc/pipewire/pipewire.conf.d/`. Consistent with what
the graph reports: every client, including WirePlumber and the Waydroid one, carries
`pipewire.access = unrestricted`.

**So anything that reaches the socket today gets the entire API** — including creating a link from
any sink's monitor port into itself, which is a recording tap on everything the desktop plays.

### 4. The container's client is identifiable, but not trustworthily

Android's audio HAL already has a live, persistent PulseAudio connection, and it is visible:

```
application.name               = Waydroid
application.process.binary     = threaded-ml
application.process.host       = waydroid
application.process.user       = system
application.process.id         = 76            <- the pid INSIDE the container
client.api                     = pipewire-pulse
pipewire.sec.uid               = 1000          <- pipewire-pulse's
pipewire.sec.pid               = 280906        <- pipewire-pulse's
pipewire.sec.socket            = pipewire-0
pipewire.sec.label             = unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
```

Read the two halves against each other. The `application.*` props say "waydroid" clearly — but they
are what the client said about **itself**, and anything in the container can say the same. The
`pipewire.sec.*` props are the ones PipeWire vouches for, and they all describe
**`pipewire-pulse`**, because that is the process holding the connection. So there is no property on
this client that both identifies the container and can be trusted.

Which kills the mounted-socket design on its own: even with `access.socket` enabled and a
WirePlumber rule written, the rule could only restrict *the container as a whole*, never one app
inside it — and the props it would have to match on are forgeable by anything in there.

One more detail from the same probe: with nothing playing there are **no `sink-inputs`**. The client
connection persists; the stream node appears only during playback. A patchbay must not treat a
missing Waydroid node as a missing Waydroid. The app answers this with a Clients section and a
standing phrase in the status line — "Android connected, idle" and "Android streaming" are
different states, and on a quiet host both would otherwise look like nothing at all.

### 5. The credential drop needs root. The daemon does not

btd's profile lives at

```
~jmelanso/.local/share/waydroid/data/data/lan.syshlt.bluetooth/files/btd.json
```

measured as uid 10213, mode 0600, inside a `drwxr-x--x` directory. That is **real kernel DAC
separation inside the container** — Android uids are real uids, so it holds even though
`getenforce` there says `Disabled` ([docs/50](50-bluetooth.md)). It is also why only root can put a
file there.

Meanwhile `systemctl --user is-active pipewire wireplumber` is `active`, so a user unit works on
this host. And PipeWire is a **user** service: the daemon's entire job — `pw-dump`, `pw-link`,
`wpctl`, `pw-metadata` — is ordinary client work needing no privilege whatsoever.

So this splits where btd did not. [waydroid-btd.service](../artifacts/bluetooth/waydroid-btd.service)
says in its own header that root is needed "for exactly one thing" and that "with `--no-profile`
this could be a user unit". That note is taken up here: `waydroid-pwd` is a `--user` unit, and
`waydroid-pwd-publish` is the root half that does nothing else.

## The design

```
    Android                          │  host (jmelanso session)
                                     │
    ┌───────────────────────────┐           │   ┌──────────────────┐        ┌───────────┐
    │ Patchbay (app)            │ TCP/JSON  │   │  waydroid-pwd    │ pw-dump│ PipeWire  │
    │ com.systemhalted.patchbay │ ─────────►│──►│  graph + policy  │───────►│ 1.6.8     │
    │                           │◄───────── │◄──│  (--user unit)   │◄───────│WirePlumber│
    └───────────────────────────┘  events   │   └──────────────────┘  wpctl └───────────┘
      192.168.240.112                       │     192.168.240.1:7713   pw-link
                                            │            ▲
                                            │   ┌────────┴─────────┐
                                            │   │ waydroid-pwd-    │  root, and only to write a
                                            │   │ publish (root)   │  0700 app-private directory
                                            │   └──────────────────┘
```

The container never gets a PipeWire handle. The attack surface is a JSON verb set somebody wrote,
not the PipeWire API, and by finding 5 the token is bound to one app by the kernel.

### Why TCP and not binder

Settled by [docs/50](50-bluetooth.md) and unchanged: an ordinary app cannot reach an arbitrary
binder name. `ServiceManager.getService()` is non-SDK on Android 13, the name would want an overlay
`service_contexts` entry, `untrusted_app` would want an SELinux `find` rule, and
[docs/35](35-wifi-stage5.md)'s `dontaudit`ed binder-transfer trap waits underneath all of it. A
socket costs none of that and is testable with `nc`.

### The wire

Newline-delimited JSON, one long-lived connection, commands up and events down.

```
→ {"id":1,"cmd":"auth","token":"…"}
← {"id":1,"ok":true,"version":1,"policy":{"links":true,"links.capture":false,…}}
← {"ev":"ready","version":1,"ready":true,"policy":{…},"objects":[…],"spawned":[]}
→ {"id":2,"cmd":"link-create","output":54,"input":53}
← {"id":2,"ok":true}
← {"ev":"update","changed":[{"id":91,"kind":"link","output_node":52,"output_port":54,
                             "input_node":52,"input_port":53,"state":"active"}]}
→ {"id":3,"cmd":"link-destroy","link":91}
← {"ev":"update","removed":[91]}
```

Commands: `auth`, `ping`, `graph`, `policy`, `node-volume`, `node-mute`, `default-set`,
`default-clear`, `device-profile`, `device-route`, `link-create`, `link-destroy`, `quantum`, `rate`,
`wp-setting`, `node-param`, `node-create`, `node-destroy`, `nodes`. Events: `ready`, `graph`, `update`, `reset`,
`error`, `node-spawned`, `node-gone`.

**A verb names its target by type — `node`, `device`, `link`, `output`, `input` — and never `id`.**
`id` is the request id every reply is correlated on, and an early draft used it for both; the two
are then uncarryable in one message, and the bug presents as "the daemon says object 7 does not
exist" when nobody mentioned 7. Found by the local protocol test, which is the only reason it is not
still in there.

Property projections are explicit allow-lists per object type rather than "send whatever pw-dump
has", so the wire does not change shape when the host's PipeWire is updated. Module, Factory, Core,
Profiler and SecurityContext are dropped entirely — 28 of the 63 objects, and no verb touches any of
them.

Two structural quirks of pw-dump the projection has to absorb: **`props` live under `info` for Node,
Port, Link, Client and Device but at the top level for Metadata and SecurityContext**, and **ids are
strings in some places and numbers in others** (`node.id` on a Port is `"56"`; `link.output.node` on
a Link is `56`). Both were measured; both would silently break a join.

### Capability policy, and why `links.capture` is its own gate

`/etc/waydroid-pwd/policy.conf`, `key = value`, defaults shown:

```
mixer = yes           # volume, mute, defaults, device profiles and routes
links = yes           # creating and destroying links
links.capture = no    # ... where the SOURCE is a capture device or a monitor port
graph = yes           # clock.force-quantum, clock.force-rate, wpctl settings
nodes = no            # supervised pw-loopback instances
modules = no          # module instances hosted in their own pipewire process
params = yes          # filter-graph control ports the node already advertises
```

`links.capture` is split out because **making that link is mechanically identical to making any
other one**. There is no separate verb to refuse, no different factory, no flag: the only thing that
distinguishes "route this synth into that sink" from "route the microphone into a recorder" is which
ports were named. So the gate has to inspect the ports, and it does: a link is a capture link if its
source port is a monitor port (`port.monitor`, or a `monitor_*` name) or belongs to a node whose
`media.class` starts with `Audio/Source`.

The honest framing of what any of this protects: anything in the container holding the token can
call any enabled verb. The token is in the app's 0700 private directory, so in practice that means
the Patchbay app and anything running as its uid. These gates decide what that is allowed to be.

### Supervised child processes, not `load-module`

`pw-cli` does offer `load-module`, and the one-shot form is a trap: **`pw-cli load-module <name>`
loads the module into its own `pw_context` and then exits**, taking the module with it. That is
almost certainly why `pw-loopback` exists as a standalone binary rather than as a documented
`pw-cli` incantation.

**Corrected 2026-09-27.** That holds for the one-shot form only. `pw-cli` invoked with no command
is a **REPL that reads commands from stdin**, and it holds one `pw_context` for as long as stdin
stays open — so a module loaded in a stdin-fed session persists for the life of that session, and
`load-module` hands back a variable (`1 = @module:22`) that `unload-module` takes. Measured: a
`pw-loopback` and a `filter-chain` loaded into one session coexisted for minutes, and closing stdin
removed all four of their nodes. The sentence above still explains why `pw-loopback` is a
standalone binary; it does not rule `pw-cli` out as a module host.

The mechanism that actually persists is the one `/usr/share/pipewire/filter-chain.conf` documents in
its own header — *"Run the filters with `pipewire -c filter-chain.conf`"*. So `node-create` spawns
and supervises a child process: `pw-loopback` directly, or `pipewire -c <generated config>` for a
module instance, with the config written into the daemon's state directory and the standard client
module preamble (`rt`, `protocol-native`, `client-node`, `adapter`) copied from that file.

This is better than a loaded module on three counts, not just one: it is reversible by killing a pid,
a crash takes out one node instead of the graph, and nothing survives a daemon restart to be puzzled
over later. The daemon kills its children on shutdown for exactly that last reason.

### Credential delivery

The daemon writes the profile — address, port, token, TLS pin — to
`~/.local/state/waydroid-pwd/profile.json` as the session user. `waydroid-pwd-publish` copies it to
the app's `files/profile.json` with the app's uid and mode 0600, creating `files/` and chown-ing it
first — [docs/46](46-removable-media.md) already paid for the version of this bug where a root-owned
directory left the app unable to write its own files.

Publication retries on an interval rather than running once, so installing the app after the daemon
works without restarting anything, and a `waydroid init` that recreates the data tree repairs itself.
`pw-app/build.sh --install` waits for exactly this, as `bt-app/build.sh` does for btd.

TLS is optional (`--tls`), self-signed, and **pinned by certificate SHA-256 rather than
CA-validated** — there is no name to verify on a bridge address and no CA to verify against, so
pinning is both simpler and strictly stronger. Default is plaintext: on a trusted-zone bridge with a
token, TLS buys confidentiality against something that would already have to be inside the container.

## The Android half, and why it is a list before it is a canvas

qpwgraph is the obvious model and the wrong place to start. It assumes a mouse with hover,
right-click menus and a large screen; on this display a 60-object graph of bezier curves is a demo,
not a tool. So the first screen is a list — sections by kind, a row per node, ports underneath, links
in their own section — and the canvas view comes later over the same `Graph`.

Connecting by two taps rather than by dragging is the same decision made twice. A drag between two
port circles needs both on screen at a legible size simultaneously, which here means about eight
ports; tapping an output port arms it, tapping an input port completes the link, and the arming
survives scrolling the length of the graph.

`PwClient.kt` is [`BtClient.kt`](../bt-app/src/BtClient.kt) with the names changed — the three-thread
socket owner, the reconnect backoff, the pinned-TLS trust manager and the main-looper posting are
transport, not Bluetooth. `About.kt` is the verbatim copy every app here carries.

Two graph facts the UI has to respect, both from the findings above: **ids are ephemeral**, so a
`reset` event throws the whole store away including whatever port was armed, rather than trying to
reconcile; and **names are what endure**, so `Graph.nameKey` (node name + `:` + port name) exists
now even though nothing saves patches yet, so that when something does it is not tempted by the id.

## What this deliberately does not do

| | why |
|---|---|
| bind-mount `pipewire-0` into the container | findings 3 and 4: every app in the container would get the whole API, and PipeWire cannot tell them apart |
| use PipeWire's `SecurityContext` to mint a restricted socket | the global is there (id 3, permissions `rwx`, from `module-protocol-native`). **Corrected 2026-09-27: the "there is no CLI for it" reason was wrong** — `pw-container`(1) ships in `pipewire-utils` and is exactly that CLI, minting a socket whose clients carry `pipewire.access = restricted`. The row stands on the reasons either side of it: it needs `access.socket` turned on **host-wide**, and by finding 4 it still cannot distinguish apps inside the container, so it would restrict Waydroid as a whole and never one app in it. The owner's 2026-09-27 constraint rules it out a third time — a mounted socket is an audio *data* plane into the container, which is the thing being avoided |
| enable `access.socket` | changes access for every client on the machine to fix one container |
| port libpipewire to bionic | both ABIs, the version coupling docs/44 objects to, and docs/54's no-vendored-binaries policy. A pure-Kotlin native-protocol client is possible in principle — `LocalSocket` does support `SCM_RIGHTS` — but is thousands of lines of POD marshalling against a protocol that is not a stable contract |
| use binder | docs/50 settled it |
| package the APK | no app in this repository is packaged: an APK needs the Android SDK and Kotlin compiler at build time, neither a Fedora BuildRequires, and a prebuilt one would be the vendored binary docs/54 rules out |
| touch anything in the image | there is nothing to touch. No overlay component exists for this work and none is needed |

## Verified vs hypothesis

**Verified on bigtab01, 2026-09-25** (all read-only): PipeWire 1.6.8 and WirePlumber 0.5.14 with all
three user units active; the full tool set present and `qpwgraph` absent; the 63-object graph and its
type breakdown; zero links while idle with ports present on both sink and source; `link-factory` and
the four loopback/filter modules installed; both `pipewire-0` and `pipewire-0-manager` sockets at
mode 0666; the two MIDI nodes; `clock.quantum` 1024 / min 32 / max 2048 / rate 48000 /
allowed-rates `[48000]`; `waydroid0` at 192.168.240.1 in the `trusted` zone with the container
0.061 ms away; 7713 free; `access.socket` commented out and every client `unrestricted`; the Waydroid
client's full prop set including the `pipewire.sec.*` mismatch; no `sink-inputs` while idle;
`pw-dump -m`'s array framing and `info: null` removals; `pw-link`'s colon-bearing port names, its id
forms and `--linger` being the default; `pw-loopback`'s and `pw-metadata`'s option sets; `wpctl`'s
verb list; `pw-cli`'s verb list; package ownership of every tool; btd's published profile at uid
10213 mode 0600 in a 0751 directory; root being able to reach the user's PipeWire socket.

**Verified locally, 2026-09-25**, against a fake `pw-dump` reproducing the measured framing:

- **Projection** — node, port, link, client, device and metadata; the metadata
  top-level-`props` fallback; string-to-int id coercion; cubic volume conversion
  (`channelVolumes [0.125]` → `0.5`, matching what `wpctl` prints); monitor-port detection; delta
  apply and `info: null` removal; Module/Factory/Core dropped.
- **Policy** — `links.capture` refuses both a real capture source and a real monitor port and
  says which capability did it; `nodes` and `modules` refuse; `quantum` is range-checked against
  the live `min`/`max`; `rate` is checked against `allowed-rates`; port direction is checked.
- **Protocol** — an unauthenticated command is refused; a 64-character token is accepted; the
  `ready` snapshot matches an independently parsed `pw-dump` to within transient clients.
- **Resync** — with a `pw-dump` that dies on a timer, the daemon emits
  `error` → `reset` → `graph`, and the `graph` carries the *new* generation's objects. This is
  the leg that was wrong on the first attempt: `_on_monitor_down` cleared the same flag
  `_on_reset` used to tell a resync from a first sync, so every resync looked like a first sync
  and no client was ever told its ids had gone stale. There are two flags now.
- **The publisher** — the not-installed-yet path, the 0600 drop with the app's uid, and
  idempotence on a second run.
- **Packaging** — `build-mod.sh --lint pwd` reports exactly the classes btd reports and nothing
  new; `test-install.sh pwd` passes 5 of 5 including uninstall with files edited behind rpm's
  back.
- **The app** — builds; the APK declares `INTERNET` and nothing else.

**Verified on the device, 2026-09-25**, with the daemon run by hand out of `/tmp` against the real
graph — nothing installed into `/usr`, no unit enabled:

- **The daemon on the real host** — binds `192.168.240.1:7713` and parses the live `pw-dump -m`,
  reporting `33 of 63 objects`. The 30 it drops are Modules and Factories. Both numbers are logged,
  because the app's status line shows only the first and the gap otherwise reads as a loss.
- **The credential drop** — `waydroid-pwd-publish --once` lands `profile.json` at uid 10220 mode
  0600 inside the app's own directory: the kernel DAC gate finding 5 rests on, now measured rather
  than reasoned about.
- **The app** — installs, launches, and connects **from inside the container** (192.168.240.112),
  rendering the real graph with sinks, sources, MIDI, clients, links and devices, and a policy
  footer reading `+graph +links −links.capture +mixer −modules −nodes`.
- **Control from the tablet** — a tap on MUTE muted sink 56 (`wpctl get-volume 56` →
  `1.00 [MUTED]`); a second tap restored it. Touch → TCP/JSON → `wpctl` → monitor delta → back.
- **Reconnect** — killing and restarting the daemon had the app back inside three seconds on its
  own backoff, with nobody touching the panel.
- **`client.id` correlation** — a `pipewire-pulse` stream node carries the `client.id` of its own
  client, checked with a silent `pacat` stream (node 65 → client 62). That is what puts Android's
  streams under the Waydroid client rather than loose in the list.

Two defects only the screen could find, and both the same root cause: `optString` on a JSON null
returns the four characters `"null"`, not `""`. So `media.class` rendered as `null · id 31` — and
worse, the filter that hides `Dummy-Driver` and `Freewheel-Driver` tested `isNotEmpty()` and let
both through, which is the check the code comment calls "not a rounding error". A local probe had
reported no literal nulls because it tested Python `None`, so it was vacuous for exactly this case.
Every projected string now goes through `Graph.text`.

**Measured on bigtab01, 2026-09-26 — `force-quantum` takes, and the host does not survive it.**
This was two items on the hypothesis list below, and it is worth separating what each one did.

*It takes.* The verb works exactly as designed: the app's dialog sent `32`, `cmd_quantum`
range-checked it against the live `clock.min-quantum` of 32, accepted it, and `pw-metadata` wrote it.
Nothing in the chain misbehaved.

*The host does not survive it.* 32 frames is 0.667 ms against a configured `clock.quantum` of 1024,
a 32× cut, and `force-quantum` is graph-wide — so it applies to Waydroid's `pipewire-pulse` path,
which reaches PipeWire through an ~85 ms HAL buffer and has nothing like that timing headroom.
Android's audio went scratchy and then progressively robotic: deadline misses at block rate, which
is dense artefacts rather than occasional clicks. Host load average was 0.06 throughout, so this is
wakeup latency and scheduling granularity and NOT CPU exhaustion — a low load average does not
exonerate a small quantum.

Three things about it are worth keeping:

- **It outlived everything that set it.** `force-quantum` lives in PipeWire's own `settings`
  metadata, not in this daemon, so killing the transient `/tmp` daemon did not revert it and neither
  would uninstalling the package. It stayed in force for two days across the whole diagnosis,
  because the host had not rebooted. It is not persisted, though: a reboot or an unforce clears it,
  and nothing has to be edited to recover.
- **`min-quantum` is not a safety floor.** It is what PipeWire will accept. The daemon's range check
  against it was working correctly and still admitted a value that made the machine unusable.
  32 is now known bad and 1024 known good; nothing in between has been measured, and
  `bin/pw-quantum-bisect.sh` is what measures it -- it walks 512, 256, 128, 64, 32 with audio
  playing, samples the xrun delta at each step, asks how each one sounds before going lower, and
  restores the original `force-quantum` on any exit including an interrupt. The app therefore
  labels any choice below the graph's configured quantum and takes a second tap to send it
  (`confirmQuantum`), which is a confirmation and not a floor — a real floor would need the policy
  file to parse numbers, and it parses yes/no only.
- **It is not a quality control, and it is not aimed at Android.** Quantum trades latency against
  timing headroom and nothing else: at any quantum the graph can actually meet, the samples are
  bit-identical at 32 and at 1024. What went wrong was missed deadlines, not a quantum that "sounds
  worse". docs/44's budget has the numbers — 1024 @ 48 kHz is 21.3 ms, 32 is 0.67 ms, and Android's
  HAL buffer is 85 ms on top of either — so the path is ~106 ms and forcing 32 would have bought
  about 19% of it, off the term that is not the dominant one. That 21.3 ms is inaudible here anyway:
  uniform playback delay has no reference to compare against, and latency only becomes audible when
  there is one, such as monitoring a mic or playing a software instrument. Which settles who the
  control is for — host-side clients with a short path of their own, not audio arriving through the
  HAL.
- **The diagnosis was nearly vacuous.** xruns only accumulate on a graph that is carrying audio, so
  the first `pw-audio-diag.sh` run skipped its own decisive leg and said so rather than reporting a
  clean zero it had not earned. That is the same failure shape as the `optString` probe recorded
  above, caught this time by the script refusing to answer.

**Measured on bigtab01, 2026-09-27 — the effects gate: hosting a filter chain, reading its
controls, and writing them.** Six probes, each torn down before the next; `pw-dump` reported zero
`probe` objects and the default sink was unmoved after every one. This was run to decide whether an
effects UI in the app is reachable at all. It settles the last item on the hypothesis list above and
forces the two corrections recorded earlier.

*Hosting works, by both routes.* `pipewire -c <generated config>` — the mechanism `node-create`
already implements — spawned a child that stayed alive, produced an `Audio/Sink` carrying the filter
graph, and took every one of its nodes with it when killed. A stdin-fed `pw-cli` session does the
same, which is the correction under
[Supervised child processes](#supervised-child-processes-not-load-module). Neither route leaves
anything behind. **The daemon therefore needs no new hosting mechanism**, and the `pw-cli` session
is an option rather than a dependency.

*The controls are in `pw-dump`, but not where the projection looks.* A filter-chain node carries
**two** `Props` entries. The first is audioconvert's — `channelVolumes`, `mute`, `channelmix.*` —
and is the one `_project_node` reads today, which is why volume and mute already work. The second is
the filter graph's, keyed `<filter-node>:<port>` as a flat alternating list:

```
['band:Freq', 1000.0, 'band:Q', 1.0, 'band:Gain', 0.0,
 'band:b0', 1.0, 'band:b1', 0.0, 'band:b2', 0.0, 'band:a0', 1.0, ...]
```

So the read path is a projection change, not a new query. Note the biquad coefficients `b0`–`a2`
arrive in the same list and are **read-only** except on `bq_raw`: a UI that renders every key as a
slider renders six meaningless ones.

*Writing works, from an ordinary one-shot client.* `pw-cli s <id> Props '{ params = [ "band:Freq"
250.0 "band:Q" 3.0 ] }'` set two controls in one call and both read back. The same syntax the
`pipewire-props`(7) man page documents for ALSA device params works on a filter-chain node.

*The trap, and it cost four of the six probes.* A filter chain that has **never been connected**
reports its configured control values forever, whatever is written to it. The write is not lost —
it surfaces the instant the chain is linked. Isolated on a single dead-ended chain:

| step | node state | wrote | `pw-dump` reported |
|---|---|---|---|
| created with `node.autoconnect = false` | `suspended` | — | `Gain 0.0` |
| write `6.0` | `suspended` | `6.0` | `Gain 0.0` |
| linked to the real sink by hand | **`running`** | — | **`Gain 6.0`** — the earlier write surfaced |
| unlinked again | `suspended` | — | `Gain 6.0`, survives |
| write `-12.0` | `suspended` | `-12.0` | `Gain -12.0` |

So the rule is *not* "a suspended node rejects writes" — the last row writes while suspended and
reads back immediately. It is that the filter graph's control state does not exist until the chain
has been instantiated once, and instantiation needs the chain connected to something. Two
consequences: **`node-create` should link the chain it creates** rather than leave it dangling, and
the app must not present a never-connected chain's values as authoritative.

The probe's own isolation flag — `node.autoconnect = false`, added so a test chain could not reach
the speakers — was what hid the result for four rounds. That is the same shape as the `optString`
probe recorded above: a safety measure that made the test vacuous for exactly the case under test.

**Measured on bigtab01, 2026-09-28 — which of the three equalizers a slider can actually reach.**
Three chains side by side, all three loading without complaint, all torn down:

| chain | ports | second `Props` entry |
|---|---|---|
| `param_eq`, three bands from a `filters` array | 2 in / 2 out, `running` | **no controls** |
| `libpipewire-module-parametric-equalizer`, fed an AutoEQ file | 8 in / 8 out, `suspended` | **no controls** |
| chained `bq_lowshelf` + `bq_peaking` | `running` | 18 keys, every one colon-keyed |

The write sweep found a settable Gain only on the chained pair, and it landed where it was aimed:
`b1:Gain` took 4.5 while `b2:Gain` stayed at 0.0. The suspended row does not weaken the result —
the probe above established that a dead-ended chain still *reports* its configured control values,
so suspension hides nothing, and no keys means no controls.

Both file-driven equalizers are therefore config-time only, exactly as their man pages imply:
`param_eq` takes `config = { filename | filters }`, and `module-parametric-equalizer` takes
`equalizer.filepath` and nothing else — it parses an AutoEQ or Squiglink file and translates it
into filter-chain arguments at load. Changing a band means respawning the chain. They still earn a
catalogue entry, just a different one: *load a headphone correction curve* is a real use case,
where `param_eq`'s efficiency and its eight channels are the advantage and there was never going
to be a slider. The affordance there is a file picker, not a fader.

**And the graph must not declare its own `inputs`/`outputs`.** The first attempt wrote
`inputs = [ "b1:In" ]` and got a **mono** sink — `n-input-ports` 1. Omitting both, which is what
the shipped `sink-eq6.conf` does, gives a stereo sink and, the part worth knowing, **one set of
controls rather than two**: 18 keys either way, because the per-channel duplicated graphs share a
control namespace. One write to `band1:Gain` moved the band on both channels. So the UI wants one
slider per band per parameter, with no left/right pairing, and the two channels cannot drift apart.

**Deployed on bigtab01, 2026-09-28 — a six-band EQ the app can drive, and the unit that hosts it.**
[artifacts/pipewire/eq6-sink.conf.example](../artifacts/pipewire/eq6-sink.conf.example), copied to
`~/.config/pipewire/filter-chain.conf.d/10-eq6-sink.conf`. User scope throughout: no sudo, nothing
in `/usr`, nothing in the image.

**The persistent half of an effects rack needs no daemon verb, because Fedora already ships it.**
`filter-chain.service` runs `pipewire -c filter-chain.conf` as its own unit, `BindsTo=pipewire.service`,
and merges `~/.config/pipewire/filter-chain.conf.d/`. That is exactly the supervised-child argument
this document makes for `node-create`, already packaged and already systemd-managed — so adding,
changing or removing a persistent effect restarts one small unit and **never interrupts Android's
stream**, and a crash takes out the chain rather than the graph. The `conf.d` verb this document's
plan wanted is therefore "write a file and poke one unit", not "restart the audio server".

Measured after `systemctl --user enable --now filter-chain.service`:

- the sink appears as `effect_input.eq6`, `media.class = Audio/Sink`, 2 in / 2 out, publishing
  **18 adjustable controls out of 54 keys** — six bands of Freq/Gain/Q, the other 36 being the
  read-only biquad coefficients the projection flags;
- its output is linked FL→FL, FR→FR into `alsa_output.pci-0000_00_1b.0.analog-stereo`;
- `wpctl set-default` takes, and both `default.audio.sink` and `default.configured.audio.sink`
  become `effect_input.eq6`;
- `pw-cat` with **no** `--target` lands on `effect_input.eq6:playback_FL/FR`, which is the proof
  that the routing works — anything that plays to the default sink, Android included, now goes
  through the EQ;
- writes take while running (two gains in one call, then a Freq), survive the chain going idle,
  and are still settable once idle.

**`wpctl status` files it under `Filters`, not `Sinks`.** The node is an `Audio/Sink` and `pw-dump`
says so, but WirePlumber presents link-group nodes in their own section, so a `wpctl status` read
that stops at `Sources:` will conclude the sink vanished and the default is unset. Both were
briefly believed here. The app is unaffected: it classifies on `media.class` from the projection,
not on wpctl's presentation.

**One rough edge, and it is the 2026-09-27 trap in its natural habitat.** Between the unit starting
and the first audio, the chain has never been instantiated, so writes are accepted and invisible —
a slider will appear not to move. After the first playback it behaves normally, including while
suspended. In practice nobody EQs in silence, but the app should not present that window as a
failure.

Not yet verified: that the unit comes back after a reboot under the cage session's user manager.
That is the same open question this document already has for `waydroid-pwd.service`, now with a
second unit riding on it.

**Built on bigtab01, 2026-09-28 — the Effects screen, and what a slider can honestly claim.**
[pw-app/src/Controls.kt](../pw-app/src/Controls.kt) and the `showEffects` dialog in
[MainActivity.kt](../pw-app/src/MainActivity.kt). An "Effects" button appears on any node row whose
projection carries `controls`, and opens one slider per adjustable control, grouped by filter.

**The entry point is its own row rather than a button on the volume row.** A filter chain does not
have to be a sink: a node hosted by `pipewire -c` with no audioconvert in front of it publishes
control ports and no volume at all, so hanging the button off the mixer would hide the controls on
exactly the nodes that have nothing but controls.

**The coefficient ports are dropped, not shown read-only.** They are two thirds of what a biquad
publishes — 36 of the 54 keys on the six-band EQ — and they are outputs: a biquad computes `b0`..`a2`
from the `Freq`, `Q` and `Gain` above them. A screen that lists them is mostly a view of its own
arithmetic. The count is still reported in the header, so the hiding is visible rather than silent.

**A slider's range is keyed on the PORT name, and that is a compromise with a known cost.**
PipeWire publishes a control as `<filter-node-name>:<port>`, and the filter node's name is whatever
the config author chose — `eq_band_1` here, which says nothing about what kind of filter it is. The
*label* (`bq_peaking`, `delay`, `noisegate`) lives in the config and never reaches the graph, so
nothing the daemon can see reports it. Port names, by contrast, are fixed by the plugin, and
libpipewire-module-filter-chain(7) is the list: every biquad has `Freq`/`Q`/`Gain`, the delay has
`Delay (s)`/`Feedback`/`Feedforward`, the noise gate has `Attack (s)`/`Release (s)`/`Hold (s)` and
its two thresholds, the mixer has `Gain 1`..`Gain 8`. The cost is one collision: `lufs2gain`
publishes an *output* control also called `Gain`, linear, which gets a biquad's ±24 dB slider.
Writing to an output control does nothing, so the damage is a misleading readout rather than a
wrong sound — but the real fix is the host telling the app what each control is, which is the
recipe catalogue this document sketches and the app deliberately does not fake.

**A port this table has never heard of gets no slider.** A slider is a claim about where the ends
are, and for an unknown port there is no honest claim to make; a guessed range would put a real
control somewhere arbitrary on the bar. Those fall back to typing the number, which is exactly as
capable and does not lie. Where a control's *configured* value falls outside an assumed range, the
range is widened to cover it rather than clamped, or the first touch of the slider would jerk the
control to the end without anybody asking.

Two smaller things the existing screen already settled, reused here: sends happen on
`onStopTrackingTouch` and not per pixel, because a `set-param` per progress step is a `pw-cli`
spawn per progress step on the host; and nothing suppresses rendering during a drag, unlike the
volume slider, because these views live in a dialog rather than in the list `render()` rebuilds.

Verified over the wire against the running daemon, from the host:

| | |
|---|---|
| `auth` returns `params: true` in the policy | ✔ |
| node 84 projects `controls`: 54 keys, 18 with `readonly: false` | ✔ |
| each entry carries `key`, `filter`, `port`, `value`, `readonly` as the app reads them | ✔ |
| `node-param` applies and replies `{"ok":true,"applied":[…],"state":"running"}` | ✔ |
| `node-param` with `debug.wav-path` is refused — *a control name looks like "band:Freq"* | ✔ |
| the app installs, connects from the container's address, and does not throw | ✔ |

Not verified: that a finger on a slider produces the sound it promises. That needs the panel.

**A deployment finding worth more than the screen.** `bin/pipewire-test.sh` failed every protocol
leg, and the reason was not the daemon: it has been running as a bare `/tmp/waydroid-pwd` process
with `--state-dir /tmp/pwd-state` since 24 September, so the token was not where the test looks for
it. Two consequences that matter more than the test output. The process had been running **three-day-old
code** — the file on disk was current, Python read it at exec, and `md5sum` comparing the file to
the repo agrees while the running process does not, which is a check that looks convincing and
proves nothing. And nothing about that deployment survives a reboot. The daemon needs to be the
packaged `waydroid-ext-pwd` under a `--user` unit at the default state directory before any of this
is real; `rpm -q` says it is still not installed.

**Still hypothesis:** that two-tap linking works under a finger on the panel; that `pw-link` by id
creates a link the daemon then sees via the monitor; that `wpctl set-volume` against a node id
behaves as expected (mute is verified, the slider is not); that a real `systemctl --user restart
pipewire` produces the `reset` → `graph` sequence (the daemon's side is verified above against a
fake monitor, but PipeWire's own restart behaviour is not); that a `--user` unit starts under the
cage session's user manager at boot rather than only after a login. The last item on this list
— whether `pipewire -c` with a generated config really hosts a module instance the way
`filter-chain.conf` implies — is **answered below, and it does**.

## First commands

The host-side reads above needed no sudo. What is left needs the container running, and should be
run when nothing else is mid-install:

```bash
# the daemon, by hand, against the real graph -- no install, no unit
artifacts/pipewire/waydroid-pwd --listen 127.0.0.1 --port 7713 --no-auth --no-profile

# does the projection match what pw-dump sees?
printf '{"id":1,"cmd":"auth"}\n{"id":2,"cmd":"graph"}\n' | nc 127.0.0.1 7713

# the safe link round-trip: the two MIDI Through ports, so no audio device moves
pw-dump | python3 -c 'import json,sys
for o in json.load(sys.stdin):
    p = (o.get("info") or {}).get("props") or {}
    if "Midi Through" in str(p.get("port.name")): print(o["id"], p.get("port.direction"), p.get("port.name"))'

# then the whole thing
bin/pipewire-test.sh
```

If the complaint is the SOUND rather than the plumbing, this one is read-only — no link, no volume,
no metadata, no profile — and wants audio playing in Android before it can measure anything:

```bash
ssh 10.42.0.137 'sudo sh -s' < bin/pw-audio-diag.sh
```

And the one that is *not* read-only: it forces the quantum down a step at a time to find where this
host stops coping. Copied over rather than piped, because it asks how each step sounds and a `read`
against a piped stdin would eat its own source. `--auto` judges on xrun counters alone.

```bash
scp bin/pw-quantum-bisect.sh 10.42.0.137:/tmp/
ssh -t 10.42.0.137 'sudo sh /tmp/pw-quantum-bisect.sh'
```
