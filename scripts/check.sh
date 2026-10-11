#!/usr/bin/env bash
# check.sh — sanity-check the project + (when present) the built artifacts.
# Phase 0: validates the harness itself; later phases add image/DTB/module checks.

source "$(dirname "$0")/lib.sh"

fail=0
note() { printf '  %-44s %s\n' "$1" "$2"; }

log "pocknix-os preflight"

# --- host tooling ----------------------------------------------------------
for t in bash sed rsync curl tar; do
  if have "$t"; then note "host tool: $t" "ok"; else note "host tool: $t" "MISSING"; fail=1; fi
done
if [ "$(uname -s)" = "Linux" ]; then note "host os" "Linux ok"
else note "host os" "$(uname -s) (image build needs Linux)"; fi

# Image-build readiness on this host; notes only, so the preflight still passes anywhere. On a
# non-aarch64 host the kernel cross-compiles and the chroots run under qemu-user (binfmt_misc).
if [ "$(uname -s)" = "Linux" ]; then
  if [ "$(uname -m)" = "aarch64" ]; then
    note "host arch" "aarch64 (native)"
  else
    note "host arch" "$(uname -m) (kernel cross-compiles, chroots run under qemu-user)"
    cc="${CROSS_COMPILE:-aarch64-linux-gnu-}gcc"
    have "${cc}" && note "cross compiler" "${cc} ok" || note "cross compiler" "MISSING ${cc} (make kernel)"
    bf="$(grep -l '^magic 7f454c46020101.*0200b700$' /proc/sys/fs/binfmt_misc/* 2>/dev/null | head -n 1 || true)"
    if [ -z "${bf}" ]; then
      note "qemu aarch64 binfmt" "MISSING (qemu-user-static + its binfmt registration)"
    elif ! grep -qx enabled "${bf}"; then
      note "qemu aarch64 binfmt" "${bf##*/} disabled (sudo systemctl restart systemd-binfmt)"
    elif grep -q '^flags: .*C' "${bf}"; then
      note "qemu aarch64 binfmt" "$(sed -n 's/^flags: //p' "${bf}") ok"
    else
      note "qemu aarch64 binfmt" "$(sed -n 's/^flags: //p' "${bf}") lacks C (makepkg's sudo fails in the chroot)"
    fi
  fi
  # A Windows drive under WSL (9p) or another non-POSIX fs can't hold the chroots' owners and modes.
  fs="$(stat -f -c %T "${POCKNIX_ROOT}" 2>/dev/null || true)"
  case "${fs}" in
    v9fs|9p|drvfs|fuseblk|ntfs*|vfat|msdos|exfat) note "checkout filesystem" "${fs}: build from a Linux filesystem instead" ;;
    *) note "checkout filesystem" "${fs:-?} ok" ;;
  esac
  grep -qw btrfs /proc/filesystems 2>/dev/null || PATH="${PATH}:/usr/sbin:/sbin" modprobe -n btrfs 2>/dev/null \
    && note "btrfs (make sd-image)" "ok" || note "btrfs (make sd-image)" "MISSING in this kernel"
  have ccache && note "ccache (make kernel)" "ok" \
    || note "ccache (make kernel)" "not installed (optional: kernel rebuilds recompile everything)"
fi

# --- project layout --------------------------------------------------------
for d in config config/packages scripts packages/shared packages/soc "devices/${DEVICE}"; do
  [ -d "${POCKNIX_ROOT}/${d}" ] && note "dir: ${d}/" "ok" || { note "dir: ${d}/" "MISSING"; fail=1; }
done

# --- package placement: shared/ vs soc/ -------------------------------------
# The split is load-bearing: shared/ builds once into [pocknix-shared], soc/
# builds per SoC gated by ./socs. A PKGBUILD directly under packages/ is
# invisible to the build; a soc/ package without socs (or with an unknown SoC)
# would silently vanish from every repo; a socs file under shared/ is a
# misplacement (shared builds must be SoC-blind).
while IFS= read -r p; do
  note "package: ${p#"${POCKNIX_ROOT}"/}" "OUTSIDE shared/ and soc/ — never built"; fail=1
done < <(find "${POCKNIX_ROOT}/packages" -maxdepth 2 -name PKGBUILD \
           ! -path "*/packages/shared/*" ! -path "*/packages/soc/*" 2>/dev/null)
for p in "${POCKNIX_ROOT}"/packages/soc/*/; do
  [ -d "${p}" ] || continue
  n="$(basename "${p}")"
  if [ ! -f "${p}/socs" ]; then
    note "soc pkg: ${n}" "MISSING socs file"; fail=1; continue
  fi
  read -r _socs < "${p}/socs"
  bad=0
  # "all" = every kernel/<soc>, so a new SoC needs no socs edits; it never mixes with names.
  if [ "${_socs}" = all ]; then note "soc pkg: ${n}" "socs: all"; continue; fi
  for s in ${_socs}; do
    [ -f "${POCKNIX_ROOT}/kernel/${s}/kernel.conf" ] || { note "soc pkg: ${n}" "unknown SoC '${s}' in socs"; fail=1; bad=1; }
  done
  [ "${bad}" -eq 0 ] && [ -n "${_socs}" ] && note "soc pkg: ${n}" "socs: ${_socs}"
done
for p in "${POCKNIX_ROOT}"/packages/shared/*/socs; do
  [ -e "${p}" ] || continue
  note "shared pkg: $(basename "$(dirname "${p}")")" "has a socs file (shared builds are SoC-blind — move it to packages/soc/ or delete the file)"; fail=1
done
for f in config/pocknix.conf config/pacman.conf.in config/packages/base.list \
         "devices/${DEVICE}/profile.conf" "kernel/${SOC}/kernel.conf"; do
  [ -f "${POCKNIX_ROOT}/${f}" ] && note "file: ${f}" "ok" || { note "file: ${f}" "MISSING"; fail=1; }
done
note "device" "${DEVICE} (${DEVICE_PRETTY:-?}) on ${SOC}"

# --- scripts executable ----------------------------------------------------
for s in build-all.sh build-status.sh sync.sh bootstrap.sh build-image.sh build-kernel.sh build-packages.sh \
         build-sd-image.sh stage-repo.sh stage-check.sh publish-repo.sh install.sh check.sh; do
  [ -x "${POCKNIX_ROOT}/scripts/${s}" ] && note "exec: scripts/${s}" "ok" || { note "exec: scripts/${s}" "not +x"; fail=1; }
done

# --- pocknix-perfd factory profiles ---------------------------------------
if out="$(python3 "${POCKNIX_ROOT}/scripts/check-power-profiles.py" 2>&1)"; then note "power profiles" "ok"
else note "power profiles" "BROKEN"; printf '%s\n' "${out}" | sed 's/^/    /'; fail=1; fi

# --- SoC families: what a new SoC or board must carry (all SoCs, not just DEVICE) ----
# Each of these has shipped broken once or was only written down: a missing profile dies at
# build time, a board key a consumer reads falls back to RP6 values, an unreferenced board
# never loads, and a cmdline drift ships a boot image that disagrees with the on-device one.
# Keys every board must set: the session, desktop, pinning and install-to-internal consumers
# fall back to RP6 values without them (devices/README.md runtime contract).
REQUIRED_BOARD_KEYS="POCKNIX_DEVICE POCKNIX_SOC POCKNIX_PANEL_W POCKNIX_PANEL_H
  POCKNIX_PANEL_REFRESH POCKNIX_PANEL_ORIENT POCKNIX_PANEL_MM POCKNIX_DESKTOP_ROTATE
  POCKNIX_DESKTOP_SCALE POCKNIX_BIG_CORES POCKNIX_INTERNAL_DISK POCKNIX_BOOT_GPT_NAME
  POCKNIX_BOOT_FAT_LABEL POCKNIX_ROOT_LABEL"

# Prints one problem per line for a board file; nothing means it is fine.
check_board() {  # $1 = BSP dir, $2 = board file, $3 = SoC
  local n r m
  n="$(basename "$2")"
  # Reachable = sourced by the dispatcher or by another board (variants source their base).
  grep -qsE "^[[:space:]]*\. /usr/lib/pocknix/boards/${n//./\\.}([[:space:]]|\$)" \
    "$1/device.conf" $(ls "$1"/boards/*.conf | grep -v "/${n}\$") || echo "${n} is never sourced"
  # Evaluated, not grepped: a variant board sources its base board.
  r="$(sed "s|/usr/lib/pocknix/boards/|$1/boards/|g" "$2" | env -i bash -c '
    . /dev/stdin || exit 1; for k in '"${REQUIRED_BOARD_KEYS//$'\n'/ }"'; do eval "[ -n \"\${${k}:-}\" ]" || printf "%s " "${k}"; done
    printf "|%s" "${POCKNIX_SOC:-}"')" || { echo "${n} fails to source"; return; }
  m="${r%%|*}"; [ -z "${m}" ] || echo "${n} lacks ${m% }"
  [ "${r#*|}" = "$3" ] || echo "${n} says POCKNIX_SOC=${r#*|}"
}

# Prints one problem per line for a SoC family; nothing means it is fine.
check_family() {  # $1 = SoC
  local soc="$1" dev="${POCKNIX_ROOT}/devices/$1" bsp="${POCKNIX_ROOT}/devices/$1/packages/pocknix-bsp-$1"
  local f p cmd grub line
  for f in "devices/${soc}/profile.conf" "config/tuning/${soc}.conf" "kernel/${soc}/kernel.conf"; do
    [ -f "${POCKNIX_ROOT}/${f}" ] || echo "missing ${f}"
  done
  [ -f "${dev}/profile.conf" ] || return
  grep -q "^| kernel (${soc}" "${POCKNIX_ROOT}/PATCHES.md" || echo "no PATCHES.md kernel row"
  for p in DEVICE_BSP_PKG DEVICE_META_PKG; do
    [ -f "${dev}/packages/$(profile_get "${dev}" "${p}")/PKGBUILD" ] || echo "${p} has no package under devices/${soc}/packages/"
  done
  [ -f "${bsp}/device.conf" ] || echo "missing pocknix-bsp-${soc}/device.conf"
  for f in "${bsp}"/boards/*.conf; do
    [ -f "${f}" ] && check_board "${bsp}" "${f}" "${soc}"
  done
  cmd="$(profile_get "${dev}" KERNEL_CMDLINE)"
  if [ -f "${bsp}/kernel-cmdline" ] && [ "$(cat "${bsp}/kernel-cmdline")" != "${cmd}" ]; then
    echo "BSP kernel-cmdline drifted from the profile"
  fi
  grub="${POCKNIX_ROOT}/packages/soc/pocknix-bootloader-${soc}/grub.cfg"
  if [ -f "${grub}" ]; then
    while IFS= read -r line; do
      [ "${line}" = "${cmd}" ] || { echo "a grub.cfg menuentry cmdline drifted from the profile"; break; }
    done < <(sed -n 's|^[[:space:]]*linux /KERNEL ||p' "${grub}")
  fi
}

for _k in "${POCKNIX_ROOT}"/kernel/*/kernel.conf; do
  _soc="$(basename "${_k%/kernel.conf}")"
  _bad="$(check_family "${_soc}" | paste -sd ';' -)"
  if [ -z "${_bad}" ]; then note "family: ${_soc}" "ok"; else note "family: ${_soc}" "${_bad}"; fail=1; fi
done

# Every key a board sets is part of the runtime contract, so it must be in the README table.
_undoc=""
for _key in $(cat "${POCKNIX_ROOT}"/devices/*/packages/pocknix-bsp-*/boards/*.conf \
                  "${POCKNIX_ROOT}"/devices/*/packages/pocknix-bsp-*/device.conf 2>/dev/null |
              grep -oE '^[[:space:]]*POCKNIX_[A-Z0-9_]+=' | tr -d ' =' | sort -u); do
  grep -q "\`${_key}\`" "${POCKNIX_ROOT}/devices/README.md" || _undoc="${_undoc} ${_key}"
done
if [ -z "${_undoc}" ]; then note "board keys documented" "ok"
else note "board keys documented" "not in devices/README.md:${_undoc}"; fail=1; fi

# --- kernel enablement present? (committed; refreshable via sync) -----------
_npatch=$(find "${KERNEL_DIR}/patches" "${POCKNIX_ROOT}/kernel/common/patches" -name '*.patch' 2>/dev/null | wc -l | tr -d ' ')
if [ "${_npatch:-0}" -gt 0 ]; then
  note "kernel: enablement (kernel/${SOC}/ + common/)" "${_npatch} patches"
else
  note "kernel: enablement (kernel/${SOC}/ + common/)" "run 'make sync'"
fi
# vendor sync is build-time only (gitignored)
if [ -d "${VENDOR_DIR}/rocknix-${SOC}/reference" ]; then
  note "vendor: reference/firmware" "synced"
else
  note "vendor: reference/firmware" "run 'make sync' (build host)"
fi

# --- built artifacts (only checked if they exist) --------------------------
if [ -d "${KERNEL_BUILD_DIR}/out" ]; then
  note "kernel build" "$(cat "${KERNEL_BUILD_DIR}/out/kernelrelease" 2>/dev/null || echo present)"
else
  note "kernel build" "run 'make kernel'"
fi
if [ -f "${IMAGE_DIR}/KERNEL" ]; then
  note "boot image KERNEL" "$(du -h "${IMAGE_DIR}/KERNEL" | cut -f1) (qcom-abl)"
else
  note "boot image KERNEL" "not built (make kernel)"
fi
[ -d "${ROOTFS_DIR}" ] && note "rootfs" "present"

echo
[ "$fail" -eq 0 ] && ok "preflight passed" || die "preflight found problems (see above)"
