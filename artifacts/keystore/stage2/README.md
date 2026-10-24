# keystore stage 2 — declare a StrongBox instance and watch keystore2

> **Superseded 2026-10-22: do not run step 2 below.** Stage 2 was never armed, because the clean
> baseline answered it ([docs/73](../../../docs/73-keystore-stage1-engine.md)). Stage 3a then
> measured that the VINTF *fragment* here **breaks boot**. libvintf rejects a second declaration of
> `android.hardware.keymaster@4.0` as a conflict and poisons the whole device manifest, after which
> keymaster and keystore2 crash-loop. The route that works overrides `/vendor/etc/vintf/manifest.xml`
> itself, adding `strongbox` as a second `<instance>` and `<fqname>` inside the existing keymaster
> `<hal>`. That file is derived from the image, so it is not committed here. The feature XML (step 1)
> is still correct. Everything below is kept as the record of what was planned.

These two overlay files are [docs/65](../../../docs/65-tpm-keystore.md) /
[docs/73](../../../docs/73-keystore-stage1-engine.md) **stage 2**: make Android *declare* a StrongBox
secure element with nothing serving it yet, so the first failure tells us how `keystore2` reacts —
[docs/65](../../../docs/65-tpm-keystore.md) open questions 3 and 4. They are **staged here, not
wired into `waydroid-overlay-sync` or any package**, on purpose: applying them is an attended,
reversible test that must be run with the owner at the machine, not something an install does.

## Why this is attended, and the risk

An overlay file is live only at **Waydroid session start** — on bigtab01 that means logging out of
the `waydroid-cage` session at the console and back in ([AGENTS.md](../../../AGENTS.md); neither
`waydroid container restart` nor `systemctl restart waydroid-container.service` applies an overlay).
And the asymmetric risk is open question 4: **if `keystore2` refuses to come up rather than dropping
a declared-but-absent instance, the lockscreen and every app's keys are behind it** — a bad outcome
on a kiosk reachable only from the console. So this is done in two steps, lower risk first, each one
reversible by deleting the file and restarting the session.

## The two files

| File | Overlay target | Effect |
|---|---|---|
| `android.hardware.strongbox_keystore.xml` | `/system/etc/permissions/` | PackageManager advertises `FEATURE_STRONGBOX_KEYSTORE`. Lower risk — PackageManager-facing. |
| `android.hardware.keymaster@4.0-strongbox.xml` | `/vendor/etc/vintf/manifest/` | `keystore2` tries to bind a `strongbox` KeyMint via its `km_compat` HIDL shim. Higher risk — this is the one open question 4 is about. |

## Procedure (with the owner at the machine)

Overlay files go under `/var/lib/waydroid/overlay/…`, but a mounted overlay lowerdir does **not**
pick up a dropped file (AGENTS.md) — stage them in the packaged source
`/usr/lib/waydroid-overlay/…` if `waydroid-overlay-sync` is to place them, or drop them directly and
confirm by reading them from **inside** the container, never by `ls` of the overlay dir.

1. **Feature XML alone.** Place `android.hardware.strongbox_keystore.xml`, restart the session, then
   from inside Android:
   - `pm has-feature android.hardware.strongbox_keystore` → expect `true`
   - confirm the keystore still works normally (screen unlocks; an ordinary app key generates)
   - app-level StrongBox requests should fail (no instance yet) — that is expected, not a fault.
2. **Add the VINTF fragment.** Only if step 1 was clean: place
   `android.hardware.keymaster@4.0-strongbox.xml`, restart the session, and read the keystore log
   (`logcat -b all | grep -iE "keystore2|km_compat|strongbox|keymint"`). The informative outcomes:
   - **declared-but-absent, keystore otherwise healthy** — the good case: stage 3 can serve the
     instance. This answers open question 3 (A13 does surface a HIDL strongbox instance) and 4
     (keystore2 tolerates its absence).
   - **keystore2 wedged / lockscreen broken** — open question 4's bad case. Undo immediately
     (delete the fragment, restart the session) and stage 3 must land behind a `session stop`, not a
     reboot, from the first commit.

## Undo

Delete the file(s) and restart the session. Nothing else is touched; there is no package to remove
and no policy to reload.
