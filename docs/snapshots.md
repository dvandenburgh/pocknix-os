# Snapshots, rollback and the update safety net

pocknix stays a fully **mutable** Arch system - `pacman -Syu` is still the update - but every
package transaction is wrapped in a btrfs snapshot, and rolling back is one QAM button (or one
command) plus a reboot. No bootloader menu is involved, so it works identically on the
sm8550 devices (ROCKNIX ABL, no menu at all) and the sm8250 devices (GRUB).

## How it works

**Root layout.** The root partition is btrfs with five subvolumes:

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

**Snapshots.** Two alpm hooks (package `pocknix-snapshots`) fire inside *every* pacman
transaction - the QAM updater, `pocknix-update`, or a plain `pacman -Syu` over ssh:

- `05-pocknix-snapshot` (PreTransaction): read-only snapshot of `/` into
  `/.snapshots/<id>/snapshot` + metadata in `info.json` (date, targets, whether a kernel
  was in the transaction). Skipped when free space is below
  `POCKNIX_SNAPSHOT_MIN_FREE_MIB` (1 GiB by default) - **never blocks the update**.
- `99-pocknix-snapshot-post` (PostTransaction): marks the transaction committed, touches
  `/run/pocknix/reboot-required` when a kernel changed, prunes old snapshots.

Retention: the newest `POCKNIX_SNAPSHOT_KEEP` snapshots (5 by default) + **1** abandoned root.
Both tunables live in `/etc/pocknix/snapshots.conf`.

**The kernel gap.** Boot files live on the FAT partition (`/flash`), outside btrfs. When the
rollback target's kernel differs from the running one, `pocknix-rollback` regenerates
`/flash/KERNEL` (and dtbs on arm-efi) **from the snapshot's own tree** (via the kernel
package deploy script in `SRCROOT`/staging mode), staged as `*.new` before the commit and
renamed after - so the kernel and its modules always match after the reboot. A crash inside
that tiny window is healed on the next boot by `pocknix-rollback-repair.service`.

## Using it

Three front-ends, one mechanism - pick whichever still works when things go wrong:

- **Game mode (QAM):** Pocknix Control → Updater tab → **Roll Back Last Update** → confirm →
  **Reboot Now**. See [pocknix-control.md](pocknix-control.md#rolling-back-an-update) for the
  full walkthrough.
- **Desktop mode:** **Pocknix Tools** → *Roll back the last update...* lists every snapshot,
  newest first; pick one, confirm, and it offers the reboot. Use this when Steam or the
  plugin is what broke. Booted from the SD with Pocknix also on internal storage, *Roll back
  the INTERNAL install...* does the same for the internal copy.
- **CLI (terminal/ssh):**

```bash
pocknix-snapshots list          # what you can roll back to
pocknix-snapshots status        # running root / boots-next / free space
sudo pocknix-rollback           # newest snapshot, interactive confirm
sudo pocknix-rollback --to 0003 # jump straight to a specific snapshot
sudo pocknix-rollback --yes     # skip the confirm (scripts)
sudo pocknix-rollback --internal --to 0003  # roll back the internal install from the SD
pocknix-rollback --list         # same as pocknix-snapshots list (--status likewise)
sudo pocknix-snapshots prune    # apply the retention now (updates do this themselves)
```

Snapshots are full photographs of the system, not incremental steps, so `--to` is always a
**single jump** - no rolling back one update at a time. It is also directionless: from a
restored older state, `--to` a newer snapshot moves you forward again. The QAM only ever
offers the *last* update (the common case); anything deeper is for Pocknix Tools or the CLI. Times are
stored in UTC but always displayed in local time.

Rolling back a rollback works the same way - every rollback creates a fresh root from an
immutable read-only snapshot, and the abandoned root is kept (one deep) for inspection.
After a rollback the QAM shows a *"System was rolled back"* notice and hides the rollback
button (you are already on that snapshot's state); the next update clears the notice,
takes a fresh snapshot, and brings the button back.

## Manual recovery (device won't boot after a kernel update)

Both kernel deploy paths keep the previous boot image as `/flash/KERNEL.bak`. If the device
no longer boots and you can't get a shell:

1. Power off. Put the SD in a card reader (internal installs: boot a pocknix SD instead and
   mount the internal FAT).
2. On the boot FAT partition:
   ```bash
   mv KERNEL KERNEL.bad
   mv KERNEL.bak KERNEL
   md5sum KERNEL > KERNEL.md5    # MANDATORY - the ABL refuses a KERNEL whose md5 mismatches
   ```
3. Boot. The old kernel now runs with the newer modules - degraded (Wi-Fi/audio may be
   missing) but alive. Run `sudo pocknix-rollback` on the device to make kernel and rootfs
   coherent again.
