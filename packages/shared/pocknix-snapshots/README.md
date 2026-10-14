# pocknix-snapshots

How the update snapshots and `pocknix-rollback` work. The user guide is
[docs/snapshots.md](../../../docs/snapshots.md).

## Root layout

The root partition is btrfs with five subvolumes:

| Subvol | Mounted at | Rolls back? |
|---|---|---|
| `@` | `/` (as the filesystem **default**) | yes - the OS, including pacman's database |
| `@home` | `/home` | no - games, saves, settings survive |
| `@snapshots` | `/.snapshots` | no - the snapshots themselves |
| `@pacman-cache` | `/var/cache/pacman` | no - downloaded packages aren't duplicated per snapshot |
| `@var-log` | `/var/log` | no - logs survive for post-mortem |

Neither the kernel cmdline nor the fstab root line names a subvolume: the kernel mounts
whatever the filesystem's *default subvolume* is. That is the whole rollback mechanism -
`pocknix-rollback` points the default at a restored root, and the next boot comes up in it. Zero boot-config
changes, one atomic btrfs operation as the commit point.

## Snapshots

Two alpm hooks fire inside *every* pacman transaction - the QAM updater, `pocknix-update`, or a
plain `pacman -Syu` over ssh:

- `05-pocknix-snapshot` (PreTransaction): read-only snapshot of `/` into
  `/.snapshots/<id>/snapshot` + metadata in `info.json` (date, targets, whether a kernel
  was in the transaction). Skipped when free space is below
  `POCKNIX_SNAPSHOT_MIN_FREE_MIB` - **never blocks the update**.
- `99-pocknix-snapshot-post` (PostTransaction): marks the transaction committed, touches
  `/run/pocknix/reboot-required` when a kernel changed, prunes old snapshots.

Retention: the newest `POCKNIX_SNAPSHOT_KEEP` snapshots + **1** abandoned root. Both tunables and
their defaults live in `/etc/pocknix/snapshots.conf`.

## The kernel gap

Boot files live on the FAT partition (`/flash`), outside btrfs. When the rollback target's kernel
differs from the running one, `pocknix-rollback` regenerates `/flash/KERNEL` (and dtbs on arm-efi)
**from the snapshot's own tree** (via `pocknix-boot-deploy` from `pocknix-bsp-common`, in
`SRCROOT`/staging mode), staged as `*.new` before the commit and renamed after - so the kernel and its modules always match after the reboot. A crash inside
that tiny window is healed on the next boot by `pocknix-rollback-repair.service`.
