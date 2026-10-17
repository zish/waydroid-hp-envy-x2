#!/usr/bin/env python3
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
"""Repository policy checks that need nothing but the tree itself.

Each check is a rule the project already holds and used to enforce by memory.
They are stdlib-only and read only tracked files, so they run identically on
the dev box, in lefthook's pre-push and on a GitHub runner -- tests/run.sh's
`policy` suite calls this with no arguments, which runs all of them.

  binaries   No binary may be tracked unless tests/binary-allowlist names it,
             with its sha256. AGENTS.md, "no binaries from external sources",
             and docs/54: before this, a new vendor .so needed someone to
             notice it in review, and an allowed path could silently take on
             different bytes. The hash makes a rebuilt binary a deliberate,
             reviewed edit to the allowlist, on a signed commit.

Usage:
  tests/policy.py [check ...]     # default: every check
"""

import hashlib
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def tracked():
    """Every tracked path that exists in the work tree, repo-relative."""
    out = subprocess.run(["git", "-C", REPO, "ls-files", "-z"],
                         check=True, capture_output=True).stdout
    paths = [p.decode() for p in out.split(b"\0") if p]
    # A path deleted in the work tree but not yet in the index is the
    # committer's business, not a policy violation.
    return [p for p in paths if os.path.isfile(os.path.join(REPO, p))]


def is_binary(path):
    """git's own test: a NUL in the first 8000 bytes."""
    with open(os.path.join(REPO, path), "rb") as f:
        return b"\0" in f.read(8000)


def sha256(path):
    h = hashlib.sha256()
    with open(os.path.join(REPO, path), "rb") as f:
        for block in iter(lambda: f.read(1 << 16), b""):
            h.update(block)
    return h.hexdigest()


def load_allowlist(name):
    """{path: sha256} from a "<sha256>  <path>" file, sha256sum's format."""
    allowed = {}
    with open(os.path.join(REPO, "tests", name)) as f:
        for n, line in enumerate(f, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            digest, _, path = line.partition("  ")
            if len(digest) != 64 or not path:
                raise SystemExit(f"tests/{name}:{n}: expected '<sha256>  <path>'")
            allowed[path] = digest
    return allowed


def check_binaries(paths):
    allowed = load_allowlist("binary-allowlist")
    problems = []
    seen = set()
    for p in paths:
        if not is_binary(p):
            continue
        seen.add(p)
        want = allowed.get(p)
        if want is None:
            problems.append(f"{p}: binary file not in tests/binary-allowlist")
        elif sha256(p) != want:
            problems.append(f"{p}: bytes differ from tests/binary-allowlist "
                            f"(now {sha256(p)})")
    # A stale entry is harmless today and a hole tomorrow: it pre-approves
    # whatever binary next lands at that path.
    for p in sorted(set(allowed) - seen):
        problems.append(f"{p}: in tests/binary-allowlist but not a tracked binary")
    return len(seen), problems


CHECKS = {
    "binaries": (check_binaries, "binary files"),
}


def main(argv):
    names = argv or list(CHECKS)
    unknown = [n for n in names if n not in CHECKS]
    if unknown:
        print(f"unknown check: {' '.join(unknown)} (have: {' '.join(CHECKS)})",
              file=sys.stderr)
        return 2
    paths = tracked()
    failed = False
    for name in names:
        fn, what = CHECKS[name]
        count, problems = fn(paths)
        for line in problems:
            print(f"  {line}")
        if problems:
            print(f"FAIL policy {name}: {len(problems)} problem(s) in {count} {what}")
            failed = True
        else:
            print(f"ok   policy {name} ({count} {what})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
