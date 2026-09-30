# 58 — Versioning the host daemons and their APIs separately

*Opened 2026-09-30, at the owner's request, ahead of the F-Droid split
([docs/53](53-release-readiness.md) item 2). **Built and verified on hardware the same day** —
`waydroid-ext-btd` 1.1.0 and `waydroid-ext-pwd` 1.3.0, with both apps. See
[What was built](#what-was-built-and-what-it-measured) at the end.*

The problem the split creates: once each APK lives in its own repository with its own release
cadence, the app and the daemon it talks to stop moving together. F-Droid updates an APK in the
background; a host RPM waits for somebody to run `dnf upgrade`. So the two halves of every feature
will routinely be at different versions, and today that produces a silent failure.

The requirement, in the owner's words: the daemon has its own version, the API has its own version,
apps tell the API what they support, the API says whether that is supported, and an unsupported app
prompts the user to install the current one from F-Droid or the GitHub page.

## Three numbers, and keeping them straight is most of the design

| Number | Example | Changes when | Lives in |
|---|---|---|---|
| **Daemon package version** | `waydroid-ext-btd 1.0.1` | every release, including packaging-only ones | `packaging/mods/btd.mod` |
| **API version** | `2` | **only** when the wire format changes | the daemon source |
| **App version** | `versionCode` / `versionName` | every release | the APK manifest |

They are orthogonal. `btd` 1.0.1 was a package release that changed a constant and a D-Bus path and
touched no wire format, so it would not have moved the API version. Conversely one API change may
ship in a package release that also does five unrelated things.

**The API version is per daemon, not global.** `btd`'s protocol and `pwd`'s protocol evolve for
unrelated reasons; a single shared number would force a bump on one whenever the other changed and
would make every changelog lie about compatibility.

## What exists today, and why it does nothing

Both TCP daemons already declare a protocol version. `waydroid-btd:110` and
`waydroid-pwd:103` both say `PROTOCOL_VERSION = 1`, and both announce it in three places — the
`auth` reply, the `ready` event, and (for `btd`) the connection profile it writes into the app's
private directory.

**No app has ever read it, and no app sends one.** The handshake is
`{"id": 0, "cmd": "auth", "token": …}` — `BtClient.kt:97` and `PwClient.kt:97`, identical. So the
daemon has no idea what it is talking to, the app ignores what it is told, and a wire-format change
would present as malformed replies rather than as a version error.

The machinery is therefore half-built in a specific and convenient way: **the announcement side
exists and the negotiation side does not.**

## Negotiate a range, not a number

A single integer per side cannot express backward compatibility — it forces lockstep, which is the
thing this is meant to avoid. Each side declares the closed range it can speak:

```
app    → { "api_min": 2, "api_max": 4 }
daemon → { "api_min": 1, "api_max": 3 }
                                      agreed: 3   (highest common)
```

The daemon is the authority, because it is the side that can refuse. It picks the highest version
in the overlap and every later message in that connection is in that version's format.

**A daemon keeps its `api_min` low for as long as it is willing to serve old apps**, and raising
`api_min` is the deliberate act of dropping them. That is the whole backward-compatibility lever,
and it is one number in one file.

### This can ship without breaking the apps that are installed now

Today's apps send an `auth` with no range fields. **Absence is itself a valid declaration**: no
`api_min`/`api_max` means "API 1 only", which is exactly what those apps speak. So the daemon can
gain negotiation in its next release and every currently-installed app keeps working untouched, with
no flag day and no coordinated rollout.

## Three outcomes, and the one that was not asked about is the likelier one

| Outcome | Condition | Who has to update | What the app shows |
|---|---|---|---|
| **Agreed** | ranges overlap | nobody | connects at the highest common version |
| **App too old** | `app_max < daemon_min` | the APK | *"This app is too old for the host service."* F-Droid and GitHub links |
| **App too new** | `app_min > daemon_max` | the host package | *"The host service is too old for this app."* the exact upgrade command |

**The second failure will be rarer than the third.** F-Droid updates apps in the background with no
user action; `waydroid-ext-*` needs a deliberate `dnf upgrade` or `rpm-ostree upgrade` and, on this
host, a `LiveCommit` check afterwards ([packaging/README.md](../packaging/README.md), the migration
sections). So in the field the app will usually be *ahead* of the daemon. A design that only handles
"app too old" leaves the common case showing a bare connection error — and pointing the user at
F-Droid then makes it worse, because updating the app again cannot help.

Both directions need a message, and they are not interchangeable.

### The refusal has to be machine-readable

The app cannot pick the right message from a human string. The failure carries a reason code and
both ranges:

```json
{"id": 0, "err": "api_unsupported",
 "reason": "app_too_new",
 "daemon": {"api_min": 1, "api_max": 3, "package": "waydroid-ext-btd", "version": "1.0.1"},
 "app": {"api_min": 4, "api_max": 4}}
```

`package` and `version` are what make the "too old host" message actionable — *"the host has
waydroid-ext-btd 1.0.1"* beats *"the host service is too old"*. **Neither daemon currently knows its
own package version**, so this needs a build-time stamp from the `.mod`'s `VERSION`. That is new
mechanism, small, and it is the only part of this that touches the packaging.

## What the prompt can and cannot do

For **app too old**, the app can act: open the F-Droid package page, or the GitHub releases page, as
an ordinary `ACTION_VIEW`. Chrome and Brave are both installed on this host, so a browser exists
even under cage where there is no desktop. If the F-Droid client is installed its own page URL is
the better target, since it leads to a one-tap update rather than a sideload.

For **app too new**, the app can do nothing but *tell*. It has no route to `dnf` on the host, and the
daemon that would otherwise run something on its behalf is the component that is too old. So that
screen is text plus a copyable command, and it should name the package and the installed version it
got from the refusal.

Neither screen should be a toast. Both are terminal states for the connection, so they belong in the
place the app already shows "not connected", with the reason and the action in it.

## `mediad` cannot do any of this, and pretending otherwise would be worse

Removable media is not a connection. `waydroid-mediad` fires
`am broadcast -a waydroid.ext.media.VOLUME_MOUNTED -p <package> -f 32` and never learns whether
anything received it — [docs/46](46-removable-media.md) records that a wrong `-p` reports
`result=0` and fires nothing, silently. There is no reply channel, so there is nothing to negotiate
with and no way to prompt.

Its compatibility rule is therefore a discipline rather than a handshake:

- **The broadcast payload is append-only.** New extras may be added; none is ever removed,
  renamed, or repurposed. An old app ignores what it does not recognise.
- **A real break needs a new action name**, not a version field — `waydroid.ext.media.VOLUME_MOUNTED2`
  or similar — so that a daemon can emit both for a transition and old and new receivers can coexist.
- An `api` extra should still be carried, because it costs nothing and lets a *receiver* log or
  refuse. It just cannot flow the other way.

The eject path is the one part with a return channel — the app drops a marker file the daemon polls
— and it is a filename, so the same append-only rule covers it.

## What was built, and what it measured

Shipped 2026-09-30 as `waydroid-ext-btd` 1.1.0 and `waydroid-ext-pwd` 1.3.0, both deployed to
bigtab01, with `bt-app` and `pw-app` rebuilt and installed.

**The daemon half, measured on the wire** against the live `btd` at API 1–1, as an app would connect:

```
no range at all (a pre-negotiation app)    -> OK  agreed api=1  daemon=1-1
1-1  exactly the daemon's range            -> OK  agreed api=1
1-3  app newer, ranges overlap             -> OK  agreed api=1
3-5  app far ahead of the daemon           -> REFUSED app_too_new   daemon=waydroid-ext-btd 1.1.0-1
0-0  app below the daemon's floor          -> REFUSED app_too_old
5-2  inverted, a client bug                -> REFUSED app_range_invalid
garbage instead of ints                    -> OK  agreed api=1
```

The first line is the one that mattered: **no installed app broke**, because absence of a range is
read as API 1. The refusals carry `waydroid-ext-btd 1.1.0-1`, which is the build-time stamp working
and is what makes the "update the host" screen able to name what is installed.

**The app half, measured with a probe standing in for the daemon.** The apps' side could not be
proved against the real daemon, because a daemon at 1–1 cannot produce a refusal an app at 1–1 would
receive. So `waydroid-btd` was stopped and a listener put on its port, which recorded what the app
actually sent:

```
raw: {"id":0,"cmd":"auth","token":"…","api_min":1,"api_max":1}
```

and then answered with a fabricated `app_too_old` claiming a 7–9 daemon. The app took it with no
crash buffer entry, stayed alive, and **did not reconnect when the real daemon came back** — which is
the refusal being terminal, by design.

**One consequence of that worth knowing, found by testing rather than reasoning.** Because the
refusal clears `running`, an app that has been refused stays refused until it is reopened — even
after the user fixes the host. For the app-too-new case that is the likelier one, they will upgrade
the host package and then find the app still saying the host is too old. The cheap alternative is to
retry on a long backoff, minutes rather than seconds, so it heals itself without spamming the
daemon's log. **Not done**, because it is a behavioural choice rather than a bug, and it belongs to
whoever decides how the screen should feel.

The `mediad` half needed no code: the append-only rule is now written at both ends, in
`waydroid-mediad`'s notifier and in [Volumes.kt](../media-app/src/Volumes.kt), beside the constants
somebody would edit.

## What needed building

Per TCP daemon (`btd`, `pwd`):

1. `API_MIN` / `API_MAX` constants replacing `PROTOCOL_VERSION`, with `API_MIN = 1`.
2. `cmd_auth` reads `api_min`/`api_max`, defaulting both to 1 when absent; computes the overlap;
   either replies with `api` (the agreed version) or fails with the structured refusal above.
3. `ev: ready` carries the **agreed** version, not the daemon's maximum.
4. A build-time package-version stamp, sourced from the `.mod`.
5. `btd`'s profile file gains the daemon's range, so the app can see it before opening a socket.

Per app (`bt-app`, `pw-app`):

6. Send the range in `auth`.
7. Store the agreed version and branch on it wherever the format differs.
8. An unsupported-version screen with both directions and the right action for each.

Cross-cutting:

9. `waydroid-mediad` and `media-app`: the append-only rule written where somebody will read it
   before editing the payload — the same place [Volumes.kt](../media-app/src/Volumes.kt) now warns
   about the three-site action string.
10. A line in each `.mod` changelog whenever `API_MAX` moves, since that is the only place a user
    can find out that an app update is now required.

## The compatibility policy, settled 2026-09-30

**The app carries the compatibility, not the daemon. `api_min = api_max - 2`.**

Which side carries it decides which failure disappears, and they are not equally likely:

| Compatibility lives in | The failure it removes | How often that failure happens |
|---|---|---|
| **the app** — wide `api_min` | app ahead of daemon | **the common one**: F-Droid updates in the background |
| the daemon — low `api_min` | app behind daemon | the rare one: needs a user who stopped updating apps |

So an app speaking API 5 also speaks 4 and 3, and it works against any daemon released in that
window without anybody doing anything. The daemon's `api_min` rises only when keeping an old format
alive becomes genuinely unmaintainable, which is a deliberate act with a changelog line.

**A trailing window of two, on a single integer, is the whole rule** — there is no semver here to
take "major versions" from, and mapping one onto the other would only add a translation step to get
wrong.

### The refusal screen is a last resort, not the mechanism

With the app trailing by two, no-overlap should be rare, and the design goal is that the screen is
almost never shown. What should happen far more often is **graceful degradation**: if an app can
speak 5 but the daemon tops out at 3, it connects at 3 and hides whatever 4 and 5 added. Refusing
outright is correct only when the ranges do not intersect at all.

That is worth stating because it changes step 7: the app does not merely *record* the agreed version,
it gates features on it.

### No downgrade button

Tempting, and wrong, for one reason that overrides the rest: **F-Droid's auto-update would push the
user straight back into the break.** A downgrade is not a stable state unless they also turn off
updates for that app, so the button would hand out a loop and call it a fix. Android's downgrade
handling is the secondary objection — same signing key, but a lower `versionCode` needs
`allowDowngrade`, and an older app may not read the newer app's stored data.

It stays as a *documented* escape hatch for the one case that has no other answer: a host that cannot
be updated at all, because the distro has not packaged the newer daemon yet. That belongs in the
user docs, not behind a button.

## Publishing: f-droid.org, and CI cannot deploy to it

Settled 2026-09-30: **f-droid.org**, for the discovery and the update path an own repository does not
give. One correction to how this gets built, because it changes the CI design:

**You do not deploy to f-droid.org.** Submission is a merge request against the `fdroiddata` GitLab
repository carrying a `metadata/<applicationId>.yml`; F-Droid's own buildserver then fetches a
**tagged commit** of the app's repository and builds it. No APK is ever pushed. Publication runs
roughly 24–48 hours behind the metadata merge.

So CI's job is not deployment. It is: make the tag F-Droid builds from, and make that build
reproducible.

| Step | Where |
|---|---|
| tag `v<versionName>` on the app repo — F-Droid requires the tag to match the manifest | app repo CI |
| build, sign with the release key from Actions secrets, publish a GitHub release | app repo CI |
| `metadata/com.systemhalted.<app>.yml` with `Binaries:` pointing at that release asset, plus `AllowedAPKSigningKeys` | one-time MR to `fdroiddata`, then a version bump per release |
| build from source, compare against our binary, publish ours if it reproduces | F-Droid buildserver |

`Binaries:` is what keeps **our** signature on the published APK rather than F-Droid's, and that
matters beyond tidiness: if F-Droid signs and we also ever serve the same application id ourselves,
Android refuses the cross-update and users are stranded on whichever they installed first.

### The real risk is the build, not the pipeline

F-Droid's buildserver can build a non-Gradle project — `build:` takes arbitrary shell, `output:` is a
glob to the resulting APK, `sudo:` can install dependencies — so the hand-rolled
`aapt2`/`kotlinc`/`d8` scripts are not disqualifying. Two things are unproven and should be settled
before the first merge request rather than during review:

- **`kotlinc` is not part of a standard Android build image.** Ours is fetched by `build.sh --deps`
  from a GitHub release; F-Droid builds are network-restricted after the source fetch, so that
  download is the thing most likely to fail. Either `sudo:` installs a distro Kotlin compiler, or the
  app repos move to Gradle for the F-Droid path, which is a real cost against the no-Gradle decision
  every one of these apps was built on.
- **Reproducibility needs deterministic packaging** — zip timestamps and ordering — and the
  toolchain is already pinned hard (cmdline-tools `11076708`, Kotlin `2.0.21`, build-tools `34.0.0`,
  `android-33`), which is the hard part already done.

An own F-Droid repository — `fdroid update` in CI, served from GitHub Pages — remains the cheap
interim while those two are settled, and is what the [docs/53](53-release-readiness.md) debug-keystore
blocker has to be fixed for either way. It is not the destination.
