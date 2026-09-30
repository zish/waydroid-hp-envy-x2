# 58 — Versioning the host daemons and their APIs separately

*Opened 2026-09-30, at the owner's request, ahead of the F-Droid split
([docs/53](53-release-readiness.md) item 2). Design only — nothing below is built.*

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

## What needs building

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

## Decisions still open

- **Does `api_min` ever rise?** Keeping it at 1 forever is the friendliest policy and the most
  expensive to maintain, because every format the daemon has ever spoken stays in the code. A policy
  like "support the previous two API versions" is cheaper and needs stating now, since it determines
  whether step 2 above is a branch or a dispatch table.
- **Is the F-Droid target our own repository or f-droid.org?** The prompt's URL depends on it, and
  that is the other decision still open from [docs/53](53-release-readiness.md) item 2.
- **Does the app-too-new screen offer a downgrade?** F-Droid can install an older APK. Offering it
  would recover the common failure without touching the host, at the cost of telling users to move
  backwards.
