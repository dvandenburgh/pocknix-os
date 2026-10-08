# Build troubleshooting

The errors a build host is most likely to hit, by the message you see. Start with `make check`:
its host lines catch most of these before a build starts.

## Host setup

**`sudo: effective uid is not 0, is /usr/bin/sudo on a file system with the 'nosuid' option set ...`**\
**`error binfmt qemu-aarch64 has flags 'POF', without C: sudo in the build chroot cannot gain root.`**

The qemu-aarch64 binfmt registration lacks the `C` flag, so `makepkg`'s `sudo` cannot become root
inside the ARM build chroot. Debian and Ubuntu (WSL included) register it that way. Fix:
[The qemu binfmt C flag](linux-host.md#3-the-qemu-binfmt-c-flag-x86_64-hosts).

**`error no enabled aarch64 binfmt handler on x86_64`**\
**`error cross-building on x86_64 needs /usr/bin/qemu-aarch64-static`**

qemu-user is not installed, or not registered with the kernel. Install the qemu package for your
distro from [linux-host.md](linux-host.md#1-host-packages) (on Arch, `qemu-user-static-binfmt` does
the registration). The registration is done by `systemd-binfmt` at boot, so on WSL make sure
[systemd is running](wsl.md#1-install-wsl-and-ubuntu).

**`error cross-building on x86_64: need aarch64-linux-gnu-gcc (or set CROSS_COMPILE)`**

`make kernel` needs the aarch64 cross compiler on an x86_64 host. Install it from
[linux-host.md](linux-host.md#1-host-packages); a toolchain with another prefix works with
`CROSS_COMPILE=<prefix>-`.

**`error missing required tool: pahole`** (or any other tool)

Install the host packages for your distro. The less obvious ones: `pahole` comes from `dwarves`
(`pahole` on Arch), `sgdisk` from `gdisk` (`gptfdisk` on Arch), and `bsdtar` from
`libarchive-tools` on Debian/Ubuntu.

**`checkout filesystem v9fs: build from a Linux filesystem instead`** (in `make check`; the name varies)

The checkout is on a Windows drive (`/mnt/c/...`) or another filesystem without Unix permissions.
Clone again under your Linux home (`~/pocknix-os`); see [wsl.md](wsl.md#3-clone-inside-linux-not-on-c).

**`btrfs (make sd-image) MISSING in this kernel`** (in `make check`)

`make sd-image` formats the root partition as btrfs. Try `sudo modprobe btrfs`; on WSL, run
`wsl --update` and `wsl --shutdown` in PowerShell.

**`gcc: fatal error: Killed signal terminated program cc1`**

The host ran out of memory. Close other programs, add swap, or lower the kernel build's parallelism
(`sudo JOBS=4 make kernel`). On WSL, raise the memory and swap limits in
[`.wslconfig`](wsl.md#2-give-wsl-enough-memory-and-disk).

## Firmware and kernel

**`error ROCKNIX device dir not found: ...`**

`make sync` cannot find your ROCKNIX checkout. Clone it as in the [Quick start](README.md#quick-start),
or point `DISTRIBUTION_DIR` at it. For a sparse clone, check that the `sparse-checkout set` step
ran and includes `projects/ROCKNIX/devices/<SOC>`.

**`error ROCKNIX firmware overlay not at .../vendor/... — run 'make sync'`**

`make build` needs the device firmware in `vendor/`, which only `make sync` puts there. Run
`POCKNIX_SYNC_SCOPE=vendor make sync` (see the [Quick start](README.md#quick-start)) and check that
`vendor/rocknix-sm8550/filesystem/usr/lib/kernel-overlays/base/lib/firmware` lists `ath12k` and
`qcom`.

**`error no SM8550 firmware in this ROCKNIX checkout, and no extra-firmware pin at ...`**

ROCKNIX moved the SM8550 firmware out of its tree on 2026-08-03, into its `extra-firmware` repo,
and `make sync` reads which commit of it to fetch from your checkout. Add that file to the sparse
checkout, then sync again:

```bash
git -C ../distribution sparse-checkout add projects/ROCKNIX/packages/linux-firmware/extra-firmware
POCKNIX_SYNC_SCOPE=vendor make sync
```

**`error could not fetch https://github.com/ROCKNIX/extra-firmware at ...`**

The build host cannot reach GitHub, or a proxy is in the way. `git` must be able to fetch from
`github.com`; check with `git ls-remote https://github.com/ROCKNIX/extra-firmware`.

**`git status` shows many changes under `kernel/` after `make sync`**

`make sync` ran without `POCKNIX_SYNC_SCOPE=vendor` and moved the committed kernel to whatever
your ROCKNIX checkout holds. Put it back with `git checkout -- kernel/` (plus `git clean -fd kernel/`
for files it added), then re-run the sync with the vendor scope.

**`error linux-pocknix-<soc> not in [pocknix] — run 'make kernel' first`**

`make build` packages the kernel from `make kernel`'s output. Run `sudo make kernel`, then
`sudo make build` again. `make seed` never downloads a kernel, on purpose: the image must boot the
kernel its modules were built with.

## Packages

**`make: *** No rule to make target 'seed'.  Stop.`**

Your checkout predates `make seed` and `make pending`. Update it (`git pull`).

**`make pending` lists `mesa`, `gamescope`, an emulator or another big package**

`make build` will compile it, and under qemu that can take hours. It is listed because your checkout
and the published repo disagree on its version: your checkout is newer or older than the last
publish, or you changed it. Updating your checkout (`git pull`, then `sudo make seed`) usually clears
it. If you did change that package, the compile is expected.

**`error could not read https://pocknix.shuuri.net/repo/<soc>/pocknix.db`**

`make seed` cannot reach the published repo. Check the connection (or proxy) from the build host;
the build itself still works without seeding, it just compiles every package.

**`error chroot base upgrade failed — refusing to build against a stale base`**

The package build chroot could not reach the Arch Linux ARM mirrors. Re-run when the network is
back.

**`make packages` prints the package list, then `make: *** [Makefile:...: packages] Error 2`**

Older checkouts failed this way when `build/localrepo/<soc>/` or `shared/` was empty, even though
every package built. Update your checkout; the packages that were built are fine.

## SD image

**`error loop partitions /dev/loopNp1/p2 did not appear`**

The kernel did not create partition devices for the image's loop device. This happens in containers
(Docker, Podman, systemd-nspawn) that do not pass `/dev` through: build on the host itself, or in
WSL2 directly. On a host, check that the `loop` module is loaded (`sudo modprobe loop`).

**`error must run as root (chroot/mount needed): try 'sudo make <target>'`**

`seed`, `packages`, `build` and `sd-image` need root, and the docs run `kernel` with `sudo` too so
everything under `build/` has one owner. `check`, `pending` and `sync` do not.
