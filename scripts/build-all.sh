#!/usr/bin/env bash
# build-all.sh — make image: from a checkout to a flashable SD image in one command. Each step is
# the script behind its own make target; sync, kernel and packages skip what is already current, so
# a re-run redoes only the rootfs and the image. Run it as yourself: the root steps share one sudo.

source "$(dirname "$0")/lib.sh"
need_linux
S="${POCKNIX_ROOT}/scripts"
step() { log "[$1/6] $2"; }

if [ "${1:-}" = --as-root ]; then
  need_root image
  step 3 "published packages (make seed)"
  if [ -n "${POCKNIX_REPO_URL}" ]; then "${S}/seed-localrepo.sh"
  else warn "POCKNIX_REPO_URL is empty: nothing to seed from, so every package compiles"; fi
  step 4 "kernel (make kernel)"
  "${S}/build-kernel.sh"
  "${S}/pending.sh"
  step 5 "packages and rootfs (make build)"
  "${S}/build-image.sh"
  step 6 "SD image (make sd-image)"
  "${S}/build-sd-image.sh"
  exit 0
fi

# Only the host lines count here: a fresh checkout fails make check's layout lines until make sync.
step 1 "host (make check)"
problems="$("${S}/check.sh" 2>&1 \
  | grep -E '^  (host tool|cross compiler|qemu aarch64 binfmt|checkout filesystem|btrfs)' \
  | grep -Ev ' ok$' || true)"
[ -z "${problems}" ] || die "this host is not ready for an image build ('make host-setup' fixes most of it):
${problems}"

step 2 "firmware (make sync)"
dst="${VENDOR_DIR}/rocknix-${SOC}"
if [ ! -d "${dst}" ] \
   || { [ "${SOC}" != sm8250 ] && [ -z "$(ls -A "${VENDOR_DIR}/${FW_SRC_REL}" 2>/dev/null)" ]; } \
   || { [ "${DISTRIBUTION_DIR}" = "${VENDOR_DIR}/distribution" ] \
        && [ "$(cat "${dst}/.rocknix-commit" 2>/dev/null)" != "${ROCKNIX_COMMIT}" ]; }; then
  # make sync runs as you; files an earlier sudo left in vendor/ would stop it halfway.
  if [ "$(id -u)" -ne 0 ] && [ -n "$(find "${VENDOR_DIR}" ! -user "$(id -u)" -print -quit 2>/dev/null)" ]; then
    die "vendor/ holds files owned by another user (an earlier sudo): sudo chown -R $(id -un) vendor"
  fi
  POCKNIX_SYNC_SCOPE=vendor "${S}/sync.sh"
else
  log "vendor/ is current"
fi

[ "$(id -u)" -ne 0 ] || exec "${S}/build-all.sh" --as-root
# sudo resets the environment, so pass on what shapes the build (DEVICE=, SD_SSH=, ...).
fwd=()
while IFS= read -r v; do fwd+=("${v}=${!v}"); done < <(compgen -e | grep -E \
  '^(DEVICE|JOBS|CROSS_COMPILE|(DISTRIBUTION|BUILD|CACHE|PKG_CACHE|VENDOR|ROOTFS|LOCALREPO|LOCALREPO_SHARED|IMAGE)_DIR|(SD|POCKNIX|ROCKNIX|KERNEL|ALARM)_[A-Z0-9_]+)$' \
  || true)
log "seed, kernel, build and sd-image need root: asking sudo once"
exec sudo env "${fwd[@]}" "${S}/build-all.sh" --as-root
