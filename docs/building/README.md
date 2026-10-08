# Building pocknix-os

How to build pocknix-os images and packages yourself, on an ARM machine **or an ordinary x86_64
Linux PC, including Windows through WSL2**. If you only want to install pocknix, you do not need
any of this: grab an image from the [latest release](https://github.com/shuuri-labs/pocknix-os/releases/latest).

- [linux-host.md](linux-host.md) - setting up an x86_64 or aarch64 Linux machine (Ubuntu/Debian,
  Fedora, Arch)
- [wsl.md](wsl.md) - building on Windows with WSL2, flashing the result, and previewing the boot
  splash on your desktop
- [troubleshooting.md](troubleshooting.md) - the errors you are likely to meet, and what each means

## The aarch64 question

pocknix-os is an **aarch64** (64-bit ARM) operating system, so everything in the image is ARM code.
That does **not** mean you need an ARM computer to build it:

| Step | On an aarch64 host | On an x86_64 host (PC, WSL2) |
|---|---|---|
| Kernel (`make kernel`) | compiled natively | **cross-compiled**: native speed, needs `aarch64-linux-gnu-gcc` |
| Packages and rootfs (`make packages`, `make build`) | run natively in an ARM chroot | the same ARM chroot, run through **qemu-user** (emulation, several times slower) |
| SD image (`make sd-image`) | native | native: just partitioning and copying files |

The emulated steps are the slow part on x86_64. Most of that cost is compiling the big packages
(mesa, gamescope, FEX, the emulators), so the build lets you **skip compiling** everything you have
not changed: `make seed` downloads the already-built packages from the published pocknix repo, and
only your changes get compiled. With it, an x86_64 PC builds an image in a few hours instead of
days.

An aarch64 host (an Arch/Fedora VM on Apple Silicon, an ARM cloud server) needs no emulation at all
and is still the fastest way to build everything from source.

## What a build does

1. **Firmware** - `make sync` puts the device firmware (Wi-Fi, audio, battery) into `vendor/`
   (gitignored, never redistributed), from ROCKNIX's `extra-firmware` repo at the commit your
   ROCKNIX checkout pins.
2. **Kernel** - `make kernel` builds the committed kernel (`kernel/<soc>/`) into a boot image.
3. **Packages** - `make build` first builds every pocknix package that is not already in
   `build/localrepo/`; `make seed` fills that from the published repo so only real changes compile.
4. **Root filesystem** - `make build` then installs the Arch Linux ARM base and the packages into
   `build/rootfs/`, and pre-installs the ARM Steam client so first boot works offline.
5. **Image** - `make sd-image` turns that into a flashable `build/image/<soc>/pocknix-<soc>-sd.img`.

`make help` lists every target; `make check` is a preflight that also reports what this host is
missing for an image build.

## Quick start

The device family defaults to `sm8550` (Retroid Pocket 6, AYN Odin 2 family); add
`DEVICE=sm8250` to the `make` commands for the Retroid Pocket 5 / Flip 2.

```bash
git clone https://github.com/shuuri-labs/pocknix-os && cd pocknix-os
make check                                   # read the host lines: fix anything MISSING

# 1. firmware: a sparse ROCKNIX checkout (only the parts pocknix uses); make sync then fetches
#    the SM8550 folder of ROCKNIX's extra-firmware at the commit that checkout pins (~120 MB)
git clone --depth 1 --branch next --filter=blob:none --sparse \
  https://github.com/ROCKNIX/distribution ../distribution
git -C ../distribution sparse-checkout set projects/ROCKNIX/devices/SM8550 projects/ROCKNIX/packages/linux \
  projects/ROCKNIX/packages/emulators/standalone/steam projects/ROCKNIX/packages/apps/gamescope \
  projects/ROCKNIX/packages/compat/fex-emu projects/ROCKNIX/packages/hardware/quirks \
  projects/ROCKNIX/packages/linux-firmware/extra-firmware
POCKNIX_SYNC_SCOPE=vendor make sync          # vendor/ only; leaves the committed kernel/ alone

# 2-5. kernel, packages, rootfs, image
sudo make seed                               # optional on aarch64, strongly recommended on x86_64
sudo make kernel
make pending                                 # what `make build` would still compile
sudo make build
sudo make sd-image                           # -> build/image/sm8550/pocknix-sm8550-sd.img
```

Flash the image with Balena Etcher, Rufus, or `dd`, then follow
[How to install](../../README.md#how-to-install) in the project README.

For an SD card **for SM8250**, sparse-checkout `projects/ROCKNIX/devices/SM8250` instead of
`SM8550`. SM8250 has no firmware overlay (its blobs come from Arch's `linux-firmware`), so
nothing is fetched for it.

### Before `make build`: read `make pending`

`make pending` lists every package `make build` would compile. `make seed` only downloads a package
the published repo has at exactly your checkout's version, and skips any package folder with
uncommitted changes, so after seeding the list should hold only packages you changed, plus the
kernel package (`linux-pocknix-<soc>`, which is just repackaged from your `make kernel` output). If
it lists something big like `mesa`, `gamescope` or `dolphin-emu`, your checkout and the published
repo disagree on that package's version - usually your checkout is older or newer than the last
publish. Compiling it under qemu takes hours; updating your checkout (`git pull`, then
`sudo make seed` again) is usually the better fix.

### Useful build options

Set these on the `make` command line, after `sudo` (for example `sudo SD_SSH=on make sd-image`):

| Option | Effect |
|---|---|
| `SD_SSH=on` | enable SSH in the image (the root and `deck` password is `pocknix` - test images only) |
| `SD_WIFI_SSID=... SD_WIFI_PSK=... SD_WIFI_COUNTRY=US` | pre-configure Wi-Fi in the image |
| `POCKNIX_EMULATION=1` | bake the emulation layer (ES-DE and emulators) into the image |
| `DEVICE=sm8250` | build for the SM8250 family instead of SM8550 |
| `JOBS=N` | parallel jobs for the kernel build (default: all cores) |

## Building just a package

You do not need a full image to test a change. Build the package, copy it over, and install it on a
running device:

```bash
sudo make packages PKG="pocknix-branding"                  # -> build/localrepo/<soc|shared>/
scp build/localrepo/shared/pocknix-branding-*.pkg.tar.* root@<device>:/tmp/
ssh root@<device> 'pacman -U /tmp/pocknix-branding-*.pkg.tar.*'
```

A package whose build needs packages pocknix builds itself (for example `pocknix-steam` needs
`gamescope`) finds them in `build/localrepo/`, so run `sudo make seed` once first. See
[CONTRIBUTING.md](../../CONTRIBUTING.md) for how to test and submit a change.

## Space and time

Plan on roughly **80 GB free** for a full build (build chroot, rootfs, kernel tree with debug info,
caches, and the image). Rough times on a recent 8-core x86_64 PC: kernel 20-40 minutes the first
time, `make seed` depends on your connection (several GB), `make build` one to three hours under
qemu, `make sd-image` 10-20 minutes. An aarch64 host is faster for the package and rootfs steps.
`make kernel` does nothing when `kernel/<soc>/` has not changed since its last build, and with
ccache installed a small kernel change rebuilds in minutes.
