# devices/ - the device-abstraction boundary

Everything device-specific lives here (or in `kernel/<soc>/`). Shared code never
hardcodes a device fact: the **build** reads `devices/<name>/profile.conf` (sourced by
`scripts/lib.sh` right after `config/pocknix.conf`), and the **running OS** reads
`/usr/lib/pocknix/device.conf`, shipped by the family's BSP package.

`DEVICE` names an **image target**, a SoC family. This tree builds one: `sm8550`, for the
Retroid Pocket 6 (standard and TOP-DPAD models). The BSP
(`pocknix-bsp-<soc>`) ships per-board facts in `/usr/lib/pocknix/boards/<board>.conf`,
each sourcing the family-wide `boards/family.conf` first, and
`/usr/lib/pocknix/device.conf` is a sourced **dispatcher** that picks one at source time
by `/proc/device-tree/model`. `scripts/render-bsp.sh` renders it at package time from the
BSP's `boards/models` table (`<board> <dt model>` rows). InputPlumber configs are gated with
`matches:` on the devicetree model. Since consumers *source* `device.conf`, the dispatcher
is invisible to them; `/etc/pocknix/device.conf` still overrides.

The family:

* **sm8550** (qcom-abl): Retroid Pocket 6 (+TOP-DPAD), both on `boards/rp6.conf`. The RP6
  device tree includes the shared AYN SM8550 dtsi, so its sound card is named `AYN-Odin2`
  and it loads the AYN Odin 2 DSP and amp firmware: those UCM and firmware files are the
  RP6's own.

The RP6 is the fallback: it is the first `boards/models` row, which an unknown or absent
model gets (`make check` pins the two together).

Adding a **board to the family**: a `boards/<board>.conf` (only what differs from
`boards/family.conf`) + its `boards/models` row(s) + (if its controller differs) an
inputplumber yaml/map with the board's dt-model `matches:` + a `[[device]]` entry in the
BSP's `root/usr/share/steamos-manager/devices/pocknix-family.toml`, ahead of the SoC entry.
Bump the BSP pkgrel. No new packages, no new image.

## Where a new file goes

* Data about one chip (profile, tuning, freqs, boards) goes in `devices/<soc>/`.
* A chip's own `arch=any` packages (its BSP, its device meta) go in `devices/<soc>/packages/`.
* A recipe built per chip goes in `packages/soc/`, gated by its `socs` file. The goal is
  one recipe for every chip: `packages/soc/linux-pocknix/` builds every chip's kernel
  package from its `kernel/<soc>/kernel.conf`; `pocknix-bootloader-<soc>` is the remaining
  one-chip recipe until it is templated.
* `packages/shared/` only if the bytes are identical for every chip.

## What a family target must provide

```
devices/<soc>/
  profile.conf                    # build-time facts that differ per family (see devices/sm8550):
                                  #   SOC (selects kernel/<soc>/ + vendor/rocknix-<soc>/),
                                  #   BOOTLOADER (qcom-abl),
                                  #   KERNEL_CMDLINE_ROOT / KERNEL_CMDLINE_EXTRA (ONE cmdline
                                  #   for the family), DEVICE_PRETTY.
                                  #   Defaults a profile may override: config/pocknix.conf
                                  #   (DEVICE_HOSTNAME, SD_FAT_LABEL / SD_BOOT_PARTNAME /
                                  #   ROOT_LABEL, set before the profile: override with X=value)
                                  #   and scripts/lib.sh's profile_defaults (KERNEL_CMDLINE,
                                  #   DEVICE_BSP_PKG / DEVICE_META_PKG / KERNEL_PKG from SOC)
  freqs.txt                       # (with power-profiles.d tables) available cpufreq/devfreq
                                  #   frequencies the tables are checked against
  tuning.conf                     # userspace compiler tuning for the chip's per-SoC
                                  #   builds: POCKNIX_TUNE_CFLAGS (ROCKNIX's TARGET_CPU/FLAGS
                                  #   composed as -march/-mtune), POCKNIX_FEX_TUNE_CPU (per
                                  #   their fex package.mk mapping)
  packages/
    pocknix-bsp-<soc>/            # the family BSP: boards/ (family.conf, one conf per board,
                                  #   models = the table device.conf is rendered from;
                                  #   POCKNIX_BOOT_STYLE / BOOT_FAT_LABEL / ROOT_LABEL are
                                  #   rendered into family.conf from the profile) +
                                  #   root/, the install tree copied as is (git carries the
                                  #   exec bits and symlinks; make check wants 755 exactly on
                                  #   files with a shebang): input maps
                                  #   (dt-model gated), udev quirks, audio UCM, SoC
                                  #   suspend config, steamos-manager's device match
                                  #   (usr/share/steamos-manager/devices/pocknix-family.toml:
                                  #   the boards, then a qcom,<soc> catch-all), pocknix-perfd's
                                  #   underclock tables (usr/share/pocknix/power-profiles.d/
                                  #   family.conf, checked against freqs.txt).
                                  #   No kernel-cmdline: the build renders it from the profile.
                                  #   MUST: depends=(pocknix-bsp-common)
                                  #   provides/conflicts=(pocknix-bsp)   <- wrong-device guard
    pocknix-device-<soc>/         # metapackage: depends on the BSP + kernel + bootloader
                                  #   + its protons.
                                  #   Nothing every family needs: that goes on pocknix-core.
                                  #   MUST provides/conflicts=(pocknix-device).
    pocknix-firmware-<soc>/       # (optional) vendor firmware linux-firmware lacks or gets wrong,
                                  #   fetched by pinned commit + sha256 (never from vendor/),
                                  #   installed under /usr/lib/firmware/updates/; only boards
                                  #   in the BSP's boards/models. The BSP depends= on it.
```

If the family brings a **new SoC**, also create `kernel/<soc>/` (`kernel.conf` with the
source pins, `KERNEL_PKGREL` (1 for a new chip) + `config/ patches/ dts/` -
populated by `make sync` against the ROCKNIX device dir named in `ROCKNIX_SOC`); the kernel
package needs no recipe of its own (`packages/soc/linux-pocknix/` packages `make kernel` output,
plus `mkbootimg`; the /flash deploy is bsp-common's and needs nothing per SoC), and a
`packages/soc/pocknix-bootloader-<soc>/` with the ROCKNIX ABL install kit copied to the SD
boot FAT. Each SoC gets its own pacman repo tree
(`build/localrepo/<soc>`, published at `POCKNIX_REPO_URL/<soc>`): the tuned packages
(mesa, gamescope, fex-emu) share pkgnames across SoCs with different
binaries, so the repos must not mix. They build for every SoC already (`socs` = `all`);
a SoC-specific kernel config or a local patch delta goes in `kernel/<soc>/` (see
kernel/README.md). `make check` validates every family: required files, family and board keys,
the models table against boards/ and the dts model lines, the consumers' fallbacks, the rendered device.conf and family.conf, and that
the cmdline has no committed copy outside the profile. The BSP PKGBUILD installs what the
build stages into its `./staged` (device.conf, family.conf and kernel-cmdline):
copy an existing family's `package()`. A new tree is never published until its first
`make stage`/`make publish`; stage-check skips it for the other SoCs until then.

## Boot styles (`BOOTLOADER` in profile.conf)

On the device the style is `POCKNIX_BOOT_STYLE`, rendered into the BSP's family.conf from
`BOOTLOADER`; bsp-common's `pocknix-boot-deploy` runs that style's /flash deploy for every
kernel update, rollback and cmdline change. Kernel packages ship no deploy scripts or hooks.

* `qcom-abl` (sm8550): the ROCKNIX ABL boots an Android boot image (`/KERNEL`,
  mkbootimg, cmdline baked in, all dtbs appended - ABL picks by board id). The BSP
  ships `/usr/lib/pocknix/kernel-cmdline`, which build-packages.sh renders from the profile's
  `KERNEL_CMDLINE` into its `./staged`; bsp-common's kernel hook rebuilds /flash/KERNEL on device.
  The SD boot FAT also carries `rocknix_abl/` (pocknix-bootloader-<soc>): ROCKNIX's
  first-install kit for flashing that ABL from rooted stock Android - inert at boot,
  pocknix never flashes it itself.

## The runtime contract (`/usr/lib/pocknix/device.conf` -> `boards/<board>.conf`)

Sourced at launch by shared scripts (`pocknix-steam`, the desktop session, bsp-common's
`cores.sh`, the emulation launchers, the install and rollback tools; the table names each);
`/etc/pocknix/device.conf` is the admin override (sourced after, wins). Every key a script
that sources device.conf (or `cores.sh`) reads has a row, and `make check` fails on one that
does not. Absent = `required` means every board resolves it (`make check` fails a board that
leaves it unset); otherwise it says what a board without the key gets. Keys:

| Key | Used by | Absent | Meaning |
|---|---|---|---|
| `POCKNIX_DEVICE` / `POCKNIX_SOC` | anything | required | identity; pocknix-steam also passes `POCKNIX_DEVICE` to gamescope as GAMESCOPE_INTERNAL_DEVICE_ID, which the BSP's panel profiles match on |
| `POCKNIX_PANEL_W` / `POCKNIX_PANEL_H` / `POCKNIX_PANEL_REFRESH` | pocknix-steam, pocknix-roms-init (refresh also: es-retroarch) | required | gamescope -W/-H/-r |
| `POCKNIX_PANEL_ORIENT` | pocknix-steam, pocknix-roms-init | required | gamescope --force-orientation |
| `POCKNIX_PANEL_MM` | pocknix-steam | required | GAMESCOPE_FAKE_OUTPUT_MM (gamepadui DPI; deliberately faked on small panels) |
| `POCKNIX_DESKTOP_ROTATE` / `POCKNIX_DESKTOP_SCALE` | pocknix-desktop-rotate | required | kscreen-doctor rotation/scale (seeded once per user; env re-forces) |
| `POCKNIX_BOARD_UNKNOWN` | pocknix-desktop-rotate | board known (only the fallback branch sets it) | set by the device.conf fallback branch: board not in the list, do not force guessed values |
| `POCKNIX_PANEL_OUTPUT` | pocknix-steam, pocknix-desktop-rotate | single panel, first DSI | DRM connector of the main panel (`DSI-2`); gamescope `--prefer-output`, the desktop seed's output |
| `POCKNIX_PANEL_ROTATE_SHADER` | pocknix-steam | rotation autodetected | `1` = gamescope `--force-composition-rotation`: required for a panel past the DPU rotator's 1088-line cap, which otherwise scans out black |
| `POCKNIX_PANEL_HDR_NITS` | pocknix-steam | no HDR | HDR panel's peak in nits: gamescope `--hdr-itm-target-nits` plus GAMESCOPE_EXPOSE_CLIENT_SAMPLEABLE_FORMATS=1 and, for the Steam client, STEAM_GAMESCOPE_HDR_SUPPORTED=1 (its HDR switch). Set only with a gamescope panel profile in the BSP (`/usr/share/gamescope/scripts/10-pocknix/displays/`) matching the board's `POCKNIX_DEVICE` with the same peak as its `max_content_light_level`: the profile is what tells gamescope the EDID-less panel can do HDR. Absent or 0 = SDR |
| `POCKNIX_BIG_CORES` | via cores.sh: pocknix-steam-env (-> pocknix-game-launch), pocknix-rt-ladder, emulator launchers | required | cores games and emulators are pinned to; the cores left out are the small cores irq work goes to (on a SoC with no little cluster, leave two mids out) |
| `POCKNIX_BOOT_STYLE` | pocknix-install-internal, pocknix-boot-deploy (the kernel hook, pocknix-rollback, pocknix-cmdline-sync) | required | qcom-abl (rendered from the profile's `BOOTLOADER`): selects the /flash kernel deploy (`pocknix-build-bootimg`) |
| `POCKNIX_INTERNAL_DISK` | pocknix-install/uninstall-internal, installer-gui, pocknix-tools, pocknix-rollback, pocknix-internal-boot-rename | required | internal disk |
| `POCKNIX_BOOT_GPT_NAME` / `POCKNIX_BOOT_FAT_LABEL`, `POCKNIX_ROOT_LABEL` | pocknix-install/uninstall-internal, pocknix-tools (root label), pocknix-rollback, pocknix-internal-boot-rename (root label) | required | internal-install boot contract (the two labels are rendered from `SD_FAT_LABEL` / `ROOT_LABEL`, config/pocknix.conf defaults a profile may override) |

Env overrides read by the same scripts, never set in device.conf: `POCKNIX_ROTATE` /
`POCKNIX_SCALE` / `POCKNIX_OUTPUT` (pocknix-desktop-rotate re-forces the desktop seed with them).

Picking the display values for a new board:

* `POCKNIX_PANEL_W/H` are the panel's NATIVE frame. `POCKNIX_PANEL_ORIENT` is `left`/`right`
  for a portrait panel mounted landscape (the consumers transpose) and `normal` for a
  landscape-native panel (no DT `rotation`): W/H pass through untransposed and
  `POCKNIX_DESKTOP_ROTATE=none`.
* `POCKNIX_PANEL_MM` stays `177x100` unless a tester says otherwise. It is a fake that sets
  gamepadui's dpi (`W * 25.4 / 177`), field-validated on 1920- and 1280-wide panels; deviate
  only if the UI crops (dpi too high for the width) or reads tiny.
* `POCKNIX_DESKTOP_SCALE` = the largest 0.25 step that keeps the logical short side >= 480
  (the Plasma Mobile shell needs the height): 1080-line panels -> 2.5, 960-line -> 2.0.

Every consumer also falls back to the RP6 values when a required key (or the whole file) is
absent, so a missing/partial device.conf degrades to known-good behavior instead of breaking.
`make check` holds each consumer's `${POCKNIX_<key>:-<value>}` to that rule: a required key's
fallback is the RP6 value, an optional key's is 0 or empty, and `scripts/fallbacks.allow` lists
the exceptions with a reason.

## Bring-up checklist for a new board

1. Confirm the board's dtb is in `kernel/<soc>/dts` (re-`make sync` if ROCKNIX added it)
   and note the DTS `model =` string - it keys everything at runtime (`make check` fails a
   `boards/models` row that no `model = "...";` under `kernel/<soc>/dts` declares).
2. `boards/<board>.conf` in the family BSP (panel geometry/orientation from the DTS; keys
   every board shares, like `POCKNIX_BIG_CORES`, live in `boards/family.conf`); display
   values per the rule above + a `boards/models` row per DT model string.
3. InputPlumber: extend the family yaml's `matches:` if the board shares the family
   controller, or add a new model-gated yaml + capability map if it differs.
4. UCM if the sound card name differs; udev quirks as needed.
5. `make check` (board keys, models table); bump pkgrels; `make build DEVICE=<soc>`.
   No shared file should need editing; if one does, the boundary has a hole: fix the
   boundary, not the device.
