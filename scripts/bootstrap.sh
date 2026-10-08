#!/usr/bin/env bash
# bootstrap.sh — download, verify and extract the Arch Linux ARM aarch64 base
# rootfs into build/rootfs. Idempotent: re-running rebuilds a clean rootfs.

source "$(dirname "$0")/lib.sh"
need_linux
need_root bootstrap
for t in curl tar rsync; do need_tool "$t"; done

tarball="${CACHE_DIR}/${ALARM_TARBALL}"
fetch_alarm_tarball

log "extracting rootfs -> ${ROOTFS_DIR}"
# rm -rf follows bind mounts, and a chroot binds the host's /dev and the shared package cache.
if [ -d "${ROOTFS_DIR}" ]; then
  chroot_umount "${ROOTFS_DIR}" || true
  ! mounted_under "${ROOTFS_DIR}" || die "still mounted under ${ROOTFS_DIR}, not wiping it"
  rm -rf "${ROOTFS_DIR}"
fi
mkdir -p "${ROOTFS_DIR}"
# bsdtar preserves the ALARM tarball's xattrs/ownership better than gnu tar
if have bsdtar; then
  bsdtar -xpf "${tarball}" -C "${ROOTFS_DIR}"
else
  tar -xpf "${tarball}" -C "${ROOTFS_DIR}" --numeric-owner
fi

maybe_install_qemu "${ROOTFS_DIR}"
ok "base rootfs ready -> ${ROOTFS_DIR}"
