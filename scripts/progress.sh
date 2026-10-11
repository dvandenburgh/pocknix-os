# progress.sh — read and show make image's progress: the status bar at the bottom of the terminal
# that runs it, and `make status` / `make watch` from any other shell. Sourced after lib.sh by
# build-all.sh and build-status.sh; the writing side (progress_set, hist_*) lives in lib.sh.
#
# The status file is plain KEY=value lines, parsed here rather than sourced: a root build reads a
# file in the user's build/ tree.
#   P_PID P_STATE(running|done|failed|interrupted) P_DEVICE P_STARTED P_ENDED
#   P_STEPS     step names, in order          P_EST   per-step seconds: actual for finished steps,
#   P_STEP      1-based index of the current           the estimate for the rest
#   P_STEP_STARTED  P_STEP_END (0, or the current step's own estimate of its end, e.g. packages)
#   P_DONE      per-step "1" once finished     P_ROUGH 1 when an estimate is a guess (no history)
#   P_DETAIL    what the current step is doing right now

: "${POCKNIX_PROGRESS_FILE:=${PROGRESS_DIR}/status}"
PR_NOW=0 PR_ELAPSED=0 PR_LEFT=0 PR_PCT=0 PR_OVER=0 PR_ALIVE=1

step_label() {
  case "$1" in
    host) printf 'host check' ;;
    firmware) printf 'firmware' ;;
    seed) printf 'published packages' ;;
    kernel) printf 'kernel' ;;
    packages) printf 'packages' ;;
    rootfs) printf 'rootfs' ;;
    image) printf 'SD image' ;;
    *) printf '%s' "$1" ;;
  esac
}

# shellcheck disable=SC2034  # P_* are read by the scripts that source this
progress_load() {  # [file] -> P_* variables; 1 when there is no status to read
  P_PID="" P_STATE="" P_DEVICE="" P_STARTED=0 P_ENDED=0 P_STEPS="" P_EST="" P_STEP=0
  P_STEP_STARTED=0 P_STEP_END=0 P_DONE="" P_ROUGH=0 P_DETAIL="" P_PKG_SECS=0
  local f="${1:-${POCKNIX_PROGRESS_FILE}}" k v
  [ -r "${f}" ] || return 1
  while IFS='=' read -r k v; do
    [[ "${k}" =~ ^P_[A-Z_]+$ ]] && printf -v "${k}" '%s' "${v}"
  done < "${f}" 2>/dev/null
  for k in P_STARTED P_ENDED P_STEP P_STEP_STARTED P_STEP_END P_ROUGH P_PKG_SECS; do
    [[ "${!k}" =~ ^[0-9]+$ ]] || printf -v "${k}" 0
  done
  [ -n "${P_STATE}" ]
}

# From the loaded status: PR_NOW PR_ELAPSED PR_LEFT PR_PCT, PR_OVER=1 when the current step has
# run past its estimate, PR_ALIVE=0 when a "running" build's process is gone (killed, rebooted).
progress_compute() {
  local -a est=() steps=()
  local i n el cur_left
  PR_NOW="$(now_s)" PR_LEFT=0 PR_OVER=0 PR_ALIVE=1
  read -r -a est <<< "${P_EST}"
  read -r -a steps <<< "${P_STEPS}"
  n="${#steps[@]}"
  if [ "${P_STATE}" = running ]; then
    [ -n "${P_PID}" ] && grep -qa build-all "/proc/${P_PID}/cmdline" 2>/dev/null || PR_ALIVE=0
    PR_ELAPSED=$((PR_NOW - P_STARTED))
    if [ "${P_STEP}" -ge 1 ]; then
      el=$((PR_NOW - P_STEP_STARTED))
      if [ "${P_STEP_END}" -gt 0 ]; then cur_left=$((P_STEP_END - PR_NOW))
      else cur_left=$(( ${est[P_STEP - 1]:-0} - el )); fi
      [ "${cur_left}" -ge 0 ] || { PR_OVER=1; cur_left=0; }
      PR_LEFT="${cur_left}"
      for ((i = P_STEP; i < n; i++)); do PR_LEFT=$((PR_LEFT + ${est[i]:-0})); done
    fi
  else
    PR_ELAPSED=$(( (P_ENDED > 0 ? P_ENDED : PR_NOW) - P_STARTED ))
  fi
  [ "${PR_ELAPSED}" -ge 0 ] || PR_ELAPSED=0
  if [ "${P_STATE}" = "done" ]; then PR_PCT=100
  elif [ $((PR_ELAPSED + PR_LEFT)) -gt 0 ]; then
    PR_PCT=$(( PR_ELAPSED * 100 / (PR_ELAPSED + PR_LEFT) ))
    [ "${PR_PCT}" -le 99 ] || PR_PCT=99
  else PR_PCT=0; fi
}

# "~1h40m left" / "~5m left (step running long)" / "~1h40m left, a first-build guess"
progress_left_text() {
  local t
  t="~$(fmt_dur "${PR_LEFT}") left"
  [ "${PR_LEFT}" -gt 0 ] || t="almost done"
  [ "${PR_OVER}" = 0 ] || t+=" (step running long)"
  printf '%s' "${t}"
}

# One line for the status bar, fitted to <cols>.
progress_line() {
  local cols="${1:-80}" n left right bar="" w fill
  local -a steps=()
  read -r -a steps <<< "${P_STEPS}"
  n="${#steps[@]}"
  [ "${P_STEP}" -ge 1 ] || return 0
  left=" pocknix ${P_DEVICE} [${P_STEP}/${n}] $(step_label "${steps[P_STEP - 1]:-}")"
  [ -z "${P_DETAIL}" ] || left+=": ${P_DETAIL}"
  right="$(fmt_dur "${PR_ELAPSED}") in | $(progress_left_text)"
  [ "${PR_LEFT}" -le 0 ] || right+=", done ~$(printf '%(%H:%M)T' $((PR_NOW + PR_LEFT)))"
  [ "${P_ROUGH}" = 0 ] || right+=" (guess)"
  right+=" | ${PR_PCT}% "
  # A bar when there is room for it next to everything else.
  if [ $(( ${#left} + ${#right} + 28 )) -le "${cols}" ]; then
    w=20; fill=$(( PR_PCT * w / 100 ))
    printf -v bar '%*s' "${fill}" ''; bar="${bar// /#}"
    printf -v bar '[%s%*s] ' "${bar}" $((w - fill)) ''
  fi
  right="${bar}${right}"
  if [ $(( ${#left} + ${#right} + 1 )) -gt "${cols}" ]; then
    w=$(( cols - ${#right} - 4 ))
    if [ "${w}" -ge 12 ]; then left="${left:0:w}..."; else left=""; right="${right:0:cols}"; fi
  fi
  printf '%s%*s%s' "${left}" $(( cols - ${#left} - ${#right} > 0 ? cols - ${#left} - ${#right} : 0 )) '' "${right}"
}

# The multi-line report `make status` prints.
progress_report() {
  local -a steps=() est=() done_=()
  local i n mark line when
  read -r -a steps <<< "${P_STEPS}"
  read -r -a est <<< "${P_EST}"
  read -r -a done_ <<< "${P_DONE}"
  n="${#steps[@]}"
  printf -v when '%(%a %H:%M)T' "${P_STARTED}"
  case "${P_STATE}" in
    running)
      if [ "${PR_ALIVE}" = 1 ]; then
        log "pocknix build for ${P_DEVICE}: running for $(fmt_dur "${PR_ELAPSED}") (started ${when}, pid ${P_PID})"
      else
        warn "pocknix build for ${P_DEVICE}: stopped at step ${P_STEP}/${n} without finishing (process ${P_PID} is gone: killed, or the machine restarted). Run it again: finished steps are skipped."
      fi ;;
    "done") ok "pocknix build for ${P_DEVICE}: finished in $(fmt_dur "${PR_ELAPSED}") (started ${when})" ;;
    interrupted) warn "pocknix build for ${P_DEVICE}: interrupted at step ${P_STEP}/${n} after $(fmt_dur "${PR_ELAPSED}") (started ${when})" ;;
    *) warn "pocknix build for ${P_DEVICE}: failed at step ${P_STEP}/${n} after $(fmt_dur "${PR_ELAPSED}") (started ${when}); its output says why" ;;
  esac
  for ((i = 0; i < n; i++)); do
    if [ "${done_[i]:-0}" = 1 ]; then
      mark=" ok"; line="$(fmt_dur "${est[i]:-0}")"
    elif [ "$((i + 1))" = "${P_STEP}" ] && [ "${P_STATE}" != "done" ]; then
      if [ "${P_STATE}" = running ] && [ "${PR_ALIVE}" = 1 ]; then
        mark=">>>"; line="$(fmt_dur $((PR_NOW - P_STEP_STARTED))) so far"
        [ -z "${P_DETAIL}" ] || line+="  ${P_DETAIL}"
      else
        mark="  x"; line="${P_DETAIL}"
      fi
    else
      mark="   "; line="~$(fmt_dur "${est[i]:-0}")"
    fi
    printf '  %s %d/%d  %-20s %s\n' "${mark}" $((i + 1)) "${n}" "$(step_label "${steps[i]}")" "${line}"
  done
  if [ "${P_STATE}" = running ] && [ "${PR_ALIVE}" = 1 ]; then
    line="  $(progress_left_text)"
    [ "${PR_LEFT}" -le 0 ] || line+=", done around $(printf '%(%H:%M)T' $((PR_NOW + PR_LEFT)))"
    [ "${P_ROUGH}" = 0 ] || line+=" (a guess: some steps have not been timed on this host yet)"
    printf '%s\n' "${line}"
  fi
}

# --- the status bar ---------------------------------------------------------------------------
# The last terminal row is kept out of the scrolling region (as apt does), so build output scrolls
# above a line that redraws every second. A plain terminal, a pipe or POCKNIX_STATUS_BAR=off keeps
# ordinary output.
SB_PID=""
_sb_rows() { local r c; read -r r c < <(stty size < /dev/tty 2>/dev/null) && [ "${r:-0}" -gt 0 ] && printf '%s %s\n' "${r}" "${c}"; }

# Reserve the bottom row: move down a line (scrolling if at the bottom), fence it off, step back up.
_sb_reserve() { printf '\n\0337\033[1;%dr\0338\033[1A' $(( $1 - 1 )); }

statusbar_start() {
  [ "${POCKNIX_STATUS_BAR:-on}" = on ] && [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] || return 0
  local rows cols
  read -r rows cols < <(_sb_rows) || return 0
  [ "${rows:-0}" -ge 6 ] && [ "${cols:-0}" -ge 40 ] || return 0
  _sb_reserve "${rows}"
  printf '\033[22;0t'   # push the window title; statusbar_stop pops it (where the terminal can)
  (
    set +eu
    trap 'exit 0' TERM
    trap '' INT
    last="${rows}"
    while :; do
      if read -r rows cols < <(_sb_rows); then
        # A resize can drop the scrolling region: fence the (new) bottom row off again.
        [ "${rows}" = "${last}" ] || { _sb_reserve "${rows}"; last="${rows}"; }
        if progress_load && [ "${P_STEP}" -ge 1 ]; then
          progress_compute
          read -r -a steps <<< "${P_STEPS}"
          printf '\0337\033[%d;1H\033[2K\033[7m%s\033[0m\0338\033]0;pocknix %s/%s %s, %s\007' \
            "${rows}" "$(progress_line "${cols}")" "${P_STEP}" "${#steps[@]}" \
            "$(step_label "${steps[P_STEP - 1]}")" "$(progress_left_text)"
        fi
      fi
      sleep 1 & wait $!
    done
  ) &
  SB_PID=$!
}

statusbar_stop() {  # [final window title]
  [ -n "${SB_PID}" ] || return 0
  kill "${SB_PID}" 2>/dev/null || true
  wait "${SB_PID}" 2>/dev/null || true
  SB_PID=""
  local rows cols
  read -r rows cols < <(_sb_rows) || rows=""
  # Whole screen scrolls again; the bar's row is cleared.
  if [ -n "${rows}" ]; then printf '\0337\033[r\033[%d;1H\033[2K\0338' "${rows}"; else printf '\0337\033[r\0338'; fi
  printf '\033]0;%s\007\033[23;0t' "${1:-pocknix build}"
}
