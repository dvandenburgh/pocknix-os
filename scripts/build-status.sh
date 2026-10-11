#!/usr/bin/env bash
# build-status.sh — make status / make watch: how far a make image run in this checkout has got,
# and the time it has left, from any shell (the run itself shows the same in its status bar).
#   make status    print it once
#   make watch     redraw it every 2 s until the build ends (Ctrl-C stops watching, not the build)

source "$(dirname "$0")/lib.sh"
source "${POCKNIX_ROOT}/scripts/progress.sh"

if ! progress_load; then
  log "no make image run recorded in this checkout yet (${POCKNIX_PROGRESS_FILE#"${POCKNIX_ROOT}"/})"
  exit 0
fi
if [ "${1:-}" != --watch ]; then
  progress_compute
  progress_report
  exit 0
fi

trap 'echo; exit 0' INT TERM
while :; do
  progress_load || break
  progress_compute
  out="$(progress_report 2>&1)"
  printf '\033[H\033[2J%s\n\n  make watch: Ctrl-C stops watching; the build carries on\n' "${out}"
  { [ "${P_STATE}" = running ] && [ "${PR_ALIVE}" = 1 ]; } || break
  sleep 2
done
