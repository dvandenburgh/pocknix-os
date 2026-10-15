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

1. **Kernel** - `make kernel` builds the committed kernel (`kernel/<soc>/`) into a boot image.
2. **Packages** - `make build` first builds every pocknix package that is not already in
   `build/localrepo/`; `make seed` fills that from the published repo so only real changes compile.
3. **Root filesystem** - `make build` then installs the Arch Linux ARM base and the packages into
   `build/rootfs/`, and pre-installs the ARM Steam client so first boot works offline.
4. **Image** - `make sd-image` turns that into a flashable `build/image/<soc>/pocknix-<soc>-sd.img`.

`make help` lists every target; `make check` is a preflight that also reports what this host is
missing for an image build.

## Quick start

This tree builds the Retroid Pocket 6 (SoC family `sm8550`).

```bash
git clone https://github.com/dvandenburgh/pocknix-os && cd pocknix-os
./build.sh                                   # -> build/image/sm8550/pocknix-sm8550-sd.img
```

`./build.sh` is the whole build in one command (`make image` is the same thing). Run it as
yourself: it asks `sudo` once, for the steps that need root. On a fresh host it first runs
`make host-setup` to install the build packages (`--no-host-setup` stops and lists them instead).
The kernel and every package skip themselves when already current, so after an
interruption (or a change) the same command redoes only what it must; the rootfs and the image are
always rebuilt.

```bash
./build.sh --ssh                             # SSH on in the image (make image SSH=1)
./build.sh --ssh --wifi MyNet --wifi-psk secret --wifi-country US
./build.sh --no-sd-image                     # stop at the finished rootfs (make rootfs)
./build.sh --help                            # every option
```

These are the steps it runs, and each is a target of its own:

```bash
make check                                   # host lines must say ok (make host-setup fixes most)
sudo make seed                               # optional on aarch64, strongly recommended on x86_64
sudo make kernel
make pending                                 # what `make build` would still compile
sudo make build
sudo make sd-image                           # -> build/image/sm8550/pocknix-sm8550-sd.img
```

Flash the image with Balena Etcher, Rufus, or `dd`, then follow
[How to install](../../README.md#how-to-install) in the project README.

Device firmware is a package like any other (`pocknix-firmware-sm8550`, fetched at a pinned
commit and checked by sha256), so no step puts it in
place by hand. `make sync` only refreshes ROCKNIX
reference material in `vendor/`, which no build reads.

If you keep a ROCKNIX checkout of your own at `../distribution` (or point `DISTRIBUTION_DIR` at
one), `make sync` reads it instead of the pinned commit. With `POCKNIX_SYNC_SCOPE=all` it also
refreshes the committed kernel inputs in `kernel/<soc>/` from it: that is how the kernel moves to a
newer ROCKNIX.

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

Give them to `./build.sh` as flags, or set the variable on the `make` command line or in your
environment (for example `make image SSH=1`, `export SSH=1` to make it the default, or
`sudo SSH=1 make sd-image` for a single step). The on/off switches take `on`/`off`, `1`/`0`,
`yes`/`no` or `true`/`false`.

| `./build.sh` flag | Variable | Effect |
|---|---|---|
| `--ssh` / `--no-ssh` | `SSH=1` (or `SD_SSH=on`) | SSH in the image (the root and `deck` password is `pocknix` unless you set one - test images only) |
| `--password PW` | `SD_ROOT_PASSWORD=PW` | the root and `deck` password baked into the image |
| `--wifi SSID --wifi-psk PSK --wifi-country US` | `SD_WIFI_SSID= SD_WIFI_PSK= SD_WIFI_COUNTRY=` | pre-configure Wi-Fi in the image |
| `--emulation` | `POCKNIX_EMULATION=1` | bake the emulation layer (ES-DE and emulators) into the image |
| `--jobs N` | `JOBS=N` | parallel jobs for the kernel build (default: all cores) |
| `--no-sd-image` | `SD_IMAGE=off` | stop at the finished rootfs (`make rootfs`) |
| `--no-seed` | `POCKNIX_SEED=off` | compile every package instead of downloading the published ones |
| `--no-host-setup` | `POCKNIX_HOST_SETUP=off` | stop when host packages are missing instead of installing them |
| `--no-status-bar` | `POCKNIX_STATUS_BAR=off` | plain output, without the status line at the bottom |

### Watching a build

While `./build.sh` runs, the bottom row of the terminal is a status bar: the step it is on, what
that step is doing (which package is compiling, for example), the time so far, and an estimate of
the time left with the clock time it should finish. The terminal's title shows the same in short,
so you can see it from another tab. From any other shell in the checkout:

```bash
make status                                  # every step: its time, or its estimate
make watch                                   # the same, redrawn every 2 s until the build ends
```

The estimate comes from how long each step, and each package, took on this machine the last time
(kept in `build/progress/`), and from the same checks the steps use to skip work: a current kernel
or package counts as seconds, not hours. The first build on a machine has nothing to go on, so its
estimate is a rough guess and says so; from the second build on it is close.

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
