Comment for waydroid/waydroid#2389 (container: harden startup/teardown, schedtune probe, and binder handling)

---

`_validate_session_owner` on `GetSession` changes its contract for callers outside the CLI, and I think unintentionally.

Today `GetSession` answers `{}` when no session is tracked. With the check in front of it, a non-root caller in that state gets `Cannot control a session on behalf of another user` instead, because the guard fails on `"session" not in self.args` before it can distinguish "not yours" from "not there".

`waydroid status` is unaffected — `status.py` catches `DBusException` and prints `Session: STOPPED` — so nothing in the CLI regresses. What does regress is external tooling that polls `id.waydro.Container` over the bus. A session wrapper that asks "is a session already running before I start one?" gets an error in exactly the state where the answer is "no", and can no longer tell that apart from "service is down" or "someone else's session". That is the normal state at the start of every login.

Suggestion: keep returning `{}` when no session is tracked, and apply the ownership check only when there is one. That still refuses to leak another user's session details, which is the point of the change, while leaving the "is anything running?" query answerable:

```python
    def GetSession(self, sender, conn):
        if not actions.initializer.is_initialized(self.args):
            raise RuntimeError("Waydroid is not initialized")
        if "session" not in self.args:
            return {}
        self._validate_session_owner(sender, conn)
        ...
```

The `Stop`/`Freeze`/`Unfreeze` guards look right as they are — there is no useful answer to give for those without a session anyway.
