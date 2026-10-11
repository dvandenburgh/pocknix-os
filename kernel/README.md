# kernel/ — per-SoC kernel inputs (pinned ROCKNIX nightly snapshots)

Each `kernel/<soc>/` directory holds one SoC's **complete kernel input set, committed
in-repo** so pocknix-os is self-contained *and* reproducible: a clone builds the exact
same kernel with no ROCKNIX checkout needed. Only **stock Linux source** and **stock
firmware** are fetched at build (both version+sha pinned, per-SoC in
`kernel/<soc>/kernel.conf`). The device profile (`devices/<name>/profile.conf`) selects
the SoC; devices on the same SoC (RP6 + AYN Odin 2, both `sm8550/`) share the tree —
every board's dtb ships and the bootloader picks it (qcom-abl: by board id from the
boot image's appended dtbs; arm-efi: by the grub.cfg menuentry's `devicetree` line).

One directory per SoC family (devices/README.md lists them; the notes below describe
`sm8550/`). Beside the synced `patches/ dts/ config/ bootloader/`, each carries files
`make sync` never touches:

| File | What |
|---|---|
| `kernel.conf` | stock source pins and the ROCKNIX dirs to sync from |
| `config-delta` | `scripts/config` arguments applied after the shared deltas in build-kernel.sh (optional) |
| `config-assert` | symbols that must end up `=y`, checked after olddefconfig (optional) |
| `common-skip` | `kernel/common` patches this SoC leaves out, one file name per line with a `# why` (optional; `make check` fails on a name not in common) |
| `sync-keep` | our local delta, restored from git after `make sync`: `path` = our edit of an upstream file, `+path` = our own file, `-path` = deleted locally. 1000+ patches the sync deleted come back without a line; each warning sync prints is a merge to do by hand |

## Provenance — what's whose

The RP6 is **officially supported by ROCKNIX**, so the bulk of these patches are **public
ROCKNIX work**, not ours:

- **Public ROCKNIX RP6/SM8550 support** — the RP6 panel (`0104`), touchscreen, backlight,
  audio, thermal, etc. From ROCKNIX's **`next` (nightly)** branch.
- **jaewun's suspend/resume set** — `1004`, `1009` (rsinput MCU) here; the UFS, geni and tsens
  parts (`1001`, `1006`–`1008`, `1010`, `1015`, `1019`) and the thorch s2idle stack's generic
  half (`1045` gated to SM8550, `1046`–`1048`) in `kernel/common/patches/`; `1049`/`1051`
  (SM8550 dtsi OPPs) here. From
  `jaewun/ROCKNIX` `thor-suspend-fixes` / thorch; we merge/maintain it. Retired at 7.2:
  `0201` (its premise, a threaded IRQF_ONESHOT UFS handler, is gone upstream) and
  `1040`–`1044` (the "PCI: qcom: Add D3cold support" v5 series landed in 7.2).
- **Our delta** (small) — SD UHS-I SDR104 (`0210`–`0212` + the RP6/Odin 2 sdhc_2 nodes),
  `1021` (RP6 120Hz-only mode), and DTS edits that `make sync`
  does not carry (see PATCHES.md): the RP6 touchscreen at 400kHz I2C without
  `no-regmap-bulk-read` (armada-packages PR #32: the AYN workaround the RP6 inherited
  forced 63 single-byte reads per frame, capping touch at ~28Hz instead of 120Hz).

What's committed here is a **pinned snapshot of ROCKNIX `next` (nightly)** + jaewun's branch +
our delta — taken from the maintainer's `distribution/` fork (branch `thor-suspend-merge`).
We track **nightly (`next`), not a stable release**. `make sync` advances the pin when we
choose, which keeps builds reproducible (the kernel doesn't move under us between syncs).

Thorch, by contrast, auto-fetches public ROCKNIX nightly at build time (gitignored). We pin +
commit instead — same build, but reproducible and clone-standalone.

## The full kernel = stock source + this patch stack + this config

The kernel is **not** "stock Linux + a few device patches." It reproduces ROCKNIX's recipe:
stock kernel.org source (pinned per SoC in `kernel/<soc>/kernel.conf` — sm8550 **`7.2`**,
sm8250 **`7.2`**) with the full ROCKNIX patch stack applied **in order**, then the SoC
config, then qcom-abl packaging. The pin can lead or lag ROCKNIX; `make sync` moves the
patch stack, never the pin.

## Contents

| Path | What | Apply order |
|---|---|---|
| `patches/10-mainline/` | ROCKNIX generic backports (pwm, adc-keys, BT RTL8733BU) | 1st |
| `patches/20-version/` | ROCKNIX patches for the kernel version, every SoC (msm resource cleanup, initramfs warn) | 2nd |
| `patches/30-sm8550/` | SM8550 device patches: ROCKNIX's plus our 1000+ (s2idle stack, RP6 panel, RSInput gamepad, SD UHS) | 3rd |
| `../common/patches/` | Our SoC-neutral patches, applied to every SoC; `make sync` never writes there | last |
| `dts/qcom/` | RP6 device tree (`qcs8550-retroidpocket-rp6.dts` + shared `.dtsi`s) | — |
| `config/linux.aarch64.conf` | Kernel config | — |
| `config/kernel-firmware.dat` | List of firmware files to pull from `linux-firmware` (blobs NOT vendored) | — |
| `bootloader/` | qcom-abl boot-image packaging reference | — |

The numeric subdir prefixes encode ROCKNIX's `mainline -> <version> -> ${DEVICE}` patch-dir
order (scripts/unpack; version dir named in kernel.conf); the build script applies them in
sorted order, then `kernel/common/patches/`. Our generic patches go in `kernel/common/patches/`,
numbered 1000+: behaviour meant for one SoC is gated inside the patch (DT compatible, quirk,
Kconfig), so it is safe to apply everywhere. A patch that needs a SoC-dir patch first stays in
that SoC dir. `common-skip` is the fallback for a common patch that doesn't apply or isn't
validated on a SoC.

## What is NOT here (fetched at build, Phase 1)

- **Stock Linux source** — kernel.org `linux-<ver>.tar.xz`, version+sha-pinned per SoC in
  `kernel/<soc>/kernel.conf` (`KERNEL_VERSION` / `KERNEL_SOURCE_URL` / `KERNEL_SOURCE_SHA256`).
  Not committed (stock, huge).
- **Firmware blobs** — sourced from the `linux-firmware` package per `kernel-firmware.dat`.

## Provenance / refreshing

These files are mirrored from the maintainer's ROCKNIX `distribution/` checkout
(`projects/ROCKNIX/devices/SM8550/`). To pull the latest:

```bash
export DISTRIBUTION_DIR=$HOME/Documents/Coding/distribution
POCKNIX_SYNC_SCOPE=all make sync     # refreshes kernel/ — review `git diff`, then commit
```

`make sync` overwrites the synced directories from your distribution checkout, then restores
the `sync-keep` delta from git and warns for each of our edits whose upstream copy differs:
merge an intended upstream change into ours by hand, review the diff, commit.
(See `scripts/sync.sh`.)
