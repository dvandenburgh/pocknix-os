# kernel/ - committed kernel inputs, one tree per SoC family

Everything needed to build a SoC's kernel is committed here, so a clone builds the same
kernel with no ROCKNIX checkout. Only the stock kernel.org source and the firmware blobs
are fetched at build time, both pinned. The device profile (`devices/<soc>/profile.conf`)
selects the SoC; every board on a SoC shares its tree and every board's dtb ships (the ABL
picks one by board id).

This file describes the layout and the rules. What is carried and why (patch by patch, the
pinned versions, the ROCKNIX commit we synced to) lives in one place only: the kernel rows of
[PATCHES.md](../PATCHES.md), with the pins themselves in `kernel/<soc>/kernel.conf`. Keep it
that way: a list or a version copied into this file goes stale at the next sync.

## Layout

```
kernel/
  common/patches/        ours, SoC-neutral, applied to every SoC after its own stack
  <soc>/                 one per SoC family (devices/README.md lists them)
    kernel.conf          source pin (version + sha256), package release, ROCKNIX dirs to sync from
    patches/10-mainline/ ROCKNIX generic backports              <- make sync
    patches/20-version/  ROCKNIX patches for the kernel version <- make sync
    patches/30-<soc>/    ROCKNIX device patches + our 1000+     <- make sync, plus ours
    dts/                 device trees for every board on the SoC  <- make sync
    config/              ROCKNIX kernel config + firmware list  <- make sync (overwritten)
    sync-keep            our local delta inside the synced dirs
    config-delta         scripts/config arguments on top of the synced config (optional)
    config-assert        symbols that must end up =y (optional)
    common-skip          common patches this SoC leaves out (optional)
```

## Build = pinned source + patches in order + config

`scripts/build-kernel.sh` extracts the pinned source, applies `patches/*/` in sort order and
then `kernel/common/patches/`, installs `dts/`, seeds `.config` from `kernel/<soc>/config/linux.aarch64.conf`, applies our
config deltas, and packages the result as an Android boot image for the ABL (`qcom-abl`). The numbered dirs follow ROCKNIX's own apply
order (mainline, then the version dir, then the device dir): device patches can depend on
version-dir context.

The `linux-pocknix-<soc>` package ships only that output (plus `mkbootimg` on qcom-abl). One
recipe, `packages/soc/linux-pocknix/`, builds it for every SoC: `kernel.conf` sets its version
(`KERNEL_VERSION`), its release (`KERNEL_PKGREL`) and any names the SoC's kernel shipped under
before (`KERNEL_LEGACY_NAMES`). The on-device /flash deploy belongs to pocknix-bsp-common, which
picks it by the board's `POCKNIX_BOOT_STYLE`, so a new SoC adds no boot scripts.

## Where a patch goes

- **Ours and generic** (code that runs on any SoC): `kernel/common/patches/`, numbered 1000+.
  Behaviour meant for one SoC is gated inside the patch (DT compatible, quirk, Kconfig), so it
  is safe to apply everywhere.
- **Needs a SoC-dir patch first**, or touches only one SoC's dtsi/driver:
  `kernel/<soc>/patches/30-<soc>/`, numbered 1000+.
- **ROCKNIX's**: stays where `make sync` puts it; our edits to it are listed in `sync-keep`.
- **A common patch that doesn't apply or isn't validated on one SoC**: one line in that SoC's
  `common-skip` (file name + `# why`). `make check` fails on a name that no longer exists.
- **Config**: never edit `config/`; add a `scripts/config` delta (in build-kernel.sh for every
  SoC, in `config-delta` for one).

ROCKNIX ships some 1000+ files of its own, so check a new number against the synced dirs.

## Syncing from ROCKNIX

```bash
export DISTRIBUTION_DIR=$HOME/Documents/Coding/distribution   # a ROCKNIX checkout at next
make sync DEVICE=<soc>                                          # per SoC, then review git diff
```

`make sync` copies the ROCKNIX dirs over the synced paths with `--delete` (comparing by
content; `config/` takes the two upstream files without `--delete`), never touching `kernel/common/` or the per-SoC files without a `<- make sync` mark
above. It then restores our delta from git: each `sync-keep` line is `path` (our edit of an
upstream file), `+path` (our own file) or `-path` (an upstream file we delete), and every 1000+
patch of ours the sync removed comes back on its own. Each warning it prints is a merge to do
by hand: diff ours against upstream's new copy, and drop a `sync-keep` line only when the two
are identical. The source pin in `kernel.conf` never moves with a sync; bump it by hand and
record the new base in PATCHES.md.
