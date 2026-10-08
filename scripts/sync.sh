#!/usr/bin/env bash
# sync.sh — refresh the vendored ROCKNIX inputs for the selected device's SoC
# (kernel/${SOC}/, chosen by the device profile) into two destinations:
#
#   kernel/${SOC}/ (COMMITTED) — the full kernel input set: patch stack, DTS,
#             kernel config, firmware list, qcom-abl bootloader packaging. A PINNED
#             SNAPSHOT of ROCKNIX `next` (nightly) + jaewun's suspend branch + our
#             delta. The RP6 is officially supported upstream, so most of this is
#             public ROCKNIX work; committing it makes pocknix-os self-contained
#             and reproducible. `make sync` advances the pin from your
#             distribution/ checkout — review the git diff and commit the result.
#
#   vendor/   (GITIGNORED) — build-time-only material that we do NOT redistribute:
#             ROCKNIX reference scripts to adapt, and the device firmware/overlay
#             (stock firmware comes from linux-firmware at build instead).
#
# Thorch auto-fetches ROCKNIX nightly at build (gitignored); we pin + commit a
# nightly snapshot instead (reproducible, clone-standalone). We track nightly
# (`next`), not stable. vendor/ alone comes from the ROCKNIX_COMMIT pin, which
# this script fetches; to move kernel/, set DISTRIBUTION_DIR to your own ROCKNIX
# 'distribution' checkout (expected on a `next`-based branch, e.g. thor-suspend-merge).

source "$(dirname "$0")/lib.sh"

# The ROCKNIX package dirs vendor/ keeps for reference, under projects/ROCKNIX/packages/.
REFS=(emulators/standalone/steam apps/gamescope compat/fex-emu hardware/quirks linux)

# vendor/distribution is sync's own checkout: only the paths sync reads, for every SoC kernel/
# carries, at ROCKNIX_COMMIT. A shallow blobless fetch keeps it to about 10 MB.
if [ "${DISTRIBUTION_DIR}" = "${VENDOR_DIR}/distribution" ]; then
  need_tool git
  paths=(projects/ROCKNIX/packages/linux-firmware/extra-firmware)
  for p in "${REFS[@]}"; do paths+=("projects/ROCKNIX/packages/${p}"); done
  for k in "${POCKNIX_ROOT}"/kernel/*/kernel.conf; do
    s="$(sed -n 's/^: "${ROCKNIX_SOC:=\(.*\)}"$/\1/p' "${k}")"
    [ -z "${s}" ] || paths+=("projects/ROCKNIX/devices/${s}")
  done
  if [ "$(git -C "${DISTRIBUTION_DIR}" rev-parse -q --verify HEAD 2>/dev/null)" != "${ROCKNIX_COMMIT}" ] \
     || [ ! -d "${ROCKNIX_DEVICE_DIR}" ]; then
    log "ROCKNIX ${ROCKNIX_COMMIT:0:12} (only the paths sync reads) -> vendor/distribution"
    [ -d "${DISTRIBUTION_DIR}/.git" ] || git init -q "${DISTRIBUTION_DIR}"
    git -C "${DISTRIBUTION_DIR}" sparse-checkout set "${paths[@]}" \
      && git -C "${DISTRIBUTION_DIR}" fetch -q --depth 1 --filter=blob:none "${ROCKNIX_URL}" "${ROCKNIX_COMMIT}" \
      && git -C "${DISTRIBUTION_DIR}" -c advice.detachedHead=false checkout -q --force --detach FETCH_HEAD \
      || die "could not fetch ${ROCKNIX_URL} at ${ROCKNIX_COMMIT}"
  fi
fi

if [ ! -d "${ROCKNIX_DEVICE_DIR}" ]; then
  [ "${DISTRIBUTION_DIR}" != "${VENDOR_DIR}/distribution" ] \
    || die "ROCKNIX ${ROCKNIX_COMMIT:0:12} has no devices/${ROCKNIX_SOC}: pin a commit that does (ROCKNIX_COMMIT)"
  die "ROCKNIX device dir not found: ${ROCKNIX_DEVICE_DIR}
  ${DISTRIBUTION_DIR} is your own ROCKNIX checkout: add projects/ROCKNIX/devices/${ROCKNIX_SOC} to it,
  or move it aside and make sync fetches the pinned commit into vendor/distribution itself"
fi

# Moving the committed kernel is the maintainer's step, so it has to be asked for: a stale
# ../distribution left over from older instructions must not rewrite kernel/ on a plain make sync.
SCOPE="${POCKNIX_SYNC_SCOPE:-vendor}"
case "${SCOPE}" in all|vendor) ;; *) die "POCKNIX_SYNC_SCOPE='${SCOPE}': use vendor (default) or all" ;; esac

log "syncing ROCKNIX ${ROCKNIX_SOC} from ${ROCKNIX_PROJECT_DIR}"

# --- committed kernel enablement -> kernel/${SOC}/ --------------------------
# Only with POCKNIX_SYNC_SCOPE=all: a build host needs vendor/ alone, and this moves the committed
# pin to whatever the distribution/ checkout holds.
if [ "${SCOPE}" = all ]; then
  # The full patch stack ROCKNIX applies for this SoC, in order (PKG_PATCH_DIRS=
  # "mainline ${DEVICE} ... 7.0"). Stored as numbered subdirs so the build applies
  # them in the same order: 10-mainline -> 20-<soc> -> 30-version.
  log "  kernel enablement -> kernel/${SOC}/ (committed)"
  mkdir -p "${KERNEL_DIR}/patches/10-mainline" \
           "${KERNEL_DIR}/patches/20-${SOC}" \
           "${KERNEL_DIR}/patches/30-version" \
           "${KERNEL_DIR}/dts" "${KERNEL_DIR}/config" "${KERNEL_DIR}/bootloader"
  # generic ROCKNIX backports applied BEFORE device patches
  rsync -a --delete "${ROCKNIX_PROJECT_DIR}/packages/linux/patches/mainline/" "${KERNEL_DIR}/patches/10-mainline/"
  # the SoC device patches
  rsync -a --delete "${ROCKNIX_DEVICE_DIR}/patches/linux/"                     "${KERNEL_DIR}/patches/20-${SOC}/"
  # generic version-specific patches applied AFTER device patches (dir name set in
  # kernel.conf - ROCKNIX keeps using "7.0" for the 7.1.x series)
  rsync -a --delete "${ROCKNIX_PROJECT_DIR}/packages/linux/patches/${ROCKNIX_VERSION_PATCH_DIR:-${KERNEL_VERSION%.*}}/" "${KERNEL_DIR}/patches/30-version/"
  # dts / config / bootloader packaging
  rsync -a --delete "${ROCKNIX_DEVICE_DIR}/linux/dts/"                 "${KERNEL_DIR}/dts/"
  rsync -a          "${ROCKNIX_DEVICE_DIR}/linux/linux.aarch64.conf"   "${KERNEL_DIR}/config/"
  rsync -a          "${ROCKNIX_DEVICE_DIR}/config/kernel-firmware.dat" "${KERNEL_DIR}/config/"
  rsync -a --delete "${ROCKNIX_DEVICE_DIR}/bootloader/"               "${KERNEL_DIR}/bootloader/"
else
  log "  kernel/${SOC}/ left as committed (POCKNIX_SYNC_SCOPE=all moves it)"
fi

# --- gitignored build-time material -> vendor/ -----------------------------
dst="${VENDOR_DIR}/rocknix-${SOC}"
log "  reference scripts + firmware overlay -> vendor/ (gitignored)"
mkdir -p "${dst}/filesystem"
# ROCKNIX moved the SM8550 firmware out of its tree in 14ab5da8 (2026-08-03), into its
# extra-firmware repo at a commit each checkout pins in package.mk. Without the in-tree copy, fetch
# that commit's ${ROCKNIX_SOC}/ (git checks it by id); sm8250 has no overlay either way.
fw="${FW_SRC_REL#"rocknix-${SOC}/filesystem/"}"
if [ -d "${ROCKNIX_DEVICE_DIR}/filesystem/${fw}" ] || [ "${SOC}" = sm8250 ]; then
  rsync -a --delete "${ROCKNIX_DEVICE_DIR}/filesystem/" "${dst}/filesystem/"
else
  need_tool git
  mk="${ROCKNIX_PROJECT_DIR}/packages/linux-firmware/extra-firmware/package.mk"
  rev="$(sed -n 's/^PKG_VERSION="\([0-9a-f]\{40\}\)"$/\1/p' "${mk}" 2>/dev/null || true)"
  site="$(sed -n 's/^PKG_SITE="\(.*\)"$/\1/p' "${mk}" 2>/dev/null || true)"
  [ -n "${rev}" ] && [ -n "${site}" ] \
    || die "no ${ROCKNIX_SOC} firmware in this ROCKNIX checkout, and no extra-firmware pin at ${mk}:
  add projects/ROCKNIX/packages/linux-firmware/extra-firmware to its sparse checkout"
  xfw="${VENDOR_DIR}/extra-firmware"
  have="$(git -C "${xfw}" rev-parse -q --verify HEAD 2>/dev/null || true)"
  if [ "${have}" != "${rev}" ] || [ ! -d "${xfw}/${ROCKNIX_SOC}" ]; then
    log "  ${site} ${rev:0:12} (${ROCKNIX_SOC}/ only) -> vendor/extra-firmware"
    [ -d "${xfw}/.git" ] || git init -q "${xfw}"
    git -C "${xfw}" sparse-checkout set "${ROCKNIX_SOC}" \
      && git -C "${xfw}" fetch -q --depth 1 --filter=blob:none "${site}" "${rev}" \
      && git -C "${xfw}" -c advice.detachedHead=false checkout -q --force --detach FETCH_HEAD \
      || die "could not fetch ${site} at ${rev}"
  fi
  rsync -a --delete --exclude="/${fw}" "${ROCKNIX_DEVICE_DIR}/filesystem/" "${dst}/filesystem/"
  mkdir -p "${dst}/filesystem/${fw}"
  rsync -a --delete "${xfw}/${ROCKNIX_SOC}/" "${dst}/filesystem/${fw}/"
fi
for p in "${REFS[@]}"; do
  src="${ROCKNIX_PROJECT_DIR}/packages/${p}"
  if [ ! -d "${src}" ]; then
    warn "  (missing) ${src}"
    continue
  fi
  # pre-create nested parents: macOS rsync (2.6.9) won't make implied dirs
  mkdir -p "${dst}/reference/${p}"
  rsync -a --delete "${src}/" "${dst}/reference/${p}/"
done

# Which ROCKNIX commit vendor/ came from, so make image can tell when the pin has moved.
git -C "${DISTRIBUTION_DIR}" rev-parse -q --verify HEAD > "${dst}/.rocknix-commit" 2>/dev/null \
  || rm -f "${dst}/.rocknix-commit"

if [ "${SCOPE}" = all ]; then
  ok "sync complete:
  kernel/${SOC}/  (committed)  $(find "${KERNEL_DIR}/patches" -name '*.patch' 2>/dev/null | wc -l | tr -d ' ') patches + dts + config
  vendor/         (gitignored) reference scripts + firmware overlay"
else
  ok "sync complete: vendor/ (gitignored) reference scripts + firmware overlay"
fi
