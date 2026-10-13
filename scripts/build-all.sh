#!/usr/bin/env bash
# build-all.sh — ./build.sh and make image: from a checkout to a flashable SD image in one command.
# Each step is the script behind its own make target; the kernel and packages skip what is
# already current, so a re-run redoes only the rootfs and the image. Run it as yourself: the root
# steps share one sudo. While it runs, a status bar on the terminal's bottom row shows the step,
# the time so far and the time left, estimated from how long each step and each package took on
# this host the last time (scripts/progress.sh); `make status` shows the same from another shell.

usage() {
  cat <<'EOF'
usage: ./build.sh [options]          (the same as: make image, scripts/build-all.sh)

Builds a flashable SD image from this checkout: host check -> published packages -> kernel ->
packages -> rootfs -> SD image (build/image/<soc>/pocknix-<soc>-sd.img). What is already
current is skipped, so running it again after an interruption carries on where it stopped. Run it
as yourself: it asks for sudo once.

Image options
  --ssh                 SSH server on in the image (root and deck log in with the password)
  --no-ssh              SSH off, even when SSH=1 or SD_SSH=on is in the environment
  --password PW         root and deck password (default: pocknix, which is public)
  --wifi SSID           join this Wi-Fi network on first boot (needs --wifi-psk)
  --wifi-psk PSK        its passphrase
  --wifi-country CC     2-letter regulatory country, needed for 5 GHz (e.g. US)
  --emulation           bake in the emulation layer (ES-DE and the emulators)

Build options
  -d, --device NAME     image target, a family under devices/ (listed below)
  -j, --jobs N          kernel compile jobs (default: every core)
  --no-sd-image         stop at the finished rootfs (build/rootfs), without the SD image
  --no-seed             compile every package instead of downloading the published ones
  --no-host-setup       stop when host packages are missing instead of installing them
  --no-status-bar       plain output, no status line at the bottom of the terminal
  -h, --help            this help

Every option has an environment / make variable form, e.g. `make image SSH=1 SD_IMAGE=off`,
or `export SSH=1` to turn SSH on for every build:
  SSH=1 (or SD_SSH=on)  SD_ROOT_PASSWORD=  SD_WIFI_SSID=  SD_WIFI_PSK=  SD_WIFI_COUNTRY=
  POCKNIX_EMULATION=1  DEVICE=  JOBS=  SD_IMAGE=off  POCKNIX_SEED=off  POCKNIX_HOST_SETUP=off
  POCKNIX_STATUS_BAR=off   (switches take on/off, 1/0, yes/no or true/false)

From another shell: make status shows how far it is and the time left; make watch follows it.
EOF
  printf '\nFamilies for --device (default: DEVICE in config/pocknix.conf):\n'
  local p
  for p in "$(dirname "$0")"/../devices/*/profile.conf; do
    printf '  %-20s %s\n' "$(basename "$(dirname "${p}")")" "$(sed -n 's/^DEVICE_PRETTY="\(.*\)"$/\1/p' "${p}")"
  done
}

# --- options: before lib.sh, which reads DEVICE and the SD_* knobs from the environment --------
as_root=0
bad() { printf 'error: %s (./build.sh --help lists the options)\n' "$1" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  opt="$1" val="" inline=0
  case "${opt}" in --*=*) val="${opt#*=}"; opt="${opt%%=*}"; inline=1 ;; esac
  case "${opt}" in
    --password|--wifi|--wifi-psk|--wifi-country|-d|--device|-j|--jobs)
      if [ "${inline}" = 0 ]; then
        [ "$#" -ge 2 ] || bad "${opt} needs a value"
        val="$2"; shift
      fi ;;
    *) [ "${inline}" = 0 ] || bad "${opt} takes no value" ;;
  esac
  case "${opt}" in
    --as-root) as_root=1 ;;   # internal: the root half, re-run under sudo
    --ssh) export SSH=on ;;
    --no-ssh) export SSH=off ;;
    --password) export SD_ROOT_PASSWORD="${val}" ;;
    --wifi) export SD_WIFI_SSID="${val}" ;;
    --wifi-psk) export SD_WIFI_PSK="${val}" ;;
    --wifi-country) export SD_WIFI_COUNTRY="${val^^}" ;;
    --emulation) export POCKNIX_EMULATION=1 ;;
    -d|--device) export DEVICE="${val}" ;;
    -j|--jobs) [[ "${val}" =~ ^[1-9][0-9]*$ ]] || bad "--jobs takes a number, not '${val}'"
               export JOBS="${val}" ;;
    --no-sd-image|--rootfs-only) export SD_IMAGE=off ;;
    --no-seed) export POCKNIX_SEED=off ;;
    --no-host-setup) export POCKNIX_HOST_SETUP=off ;;
    --no-status-bar) export POCKNIX_STATUS_BAR=off ;;
    -h|--help) usage; exit 0 ;;
    *) bad "unknown option '${opt}'" ;;
  esac
  shift
done

progress_from_env="${POCKNIX_PROGRESS_FILE:-}"   # set: this is the root half of a running build
source "$(dirname "$0")/lib.sh"
source "${POCKNIX_ROOT}/scripts/progress.sh"
need_linux
S="${POCKNIX_ROOT}/scripts"

# Switches, normalised so the root half and every step read the same thing.
SD_IMAGE="$(onoff SD_IMAGE "${SD_IMAGE:-on}")"
POCKNIX_SEED="$(onoff POCKNIX_SEED "${POCKNIX_SEED:-on}")"
POCKNIX_HOST_SETUP="$(onoff POCKNIX_HOST_SETUP "${POCKNIX_HOST_SETUP:-on}")"
POCKNIX_STATUS_BAR="$(onoff POCKNIX_STATUS_BAR "${POCKNIX_STATUS_BAR:-on}")"
emu="$(onoff POCKNIX_EMULATION "${POCKNIX_EMULATION:-0}")"
if [ "${emu}" = on ]; then POCKNIX_EMULATION=1; else POCKNIX_EMULATION=0; fi
export SD_SSH SD_IMAGE POCKNIX_SEED POCKNIX_HOST_SETUP POCKNIX_STATUS_BAR POCKNIX_EMULATION

# --- the plan ----------------------------------------------------------------------------------
STEPS=(host)
if [ "${POCKNIX_SEED}" = on ] && [ -n "${POCKNIX_REPO_URL}" ]; then STEPS+=(seed); fi
STEPS+=(kernel packages rootfs)
if [ "${SD_IMAGE}" = on ]; then STEPS+=(image); fi
FIRST_ROOT=2   # the host check runs as you, everything from here on as root

step_target() {
  case "$1" in
    host) printf 'make check' ;; seed) printf 'make seed' ;;
    kernel) printf 'make kernel' ;; packages) printf 'make packages' ;;
    rootfs) printf 'make build' ;; image) printf 'make sd-image' ;;
  esac
}

# --- the steps -----------------------------------------------------------------------------------
# Only the host lines count here: a fresh checkout fails make check's layout lines until make sync.
host_problems() {
  "${S}/check.sh" 2>&1 \
    | grep -E '^  (host tool|cross compiler|qemu aarch64 binfmt|checkout filesystem|btrfs)' \
    | grep -Ev ' ok$' || true
}
step_host() {
  local problems
  # sudo opens a fresh pty for the root steps (use_pty), so a host whose /dev/pts is covered (an
  # interrupted build's chroot mounts, before lib.sh made them private) fails there, two steps in.
  if [ "$(id -u)" -ne 0 ] && [ "$(stat -f -c %T /dev/pts 2>/dev/null)" != devpts ]; then
    die "/dev/pts is not mounted here, so sudo cannot open the terminal it needs for the root steps
  (\"sudo: unable to allocate pty: No such device\"). An interrupted build's chroot mounts covered it.
  On WSL: run 'wsl --shutdown' in PowerShell, reopen Ubuntu and run this again.
  Elsewhere: reboot, or as root unmount what 'findmnt -R ${BUILD_DIR}' lists and remount /dev/pts."
  fi
  problems="$(host_problems)"
  # host-setup installs packages and fixes qemu's binfmt; the filesystem and the kernel it can't.
  if [ -n "${problems}" ] && [ "${POCKNIX_HOST_SETUP}" = on ] \
     && ! grep -qE '^  (checkout filesystem|btrfs)' <<< "${problems}"; then
    warn "this host is missing build tools:"
    printf '%s\n' "${problems}" >&2
    log "installing them with make host-setup (uses sudo; --no-host-setup stops here instead)"
    progress_detail "installing host packages (make host-setup)"
    "${S}/host-setup.sh"
    problems="$(host_problems)"
  fi
  [ -z "${problems}" ] || die "this host is not ready for an image build ('make host-setup' fixes most of it, docs/building/troubleshooting.md the rest):
${problems}"
}

step_seed()     { "${S}/seed-localrepo.sh"; }
step_kernel()   { "${S}/build-kernel.sh"; }
step_packages() { "${S}/pending.sh"; "${S}/build-packages.sh"; }
step_rootfs()   { POCKNIX_PACKAGES_DONE=1 "${S}/build-image.sh"; }
step_image()    { "${S}/build-sd-image.sh"; }

# --- estimates -------------------------------------------------------------------------------------
# Each step's last duration on this host (build/progress/history-<soc>), or a first-build guess
# that sets EST_ROUGH. Steps that will find nothing to do (a current kernel, current packages) are
# predicted with the same checks they make themselves.
EST_ROUGH=0
slow() { if [ "$(uname -m)" = aarch64 ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }  # <qemu> <native>

seed_has_work() {  # a package missing from build/localrepo, or older than its dir (as seed sees it)
  local repo d p v a f
  while IFS='|' read -r repo d p v a; do
    [ "${p}" != "${KERNEL_PKG}" ] || continue
    f="$(artifact_file "${repo}" "${p}-${v}-${a}")" || return 0
    artifact_current "${f}" "${d}" "${p}" || return 0
  done < <(local_artifacts)
  return 1
}

# The compiles still to come. Before the seed step has run, count only what it cannot supply:
# packages with uncommitted changes, and the kernel package (never published).
estimate_packages() {
  local -A kind=()
  local d p v a n e g base seed_ahead=0 changed="" i
  for ((i = 0; i < ${#STEPS[@]}; i++)); do
    if [ "${STEPS[i]}" = seed ] && [ "${DONE_ARR[i]:-0}" != 1 ]; then seed_ahead=1; fi
  done
  [ "${seed_ahead}" = 0 ] \
    || changed="$(git -c safe.directory='*' -C "${POCKNIX_ROOT}" status --porcelain -- packages devices 2>/dev/null || true)"
  while IFS='|' read -r _ d p v a; do
    # Seed only replaces what is published at this exact version: never the kernel, a dir with
    # uncommitted changes, or a fork's own release (pkgrel N.M on top of upstream's N).
    if [ "${seed_ahead}" = 1 ] && [ "${p}" != "${KERNEL_PKG}" ] && [[ "${v##*-}" != *.* ]] \
       && ! grep -qF " ${d#"${POCKNIX_ROOT}"/}/" <<< "${changed}"; then continue; fi
    n="$(pkg_name "${d}")"   # the history keys on it (the kernel recipe's dir is not its name)
    if [ "${a}" = any ] && [ "${kind[${n}]:-}" != native ]; then kind[${n}]=any; else kind[${n}]=native; fi
  done < <(pending_artifacts)
  # The steady cost of the step: chroot upgrade and a skip check per package (more the first
  # time, when the build chroot is created).
  base="$(hist_get packages.base)"
  if [ -z "${base}" ]; then base=300; EST_ROUGH=1; fi
  if [ ! -x "${BUILD_DIR}/pkgbuild-root-${SOC}/usr/bin/makepkg" ] && [ "${base}" -lt 1200 ]; then base=1200; fi
  EST_S="${base}"
  for n in "${!kind[@]}"; do
    read -r e g < <(pkg_estimate "${n}" "${kind[${n}]}")
    EST_S=$((EST_S + e))
    [ "${g}" = 0 ] || EST_ROUGH=1
  done
}

estimate_step() {  # <step> -> EST_S seconds, EST_KEY the history key its time is recorded under
  local h def=0
  EST_KEY=""
  case "$1" in
    host) EST_S=10; return 0 ;;
    seed) if seed_has_work; then EST_KEY=seed; def=900; else EST_S=20; return 0; fi ;;
    kernel)
      if "${S}/build-kernel.sh" --is-current >/dev/null 2>&1; then EST_S=5; return 0; fi
      EST_KEY=kernel; def=2400 ;;
    packages) estimate_packages; return 0 ;;   # times itself: per package + packages.base
    rootfs) EST_KEY=rootfs; def="$(slow 3600 1500)" ;;
    image) EST_KEY=image; def=900 ;;
  esac
  h="$(hist_get "${EST_KEY}")"
  if [ -n "${h}" ]; then EST_S="${h}"; else EST_S="${def}"; EST_ROUGH=1; fi
}

# State shared by both halves through the status file: per-step seconds and done flags.
EST_ARR=() DONE_ARR=() KEY_ARR=()
load_state() {
  progress_load || true
  read -r -a EST_ARR <<< "${P_EST}"
  read -r -a DONE_ARR <<< "${P_DONE}"
}
reestimate() {  # <from step index>: estimate it and every later step afresh
  local j
  load_state
  EST_ROUGH=0
  for ((j = $1 - 1; j < ${#STEPS[@]}; j++)); do
    estimate_step "${STEPS[j]}"
    EST_ARR[j]="${EST_S}"; KEY_ARR[j]="${EST_KEY}"
  done
  progress_set P_EST "${EST_ARR[*]}" P_ROUGH "${EST_ROUGH}"
}

run_step() {  # <index>: run it, then record how long it took
  local i="$1" name="${STEPS[$1 - 1]}" t0 dur
  t0="$(now_s)"
  progress_set P_STEP "${i}" P_STEP_STARTED "${t0}" P_STEP_END 0 P_DETAIL "" P_PKG_SECS 0
  if progress_load; then progress_compute; fi
  echo
  log "[${i}/${#STEPS[@]}] $(step_label "${name}") ($(step_target "${name}")) - $(fmt_dur "${PR_ELAPSED}") in, $(progress_left_text)"
  "step_${name}"
  dur=$(( $(now_s) - t0 ))
  if [ -n "${KEY_ARR[i - 1]:-}" ]; then hist_set "${KEY_ARR[i - 1]}" "${dur}"; fi
  if [ "${name}" = packages ]; then
    progress_load || true
    hist_set packages.base $(( dur > P_PKG_SECS ? dur - P_PKG_SECS : 0 ))
  fi
  load_state
  EST_ARR[i - 1]="${dur}"; DONE_ARR[i - 1]=1
  progress_set P_EST "${EST_ARR[*]}" P_DONE "${DONE_ARR[*]}" P_DETAIL "" P_STEP_END 0
  ok "$(step_label "${name}"): $(fmt_dur "${dur}")"
}

root_phase() {
  local i
  need_root image
  for ((i = FIRST_ROOT; i <= ${#STEPS[@]}; i++)); do
    reestimate "${i}"
    run_step "${i}"
  done
}

# A failure or Ctrl-C in either half marks the status file (once this run owns it: a run refused
# because another is going must leave that one's alone); the user half also takes the bar down.
OWN_STATUS="${as_root}"
on_exit() {
  local rc=$? state=failed
  [ "${rc}" -ne 0 ] || return 0
  [ "${rc}" -ne 130 ] || state=interrupted
  [ "${OWN_STATUS}" = 1 ] || return 0
  if progress_load && [ "${P_STATE}" = running ]; then
    progress_set P_STATE "${state}" P_ENDED "$(now_s)"
  fi
  [ "${as_root}" = 0 ] || return 0
  statusbar_stop "pocknix build ${state}"
  if [ "${P_STEP:-0}" -ge 1 ]; then
    echo >&2
    warn "build ${state} at step ${P_STEP}/${#STEPS[@]}; run it again to carry on (finished steps are skipped), 'make status' for the timings"
  fi
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "${as_root}" = 1 ]; then
  [ -n "${progress_from_env}" ] || die "--as-root is build-all.sh's own: run ./build.sh or make image"
  root_phase
  exit 0
fi

# --- the user half -----------------------------------------------------------------------------
if [ -n "${SD_WIFI_SSID}" ] && [ -z "${SD_WIFI_PSK}" ]; then
  die "Wi-Fi '${SD_WIFI_SSID}' needs its passphrase too: --wifi-psk '<passphrase>' (or SD_WIFI_PSK=)"
fi
# One build per checkout: two would share build/rootfs and the chroots.
if progress_load && [ "${P_STATE}" = running ] && [ -n "${P_PID}" ] \
   && grep -qa build-all "/proc/${P_PID}/cmdline" 2>/dev/null; then
  die "a build is already running in this checkout (pid ${P_PID}): 'make watch' follows it"
fi

mkdir -p "${PROGRESS_DIR}" 2>/dev/null || true
[ -w "${PROGRESS_DIR}" ] \
  || warn "${PROGRESS_DIR} is not writable, so there is no status bar or time estimate: sudo chown -R $(id -un) ${PROGRESS_DIR}"
export POCKNIX_PROGRESS_FILE="${PROGRESS_DIR}/status"
OWN_STATUS=1
rm -f "${POCKNIX_PROGRESS_FILE}" 2>/dev/null || true
blank=(); for _ in "${STEPS[@]}"; do blank+=(0); done
progress_set P_PID "$$" P_STATE running P_DEVICE "${DEVICE}" P_STARTED "$(now_s)" P_ENDED 0 \
  P_STEPS "${STEPS[*]}" P_STEP 0 P_EST "${blank[*]}" P_DONE "${blank[*]}"
reestimate 1

plan=""; for s in "${STEPS[@]}"; do plan+="${plan:+ > }$(step_label "${s}")"; done
progress_load || true
total=0; for e in "${EST_ARR[@]}"; do total=$((total + e)); done
log "pocknix image build for ${DEVICE} (${DEVICE_PRETTY:-${SOC}}): ${plan}"
if [ "${SD_IMAGE}" = on ]; then
  echo "    image: SSH $([ "${SD_SSH}" = on ] && echo ON || echo off)," \
       "Wi-Fi ${SD_WIFI_SSID:-none}, emulation layer $([ "${POCKNIX_EMULATION}" = 1 ] && echo baked in || echo left out)," \
       "password $([ "${SD_ROOT_PASSWORD}" = pocknix ] && echo "pocknix (default)" || echo "custom")"
else
  echo "    stops at the rootfs (build/rootfs): no SD image"
  if [ "${SD_SSH}" = on ] || [ -n "${SD_WIFI_SSID}" ] || [ "${SD_ROOT_PASSWORD}" != pocknix ]; then
    warn "SSH, Wi-Fi and the password are set when the SD image is made: give them to 'make sd-image' later"
  fi
fi
[ -n "${POCKNIX_REPO_URL}" ] || warn "POCKNIX_REPO_URL is empty: nothing to seed from, so every package compiles"
echo "    estimated time: ~$(fmt_dur "${total}")$([ "${P_ROUGH}" = 1 ] && echo ", a guess until this host has timed each step once"); 'make status' or 'make watch' from another shell"
statusbar_start

for ((i = 1; i < FIRST_ROOT; i++)); do
  [ "${i}" = 1 ] || reestimate "${i}"
  run_step "${i}"
done

if [ "$(id -u)" -eq 0 ]; then
  root_phase
else
  # sudo resets the environment, so pass on what shapes the build (DEVICE=, SD_SSH=, ...).
  fwd=()
  while IFS= read -r v; do fwd+=("${v}=${!v}"); done < <(compgen -e | grep -E \
    '^(DEVICE|JOBS|CROSS_COMPILE|SSH|(DISTRIBUTION|BUILD|CACHE|PKG_CACHE|VENDOR|ROOTFS|LOCALREPO|LOCALREPO_SHARED|IMAGE|PROGRESS)_DIR|(SD|POCKNIX|ROCKNIX|KERNEL|ALARM)_[A-Z0-9_]+)$' \
    || true)
  echo
  log "the steps from here on need root: asking sudo once"
  sudo env "${fwd[@]}" "${S}/build-all.sh" --as-root
fi

progress_set P_STATE "done" P_ENDED "$(now_s)" P_DETAIL ""
statusbar_stop "pocknix build done"
progress_load || true
progress_compute
summary=""
read -r -a EST_ARR <<< "${P_EST}"
for ((i = 0; i < ${#STEPS[@]}; i++)); do
  summary+="${summary:+, }$(step_label "${STEPS[i]}") $(fmt_dur "${EST_ARR[i]:-0}")"
done
echo
ok "pocknix ${DEVICE} build finished in $(fmt_dur "${PR_ELAPSED}"): ${summary}"
if [ "${SD_IMAGE}" = off ]; then
  log "rootfs ready in ${ROOTFS_DIR}; 'sudo make sd-image' (or ./build.sh without --no-sd-image) turns it into an SD image"
fi
