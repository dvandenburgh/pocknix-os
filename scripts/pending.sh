#!/usr/bin/env bash
# pending.sh — list what `make build` would compile, by build-packages.sh's own skip rule: a
# package dir is up to date only when every artifact it names is in build/localrepo, newer than
# every file in the dir (and, for the kernel package, than `make kernel`'s Image). No build
# chroot and no root needed.

source "$(dirname "$0")/lib.sh"

declare -A stale=()
mapfile -t want < <(local_artifacts)
for line in "${want[@]}"; do
  IFS='|' read -r repo d p v a <<< "${line}"
  [ -z "${stale[${d}]:-}" ] || continue
  f="$(artifact_file "${repo}" "${p}-${v}-${a}")" \
    && [ -z "$(find "${d}" -newer "${f}" -print -quit)" ] \
    && ! { [ "${p}" = "${KERNEL_PKG}" ] && [ "${KERNEL_BUILD_DIR}/out/Image" -nt "${f}" ]; } \
    || stale[${d}]=1
done

n=0
for line in "${want[@]}"; do
  IFS='|' read -r repo d p v a <<< "${line}"
  [ -n "${stale[${d}]:-}" ] || continue
  echo "  ${p} ${v}"; n=$((n + 1))
done
if [ "${n}" -gt 0 ]; then
  log "${n} package(s) above would be compiled by 'make build'"
else
  ok "nothing to compile: build/localrepo covers every package"
fi
