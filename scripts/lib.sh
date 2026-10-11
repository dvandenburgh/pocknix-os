#!/usr/bin/env bash
# Shared helpers for pocknix-os build scripts. Source this first:
#   source "$(dirname "$0")/lib.sh"
# It resolves POCKNIX_ROOT, loads config/pocknix.conf, and defines utilities.

set -euo pipefail

# --- locate project root (parent of scripts/) ------------------------------
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export POCKNIX_ROOT="$(cd "${_lib_dir}/.." && pwd)"

# shellcheck source=../config/pocknix.conf
source "${POCKNIX_ROOT}/config/pocknix.conf"

# --- device profile + per-SoC kernel pins -----------------------------------
# The device profile (devices/<name>/profile.conf) declares everything device-
# specific: SoC, partition labels/names, kernel cmdline, firmware source,
# device packages. It sets SOC, which selects the per-SoC kernel tree and its
# source pins (kernel/<soc>/kernel.conf).
if [ ! -f "${POCKNIX_ROOT}/devices/${DEVICE}/profile.conf" ]; then
  printf 'error: unknown DEVICE=%s — available: %s\n' \
    "${DEVICE}" "$(ls "${POCKNIX_ROOT}/devices" 2>/dev/null | tr '\n' ' ')" >&2
  exit 1
fi
source "${POCKNIX_ROOT}/devices/${DEVICE}/profile.conf"
source "${POCKNIX_ROOT}/kernel/${SOC}/kernel.conf"
# Per-SoC userspace compiler tuning (mesa/gamescope/mangohud/fex-emu are built
# with these; build-packages.sh injects them into makepkg's environment).
source "${POCKNIX_ROOT}/config/tuning/${SOC}.conf"

# Paths derived from the profile (must come after it):
: "${DEVICE_DIR:=${POCKNIX_ROOT}/devices/${DEVICE}}"
: "${KERNEL_DIR:=${POCKNIX_ROOT}/kernel/${SOC}}"
: "${ROCKNIX_DEVICE_DIR:=${ROCKNIX_PROJECT_DIR}/devices/${ROCKNIX_SOC}}"
# Boot-image style for the SoC's bootloader: qcom-abl (ABL boots an Android
# boot image, sm8550) or arm-efi (ABL chainloads GRUB, raw Image, sm8250).
# Set per-profile; default keeps the original qcom-abl devices untouched.
: "${BOOTLOADER:=qcom-abl}"
# Per-SoC pacman repo: tuned packages (mesa etc.) share pkgnames across SoCs
# with different binaries, so each SoC gets its own localrepo/published tree.
# packages/shared/* are byte-identical across SoCs: built once into the shared
# localrepo, published once as [pocknix-shared] (repo membership doubles as
# delivery targeting — see pocknix-notes dev/pacman-repo.md).
: "${LOCALREPO_DIR:=${BUILD_DIR}/localrepo/${SOC}}"
: "${LOCALREPO_SHARED_DIR:=${BUILD_DIR}/localrepo/shared}"
# Publish staging area (stage-repo.sh): a mirror of the LIVE repo with only the
# intended packages swapped in — publish-repo.sh publishes THIS, never the
# shared localrepo (which parallel sessions fill with unvalidated builds).
: "${STAGE_DIR:=${BUILD_DIR}/stage/${SOC}}"
# Which repo tree stage-repo.sh/publish-repo.sh operate on: the per-SoC
# [pocknix] tree (default) or the SoC-neutral [pocknix-shared] tree
# (make stage-shared / publish-shared). The db filename must equal the repo
# tag, hence REPO_NAME drives both the stanza and the *.db names.
: "${POCKNIX_REPO_SCOPE:=soc}"
if [ "${POCKNIX_REPO_SCOPE}" = "shared" ]; then
  REPO_NAME="pocknix-shared"; REPO_SEG="shared"
  REPO_LOCALREPO_DIR="${LOCALREPO_SHARED_DIR}"
  REPO_STAGE_DIR="${BUILD_DIR}/stage/shared"
else
  REPO_NAME="pocknix"; REPO_SEG="${SOC}"
  REPO_LOCALREPO_DIR="${LOCALREPO_DIR}"
  REPO_STAGE_DIR="${STAGE_DIR}"
fi
# Per-SoC kernel + image outputs: with one family per SoC, a shared build/kernel
# and build/image/KERNEL meant "whatever family built last" — switching families
# forced a full kernel rebuild just to regenerate an unchanged image, and the
# out/soc guards had to police mixups. Per-SoC dirs keep each family's outputs
# resident side by side. (build/cache and build/rootfs stay shared: the cache is
# SoC-neutral downloads, the rootfs is wiped by bootstrap.sh on every build.)
: "${KERNEL_BUILD_DIR:=${BUILD_DIR}/kernel/${SOC}}"
: "${IMAGE_DIR:=${BUILD_DIR}/image/${SOC}}"

# --- logging ---------------------------------------------------------------
_c_blue=$'\033[1;34m'; _c_grn=$'\033[1;32m'; _c_yel=$'\033[1;33m'
_c_red=$'\033[1;31m';  _c_rst=$'\033[0m'
log()  { printf '%s==>%s %s\n'  "$_c_blue" "$_c_rst" "$*"; }
ok()   { printf '%s ok%s %s\n'  "$_c_grn"  "$_c_rst" "$*"; }
warn() { printf '%swarn%s %s\n' "$_c_yel"  "$_c_rst" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$_c_red" "$_c_rst" "$*" >&2; exit 1; }

# --- guards ----------------------------------------------------------------
need_root() { [ "$(id -u)" -eq 0 ] || die "must run as root (chroot/mount needed): try 'sudo make $1'"; }
need_linux() { [ "$(uname -s)" = "Linux" ] || die "the image build must run on a Linux host (current: $(uname -s)). Use a Linux box or container."; }
have()     { command -v "$1" >/dev/null 2>&1; }
need_tool(){ have "$1" || die "missing required tool: $1"; }

# --- on/off knobs ------------------------------------------------------------
# The switches take 1/on/yes/true and 0/off/no/false in any case. Anything else dies: a typo like
# SD_SSH=1 used to read as "off" and only showed up as a refused login on the device.
onoff() {  # <name> <value> -> "on" or "off"
  case "${2,,}" in
    1|on|yes|y|true) printf on ;;
    0|off|no|n|false|"") printf off ;;
    *) die "$1='$2': expected on or off (1/0, yes/no and true/false work too)" ;;
  esac
}
# SSH=1 is the short spelling of SD_SSH=on (make image SSH=1, ./build.sh --ssh) and wins when both
# are set. A non-boolean SSH (some shells export it as a command name) is not ours: it is ignored.
case "${SSH:-}" in
  "") SD_SSH="$(onoff SD_SSH "${SD_SSH}")" ;;
  *)
    case "${SSH,,}" in
      1|0|on|off|y|n|yes|no|true|false) SD_SSH="$(onoff SSH "${SSH}")" ;;
      *) warn "ignoring SSH='${SSH}' (not on/off); SD_SSH=${SD_SSH} decides"
         SD_SSH="$(onoff SD_SSH "${SD_SSH}")" ;;
    esac ;;
esac

# --- package lists ---------------------------------------------------------
# awk $1, not sed 's/#.*//': sed keeps the whitespace before an inline comment and
# pacman then can't match the name.
read_pkglist() {
  awk '{ sub(/#.*/, ""); if ($1 != "") print $1 }' "$1"
}

# --- chroot mount/teardown (idempotent) ------------------------------------
# Every mount only once, and the /dev binds private. On a systemd host (WSL with systemd=true
# included) every mount is shared, so a bind of /dev is a PEER of the host's /dev and whatever is
# mounted on or under it lands on the host too: a second bind over an interrupted build's leftovers
# covers the host's /dev/pts, and from then on nothing opens a terminal (sudo: "unable to allocate
# pty: No such device") until the mounts go or the machine restarts.
chroot_bind() {  # <source> <target>
  mountpoint -q "$2" && return 0
  mount --bind "$1" "$2"
  mount --make-private "$2"
}
chroot_mount() {
  local root="$1"
  chroot_bind /dev     "${root}/dev"
  chroot_bind /dev/pts "${root}/dev/pts"
  mountpoint -q "${root}/proc" || mount -t proc  proc  "${root}/proc"
  mountpoint -q "${root}/sys"  || mount -t sysfs sys   "${root}/sys"
  mountpoint -q "${root}/run"  || mount -t tmpfs tmpfs "${root}/run"
  chroot_resolv "${root}"
  # One package cache for the rootfs and every build chroot, so pacman fetches each file once
  # rather than once per chroot and per build. Files a chroot cached itself move into it.
  local pc="${root}/var/cache/pacman/pkg"
  if ! mountpoint -q "${pc}"; then
    mkdir -p "${PKG_CACHE_DIR}" "${pc}"
    find "${pc}" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.part' \
      -exec mv -n -t "${PKG_CACHE_DIR}" {} + 2>/dev/null || true
    mount --bind "${PKG_CACHE_DIR}" "${pc}"
  fi
  prune_localrepo_copies
}

# pacman caches its file:// installs from build/localrepo too. A package rebuilt at the same version
# would then fail its checksum against the stale copy, so those never outlive a chroot session.
prune_localrepo_copies() {
  local f
  for f in "${LOCALREPO_DIR}"/*.pkg.tar.* "${LOCALREPO_SHARED_DIR}"/*.pkg.tar.*; do
    if [ -f "${f}" ]; then rm -f "${PKG_CACHE_DIR}/${f##*/}"; fi
  done
}

# Anything mounted below <dir>? Captured first: under pipefail a SIGPIPE'd findmnt | grep -q would
# read as "nothing mounted", and rm -rf follows bind mounts.
mounted_under() {
  local mounts
  mounts="$(findmnt -rno TARGET)" || return 0
  grep -q "^$1/" <<< "${mounts}"
}

# Give the chroot a working /etc/resolv.conf. On systemd-resolved hosts (Fedora,
# Arch, etc.) the host /etc/resolv.conf is a stub pointing at 127.0.0.53, which
# resolves nothing inside the chroot — so prefer the real upstream resolvers, and
# fall back to public DNS if only a localhost stub is available.
chroot_resolv() {
  local root="$1" src
  for src in /run/systemd/resolve/resolv.conf /etc/resolv.conf; do
    if [ -e "$src" ]; then
      rm -f "${root}/etc/resolv.conf"
      cp -L "$src" "${root}/etc/resolv.conf"
      break
    fi
  done
  if ! grep -E '^[[:space:]]*nameserver' "${root}/etc/resolv.conf" 2>/dev/null | grep -qv '127\.'; then
    warn "no usable upstream resolver found in chroot — falling back to public DNS (1.1.1.1)"
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "${root}/etc/resolv.conf"
  fi
}
chroot_umount() {
  local root="$1"
  for m in var/cache/pacman/pkg run sys proc dev/pts dev; do
    mountpoint -q "${root}/${m}" && umount -lf "${root}/${m}" || true
  done
  prune_localrepo_copies
}

# install qemu-user-static into the rootfs when cross-building from x86_64
maybe_install_qemu() {
  local root="$1" entry flags
  [ "$(uname -m)" = "aarch64" ] && return 0   # native, nothing to do
  [ -f "${QEMU_AARCH64_STATIC}" ] || die "cross-building on $(uname -m) needs ${QEMU_AARCH64_STATIC} (install qemu-user-static + binfmt)"
  # The chroots run under qemu via binfmt_misc, and makepkg's `sudo pacman` only gains root if
  # the handler has flag C. Debian/Ubuntu register qemu-aarch64 without it (it shows POF).
  entry="$(grep -l '^magic 7f454c46020101.*0200b700$' /proc/sys/fs/binfmt_misc/* 2>/dev/null | head -n 1 || true)"
  { [ -n "${entry}" ] && grep -qx enabled "${entry}"; } \
    || die "no enabled aarch64 binfmt handler on $(uname -m): install qemu-user-static with its binfmt registration (systemd-binfmt or binfmt-support)"
  flags="$(sed -n 's/^flags: //p' "${entry}")"
  case "${flags}" in
    *C*) ;;
    *) die "binfmt ${entry##*/} has flags '${flags}', without C: sudo in the build chroot cannot gain root.
  Copy its line from /usr/lib/binfmt.d/ into /etc/binfmt.d/ with 'C' added to the flags, then run
  'systemctl restart systemd-binfmt'" ;;
  esac
  install -Dm755 "${QEMU_AARCH64_STATIC}" "${root}${QEMU_AARCH64_STATIC}"
}

# --- pinned ALARM base ------------------------------------------------------
# Fetch + verify the ALARM base tarball into CACHE_DIR. One implementation for
# bootstrap.sh (rootfs) and build-packages.sh (build chroot): the chroot used
# to download with no sha check at all, so the two bases could diverge.
fetch_alarm_tarball() {
  local tarball="${CACHE_DIR}/${ALARM_TARBALL}"
  mkdir -p "${CACHE_DIR}"
  if [ ! -f "${tarball}" ]; then
    log "downloading ALARM rootfs: ${POCKNIX_ALARM_TARBALL_URL}"
    curl -fL --retry 3 -o "${tarball}" "${POCKNIX_ALARM_TARBALL_URL}"
  else
    log "using cached ALARM rootfs: ${tarball}"
  fi
  if [ -n "${POCKNIX_ALARM_SHA256}" ]; then
    echo "${POCKNIX_ALARM_SHA256}  ${tarball}" | sha256sum -c - >/dev/null \
      || die "ALARM tarball sha256 mismatch — refusing to build"
    ok "ALARM tarball checksum verified"
  else
    warn "POCKNIX_ALARM_SHA256 is unset — build is NOT reproducible (pin it for releases)"
  fi
}

# Render the base pacman.conf: with a pinned snapshot, the only package source
# is the frozen [pocknix-base] repo (ALARM's per-package .sig files are kept in
# the snapshot, so package SigLevel stays Required; the repo-add DB is unsigned,
# which DatabaseOptional permits). Without a pin: live ALARM, as before. Shared
# by the rootfs and the build chroot so both always install from the SAME base.
render_base_pacman_conf() {
  local out="$1"
  if [ -n "${POCKNIX_BASE_SNAPSHOT}" ]; then
    # keep the template's [options] block, replace every repo with the snapshot
    sed '/^\[core\]$/,$d' "${CONFIG_DIR}/pacman.conf.in" > "${out}"
    cat >> "${out}" <<EOF
[pocknix-base]
SigLevel = Required DatabaseOptional
Server = ${POCKNIX_BASE_URL}
EOF
  else
    cp -f "${CONFIG_DIR}/pacman.conf.in" "${out}"
  fi
}

# Every artifact `make build` wants for this SOC, one "repo-dir|pkg-dir|pkgname|version|arch"
# line each: build-packages.sh's dirs, socs gating and makepkg --packagelist naming, read from
# the PKGBUILDs alone so pending.sh and seed-localrepo.sh need no build chroot.
local_artifacts() {
  local d devsoc socs repo
  for d in "${PACKAGES_DIR}"/shared/*/ "${PACKAGES_DIR}"/soc/*/ "${POCKNIX_ROOT}"/devices/*/packages/*/; do
    [ -f "${d}PKGBUILD" ] || continue
    case "${d}" in */devices/*/packages/*)
      devsoc="$(unset SOC; . "${d%/packages/*}/profile.conf" >/dev/null 2>&1; printf '%s' "${SOC}")"
      [ "${devsoc}" = "${SOC}" ] || continue
    ;; esac
    case "${d}" in */packages/soc/*)
      socs=""; read -r socs 2>/dev/null < "${d}socs" || true
      case " ${socs} " in *" ${SOC} "*) ;; *) continue ;; esac
    ;; esac
    repo="${LOCALREPO_DIR}"
    case "${d}" in */packages/shared/*) repo="${LOCALREPO_SHARED_DIR}" ;; esac
    # PKGBUILDs are not written for set -eu, and some read ${startdir} like makepkg sets it.
    # shellcheck disable=SC2034,SC2154  # the sourced PKGBUILD sets arch, pkgname, pkgver, pkgrel
    (
      cd "${d}" && set +eu && startdir="${PWD}" && source ./PKGBUILD >/dev/null 2>&1
      a=aarch64; [[ " ${arch[*]} " == *" any "* ]] && a=any
      for p in "${pkgname[@]}"; do
        printf '%s|%s|%s|%s|%s\n' "${repo}" "${d%/}" "${p}" "${epoch:+${epoch}:}${pkgver}-${pkgrel}" "${a}"
      done
    )
  done
}

# The file in <repo-dir> for <name-version-arch>, never a signature or a partial download.
artifact_file() {  # <repo-dir> <name-version-arch>
  local f
  for f in "$1/$2.pkg.tar."*; do
    case "${f}" in *.sig|*.part) continue ;; esac
    [ -f "${f}" ] && { printf '%s\n' "${f}"; return 0; }
  done
  return 1
}

# Every artifact of every package dir `make build` would compile, as local_artifacts lines. Its
# skip rule, read from the PKGBUILDs alone: a dir is up to date only when every artifact it names
# is in build/localrepo, newer than every file in the dir (and, for the kernel package, than
# `make kernel`'s Image). POCKNIX_FORCE_REBUILD=1 compiles everything, as it does there.
pending_artifacts() {
  local -A stale=()
  local -a want=()
  local line repo d p v a f
  mapfile -t want < <(local_artifacts)
  for line in "${want[@]}"; do
    IFS='|' read -r repo d p v a <<< "${line}"
    [ -z "${stale[${d}]:-}" ] || continue
    [ "${POCKNIX_FORCE_REBUILD:-0}" != 1 ] \
      && f="$(artifact_file "${repo}" "${p}-${v}-${a}")" \
      && [ -z "$(find "${d}" -newer "${f}" -print -quit)" ] \
      && ! { [ "${p}" = "${KERNEL_PKG}" ] && [ "${KERNEL_BUILD_DIR}/out/Image" -nt "${f}" ]; } \
      || stale[${d}]=1
  done
  for line in "${want[@]}"; do
    IFS='|' read -r repo d p v a <<< "${line}"
    [ -z "${stale[${d}]:-}" ] || printf '%s\n' "${line}"
  done
}

# --- build progress ------------------------------------------------------------
# make image keeps a status file (POCKNIX_PROGRESS_FILE, exported to every step) that its status
# bar and `make status` read, and a per-host history of how long each step and each package took,
# which is where its time-left estimate comes from. Best effort throughout: no write here can fail
# a build, and outside make image the status writes do nothing.
: "${PROGRESS_DIR:=${BUILD_DIR}/progress}"
PROGRESS_HISTORY="${PROGRESS_DIR}/history-${SOC}"   # "<key> <seconds>": the last time each took

now_s() { printf '%(%s)T' -1; }
fmt_dur() {  # <seconds> -> 45s | 12m05s | 2h03m
  local s="${1:-0}"
  [[ "${s}" =~ ^[0-9]+$ ]] || s=0
  if [ "${s}" -lt 60 ]; then printf '%ds' "${s}"
  elif [ "${s}" -lt 3600 ]; then printf '%dm%02ds' $((s / 60)) $((s % 60))
  else printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60)); fi
}

# Files a root step writes here go back to whoever ran sudo: the next run's first steps run as them.
_progress_own() {
  [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_UID:-}" ] || return 0
  chown "${SUDO_UID}:${SUDO_GID:-${SUDO_UID}}" "$@" 2>/dev/null || true
}

# <file> <awk filter> <new lines>: rewrite a small state file in one rename, so a reader never
# sees half of it.
_progress_rewrite() {
  local f="$1" keep="$2" add="$3" tmp
  mkdir -p "${f%/*}" 2>/dev/null || return 0
  _progress_own "${f%/*}"
  tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null)" || return 0
  if { [ ! -f "${f}" ] || awk "${keep}" "${f}"; printf '%s' "${add}"; } > "${tmp}" 2>/dev/null \
     && chmod 644 "${tmp}" && mv -f "${tmp}" "${f}"; then
    _progress_own "${f}"
  else
    rm -f "${tmp}"
  fi
  return 0
}

progress_set() {  # <KEY> <value> [<KEY> <value> ...]: update the running build's status file
  local f="${POCKNIX_PROGRESS_FILE:-}" keys="" add="" k v
  [ -n "${f}" ] || return 0
  while [ "$#" -ge 2 ]; do
    k="$1"; v="${2//$'\n'/ }"; shift 2
    keys+="${keys:+|}${k}"; add+="${k}=${v}"$'\n'
  done
  _progress_rewrite "${f}" "!/^(${keys})=/" "${add}"
}
progress_detail() { progress_set P_DETAIL "$*"; }

hist_get() {  # <key> -> seconds it took last time; nothing when it never ran here
  [ -f "${PROGRESS_HISTORY}" ] || return 0
  awk -v k="$1" '$1 == k && $2 ~ /^[0-9]+$/ { v = $2 } END { if (v != "") print v }' \
    "${PROGRESS_HISTORY}" 2>/dev/null || true
}
hist_set() {  # <key> <seconds>
  [[ "$2" =~ ^[0-9]+$ ]] || return 0
  _progress_rewrite "${PROGRESS_HISTORY}" "\$1 != \"$1\"" "$1 $2"$'\n'
}

# How long one package should take to build: its own last build here, else a guess - an arch=any
# package only lays out files, anything else compiles (several times slower under qemu).
pkg_estimate() {  # <package dir name> <any|native> -> "<seconds> <1 when guessed>"
  local h; h="$(hist_get "pkg.$1")"
  if [ -n "${h}" ]; then printf '%s 0\n' "${h}"; return 0; fi
  case "$2:$(uname -m)" in
    any:*) printf '60 1\n' ;;
    *:aarch64) printf '300 1\n' ;;
    *) printf '1200 1\n' ;;
  esac
}
