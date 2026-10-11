#!/usr/bin/env python3
# Build-time gate for version constraints between this tree's own packages: a depends= that no
# in-tree package satisfies, or a conflicts=/breaks= that hits a sibling's current version, fails
# here rather than at the rootfs step's pacman transaction, most of a build later. Constraints on
# packages this tree does not build resolve against the base repos and are not checked here.
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

# Sources a PKGBUILD in a throwaway bash and prints its package metadata, one "KEY value" line
# each. A split PKGBUILD's package_*() functions may set their own arrays; declare -f prints each
# array assignment on one line, so those lines are evaluated per package.
DUMP = r'''
cd "$(dirname "$1")" && source "$1" >/dev/null 2>&1 || exit 1
printf 'V %s:%s-%s\n' "${epoch:-0}" "${pkgver}" "${pkgrel}"
emit() {
  local x
  for x in "${pkgname[@]}"; do printf 'N %s\n' "$x"; done
  for x in "${provides[@]}"; do printf 'P %s\n' "$x"; done
  for x in "${depends[@]}" "${makedepends[@]}" "${checkdepends[@]}" "${optdepends[@]}"; do printf 'D %s\n' "$x"; done
  for x in "${conflicts[@]}" "${breaks[@]}"; do printf 'C %s\n' "$x"; done
}
fns="$(declare -F | awk '$3 ~ /^package_/ { print $3 }')"
if [ -z "${fns}" ]; then emit; exit 0; fi
for f in ${fns}; do
  (
    pkgname=("${f#package_}")
    eval "$(declare -f "$f" | grep -E '^[[:space:]]*(depends|provides|conflicts|breaks)\+?=\(.*\);?$')"
    emit
  )
done
for x in "${makedepends[@]}" "${checkdepends[@]}"; do printf 'D %s\n' "$x"; done
'''

CONSTRAINT = re.compile(r"^([A-Za-z0-9@._+-]+?)(>=|<=|=|<|>)(\S+)$")


def segcmp(a, b):
    # alpm's rpmvercmp: alternating runs of digits and letters, separators ignored.
    if a == b:
        return 0
    ra = re.findall(r"\d+|[A-Za-z]+", a)
    rb = re.findall(r"\d+|[A-Za-z]+", b)
    for x, y in zip(ra, rb):
        if x.isdigit() and y.isdigit():
            x, y = int(x), int(y)
            if x != y:
                return 1 if x > y else -1
        elif x.isdigit() != y.isdigit():
            return 1 if x.isdigit() else -1
        elif x != y:
            return 1 if x > y else -1
    return (len(ra) > len(rb)) - (len(ra) < len(rb))


def split(v):
    epoch, _, rest = v.rpartition(":")
    ver, _, rel = rest.partition("-")
    return epoch or "0", ver, rel or None


def vercmp(a, b):
    ea, va, ra = split(a)
    eb, vb, rb = split(b)
    c = segcmp(ea, eb) or segcmp(va, vb)
    if c or ra is None or rb is None:
        return c
    return segcmp(ra, rb)


def holds(have, op, want):
    c = vercmp(have, want)
    return {">=": c >= 0, "<=": c <= 0, "=": c == 0, "<": c < 0, ">": c > 0}[op]


pkgs = []  # (pkgbuild, names, version, deps, conflicts)
offers = {}  # name -> [(version, pkgbuild)]; pkgname and versioned provides= only, as pacman
errors = []
for pb in sorted(glob.glob(os.path.join(ROOT, "packages/*/*/PKGBUILD"))
                 + glob.glob(os.path.join(ROOT, "devices/*/packages/*/PKGBUILD"))):
    rel = os.path.relpath(pb, ROOT)
    r = subprocess.run(["bash", "-c", DUMP, "_", pb], capture_output=True, text=True)
    if r.returncode != 0:
        errors.append(f"{rel}: could not be sourced")
        continue
    ver, names, deps, conflicts = None, [], [], []
    for line in r.stdout.splitlines():
        key, _, val = line.partition(" ")
        if key == "V":
            ver = val
        elif key == "N":
            names.append(val)
            offers.setdefault(val, []).append((ver, rel))
        elif key == "P":
            m = re.match(r"^([^=<>]+)=(\S+)$", val)
            if m:
                offers.setdefault(m.group(1), []).append((m.group(2), rel))
        elif key == "D":
            deps.append(val.split(":", 1)[0].strip())  # optdepends carry ": why"
        elif key == "C":
            conflicts.append(val)
    pkgs.append((rel, names, deps, conflicts))

for rel, names, deps, conflicts in pkgs:
    for d in sorted(set(deps)):
        m = CONSTRAINT.match(d)
        if not m or m.group(1) not in offers:
            continue
        name, op, want = m.groups()
        if not any(holds(v, op, want) for v, _ in offers[name]):
            have = ", ".join(sorted({v.removeprefix("0:") for v, _ in offers[name]}))
            errors.append(f"{rel}: depends on {d}, the tree builds {name} {have}")
    for c in sorted(set(conflicts)):
        m = CONSTRAINT.match(c)
        if not m or m.group(1) in names:
            continue
        name, op, want = m.groups()
        for v, src in offers.get(name, []):
            if holds(v, op, want):
                errors.append(f"{rel}: conflicts with {c}, the tree builds {name} {v.removeprefix('0:')} ({src})")

for e in errors:
    print(e)
sys.exit(1 if errors else 0)
