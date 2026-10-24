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

  links      Every relative link in a tracked Markdown file names a path that
             exists, and an #anchor into a Markdown file names one of its
             headings. The docs cross-reference each other by number and by
             section ("docs/42's *Why a private type*"), and a rename
             otherwise breaks them silently. Links outside the repository are
             not followed: that needs network, and their rot is not ours.

  xml        Every tracked XML file parses. Most are Android's: app manifests,
             resources, and the overlay's feature and VINTF files. A malformed
             one of those does not fail anywhere visible -- PackageManager or
             the VINTF loader skips it and the feature is simply absent, the
             same silence docs/31's stage 0 had to diagnose by hand. xmllint
             would do, but the stdlib parser needs no install.

Usage:
  tests/policy.py [check ...]     # default: every check
"""

import hashlib
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

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


# [text](target "title"), and the reference form "[label]: target".
INLINE = re.compile(r"\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
REFDEF = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s|$)")
FENCE = re.compile(r"^\s*(```|~~~)")
CODESPAN = re.compile(r"(`+).*?\1")
EXTERNAL = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")   # http:, mailto:, ...


def markdown_lines(path, spans=False):
    """(line number, text) outside fenced code, with code spans blanked
    unless [spans] -- a heading's anchor keeps a code span's text."""
    fence = None
    with open(os.path.join(REPO, path), encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            m = FENCE.match(line)
            if m:
                if fence is None:
                    fence = m.group(1)
                elif m.group(1) == fence:
                    fence = None
                continue
            if fence is None:
                yield n, line if spans else CODESPAN.sub("", line)


def slug(heading):
    """GitHub's heading anchor: lowercase, drop punctuation, spaces to '-'."""
    text = re.sub(r"<[^>]+>", "", heading.strip().lower())
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


_anchors = {}


def anchors(path):
    """Every anchor GitHub renders for a Markdown file, duplicates numbered."""
    if path not in _anchors:
        seen = {}
        found = set()
        for _, line in markdown_lines(path, spans=True):
            m = re.match(r"^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$", line)
            if not m:
                continue
            base = slug(m.group(1))
            k = seen.get(base, 0)
            seen[base] = k + 1
            found.add(base if k == 0 else f"{base}-{k}")
        _anchors[path] = found
    return _anchors[path]


def check_links(paths):
    tracked_set = set(paths)
    docs = [p for p in paths if p.endswith(".md")]
    problems = []
    for doc in docs:
        here = os.path.dirname(doc)
        for n, line in markdown_lines(doc):
            for target in INLINE.findall(line) + REFDEF.findall(line):
                if EXTERNAL.match(target):
                    continue
                target, _, anchor = target.partition("#")
                if target:
                    if target.startswith("/"):
                        problems.append(f"{doc}:{n}: absolute link {target}")
                        continue
                    dest = os.path.normpath(os.path.join(here, target))
                    full = os.path.join(REPO, dest)
                    # A link to an untracked file works only on the machine
                    # that has it, so it counts as broken.
                    if not (os.path.exists(full) and
                            (dest in tracked_set or os.path.isdir(full))):
                        problems.append(f"{doc}:{n}: no such file {target}")
                        continue
                else:
                    dest = doc
                if anchor and dest.endswith(".md") and anchor not in anchors(dest):
                    problems.append(f"{doc}:{n}: no heading #{anchor} in {dest}")
    return len(docs), problems


def is_xml(path):
    """By name, or by an XML declaration for files named otherwise."""
    if path.endswith(".xml") or ".xml." in os.path.basename(path):
        return True
    with open(os.path.join(REPO, path), "rb") as f:
        return f.read(5) == b"<?xml"


def check_xml(paths):
    files = [p for p in paths if is_xml(p)]
    problems = []
    for p in files:
        try:
            ET.parse(os.path.join(REPO, p))
        except ET.ParseError as e:
            problems.append(f"{p}: {e}")
    return len(files), problems


CHECKS = {
    "binaries": (check_binaries, "binary files"),
    "links": (check_links, "Markdown files"),
    "xml": (check_xml, "XML files"),
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
