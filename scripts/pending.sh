#!/usr/bin/env bash
# pending.sh — list what `make build` would compile, by build-packages.sh's own skip rule: a
# package dir is up to date only when every artifact it names is in build/localrepo, newer than
# every file in the dir (and, for the kernel package, than `make kernel`'s Image). No build
# chroot and no root needed. The rule itself is pending_artifacts in lib.sh.

source "$(dirname "$0")/lib.sh"

n=0
while IFS='|' read -r _repo _dir p v _arch; do
  echo "  ${p} ${v}"; n=$((n + 1))
done < <(pending_artifacts)
if [ "${n}" -gt 0 ]; then
  log "${n} package(s) above would be compiled by 'make build'"
else
  ok "nothing to compile: build/localrepo covers every package"
fi
