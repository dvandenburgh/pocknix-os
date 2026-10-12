#!/usr/bin/env python3
# Build-time gate for code comments: a comment must stay true about the code next to it, so this
# fails on the four ways they rot. (1) a repo path that no longer exists, (2) lineage or
# validation-status wording, which belongs in PATCHES.md, (3) a version, pkgrel, commit hash or
# date a ledger owns, (4) a pointer into the maintainer's notes: a comment is self-contained,
# repo files are the only thing it may point at. Exceptions go in check-comments.allow as
# "<path glob> :: <regex>" or "<path glob> :: <kind> :: <regex>", one per line.
import fnmatch
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
ALLOW_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-comments.allow")
KINDS = ("dead path", "notes pointer", "provenance/status", "version")

# Tracked text we author. Upstream or generated text is out: patch bodies, synced DTS/configs,
# vendored binaries, built JS, build output, docs (check.sh's doc checks own those).
EXCLUDE = re.compile(
    r"(\.(md|patch|diff|png|svg|jpg|ico|lock|txt|dts|dtsi|gpg|efi|dat|map|json|qml|policy|desktop"
    r"|template|cmake|slangp|opt)$)"
    r"|^(\.github|docs|vendor|build)/|/patches/|/dist/|/dts/|README|provenance|rocknix-reference"
    r"|linux\.aarch64\.conf$|kernel-firmware\.dat$|/bootloader/update\.sh$|package-lock|LICENSE"
)
SLASH = re.compile(r"\.(ts|tsx|js|vdf)$|polkit-1/rules\.d/")
XML = re.compile(r"\.xml$")
PYTHON = re.compile(r"\.py$")

REPO_DIRS = ("scripts", "packages", "devices", "kernel", "config", "overlay")
PATH_RE = re.compile(r"(?<![\w/.\-])(" + "|".join(REPO_DIRS) + r")/[A-Za-z0-9_./<>{}$*\-]+")
# ROCKNIX-tree paths quoted on purpose (their package.mk, device dirs, kernel scripts).
FOREIGN_PATH = re.compile(r"^(packages/(linux|tools)/|devices/SM8|scripts/(config|unpack)|config/arch\.)")

PROVENANCE_RE = re.compile(
    r"\b(modell?ed on|ported from|borrowed from|adapted from|verbatim from|lifted from|copied from"
    r"|same as (armada|ROCKNIX|Valve|SteamOS)|like (armada|ROCKNIX|Valve|SteamOS) (does|do)"
    r"|(armada|ROCKNIX|Valve|SteamOS) (does|do) (this|the same|it)|(armada|ROCKNIX|SteamOS)'s)\b"
    r"|\b(from|per|follows?|mirrors?) (armada|ROCKNIX)\b"
)
STATUS_RE = re.compile(
    r"\b(UNVERIFIED|unverified|untested|VALIDATE on|validated on|validated by|tested on|verified on"
    r"|tune on device|bitten|learned the hard way|for now\b|TODO|FIXME|XXX)\b"
)
NOTES_RE = re.compile(
    r"pocknix-notes|\bdev/[a-z0-9-]+\.md|\bplans/[a-z0-9-]+\.md|maintainer-guide|learnings\.md"
    r"|progress\.md|conventions\.md"
)
VERSION_RE = re.compile(
    r"(?<![\w.])\d+\.\d+\.\d+(?!\.\d)(-\d+)?\b"           # 1.2.3 or 1.2.3-4, not an IPv4
    r"|\b\d+\.\d+-\d+\b"                                   # 0.2-6 style pkgver-pkgrel
    r"|\bv\d+\.\d+(\.\d+)?\b"                              # v0.8.3
    r"|(?:\b(since|before|until|kernel|mesa|gamescope|Qt|scx|FEX|polkit)\s+|[<>]=\s*)\d+\.\d+\b"
    r"|\bFEX-\d{4}\b"
    r"|\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b"  # a commit hash: hex, 7+, mixed
    r"|\b20\d{2}-\d{2}-\d{2}\b"                            # a date
)


def all_tracked(root):
    """git's view when available; a plain walk (build/ excluded via EXCLUDE) when git is missing
    or refuses the checkout, as under sudo in the VM."""
    if os.path.exists(os.path.join(root, ".git")):
        try:
            out = subprocess.run(["git", "-C", root, "ls-files", "-z"], check=True,
                                 capture_output=True).stdout
            return [n for n in out.decode().split("\0") if n]
        except (OSError, subprocess.CalledProcessError):
            pass
    names = []
    for d, dirs, fs in os.walk(root):
        dirs[:] = [x for x in dirs if x not in (".git", "build")]
        for f in fs:
            names.append(os.path.relpath(os.path.join(d, f), root))
    return names


def tracked_files(root):
    return sorted(n for n in all_tracked(root) if not EXCLUDE.search(n))


def comment_lines(path, text):
    """Yield (lineno, text) for full-line comments and python docstrings; code lines with trailing
    comments are skipped (their comment is about the value beside it). Makefile `##` lines are
    make-help, not comments."""
    base = os.path.basename(path)
    first = text.split("\n", 1)[0]
    python = PYTHON.search(path) or (first.startswith("#!") and "python" in first)
    if SLASH.search(path):
        starts, block = ("//", "/*", "*"), ("/*", "*/")
    elif XML.search(path):
        starts, block = ("<!--",), ("<!--", "-->")
    elif python:
        starts, block = ("#", '"""'), ('"""', '"""')
    else:
        if "." not in base and not first.startswith("#") and base not in ("PKGBUILD", "Makefile"):
            return
        starts, block = ("#",), None
    inside = False
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if n == 1 and s.startswith("#!"):
            continue
        if block and inside:
            yield n, s
            if block[1] in s:
                inside = False
            continue
        if s.startswith(starts):
            if base == "Makefile" and s.startswith("##"):
                continue
            if block and s.startswith(block[0]) and block[1] not in s[len(block[0]):]:
                inside = True
            yield n, s


def path_exists(root, token):
    token = token.rstrip(".,:;)]'\"")
    if FOREIGN_PATH.match(token):
        return True
    pattern = re.sub(r"<[^>]*>|\$\{[^}]*\}|\$[A-Za-z_]+", "*", token)
    if pattern.endswith("-") or pattern.endswith("/"):
        pattern += "*"
    if "*" in pattern:
        parts = pattern.split("/")
        cands = [root]
        for part in parts:
            nxt = []
            for c in cands:
                if not os.path.isdir(c):
                    continue
                for e in os.listdir(c):
                    if fnmatch.fnmatch(e, part):
                        nxt.append(os.path.join(c, e))
            cands = nxt
            if not cands:
                return False
        return True
    return os.path.exists(os.path.join(root, pattern))


def load_allow(path):
    """(glob, kind or None, regex). A malformed line is an error, not a blanket exemption."""
    rules = []
    if not os.path.exists(path):
        return rules
    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = [f.strip() for f in line.split(" :: ")]
        if len(fields) == 2:
            glob, kind, regex = fields[0], None, fields[1]
        elif len(fields) == 3 and fields[1] in KINDS:
            glob, kind, regex = fields
        else:
            sys.exit("%s:%d: expected '<glob> :: <regex>' or '<glob> :: <kind> :: <regex>'" % (path, n))
        if not glob or not regex:
            sys.exit("%s:%d: empty glob or regex" % (path, n))
        rules.append((glob, kind, re.compile(regex)))
    return rules


def allowed(rules, path, kind, text):
    return any(fnmatch.fnmatch(path, g) and (k is None or k == kind) and r.search(text)
               for g, k, r in rules)


def scan(root, allow_rules):
    hits = []
    for rel in tracked_files(root):
        full = os.path.join(root, rel)
        try:
            text = open(full, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        for n, s in comment_lines(rel, text):
            found = []
            for m in PATH_RE.finditer(s):
                if not path_exists(root, m.group(0)):
                    found.append(("dead path", m.group(0).rstrip(".,:;)]'\"")))
            m = NOTES_RE.search(s)
            if m:
                found.append(("notes pointer", m.group(0)))
            m = PROVENANCE_RE.search(s) or STATUS_RE.search(s)
            if m:
                found.append(("provenance/status", m.group(0)))
            m = VERSION_RE.search(s)
            if m:
                found.append(("version", m.group(0)))
            hits.extend((rel, n, kind, what) for kind, what in found
                        if not allowed(allow_rules, rel, kind, s))
    return hits


def selftest(allow_rules):
    """Plant one comment of each kind in a scratch copy of the tree; each must fail, and the real
    tree must pass."""
    tmp = tempfile.mkdtemp(prefix="check-comments-")
    try:
        for rel in all_tracked(ROOT):  # every file: the dead-path rule must see the whole tree
            dst = os.path.join(tmp, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(os.path.join(ROOT, rel), dst)
        target = os.path.join(tmp, "scripts/lib.sh")
        planted = [
            "# see scripts/does-not-exist.sh for the helper",
            "# the full story is in pocknix-notes dev/kernel.md",
            "# ported from ROCKNIX's SM8550 quirk 096-cpuidle",
            "# pinned at mesa 26.2.3 until the base moves",
        ]
        with open(target, "a", encoding="utf-8") as f:
            f.write("\n" + "\n".join(planted) + "\n")
        hits = scan(tmp, allow_rules)
        kinds = sorted({h[2] for h in hits if h[0] == "scripts/lib.sh" and h[3] in
                        ("scripts/does-not-exist.sh", "pocknix-notes", "ported from", "26.2.3",
                         "mesa 26.2")})
        for h in hits:
            print("  planted -> %s:%d: %s: %s" % h)
        if kinds != list(KINDS):
            print("selftest FAILED: caught %s, wanted %s" % (kinds, list(KINDS)))
            return 1
        stray = [h for h in hits if h[0] != "scripts/lib.sh"]
        if stray:
            print("selftest FAILED: unplanted hits in the copy: %s" % stray)
            return 1
        print("selftest: each planted comment caught, nothing else flagged")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv):
    allow_rules = load_allow(ALLOW_FILE)
    if "--selftest" in argv:
        return selftest(allow_rules)
    hits = scan(ROOT, allow_rules)
    for rel, n, kind, what in hits:
        print("%s:%d: %s: %s" % (rel, n, kind, what))
    if hits:
        print("%d stale-looking comment(s); fix the comment or add a line to scripts/check-comments.allow"
              % len(hits))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
