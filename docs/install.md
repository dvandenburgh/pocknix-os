# Install pocknix-os

pocknix-os runs from a microSD card. Once it is up you can [move it to internal
storage](install-to-internal.md) for faster loading.

**You need** a microSD card: 64 GB works but fills up fast once games are installed, so 128 GB or
larger is recommended.

## 1. Flash the SD card

Grab the image for your device from the
[latest release](https://github.com/shuuri-labs/pocknix-os/releases/latest), decompress it
(`zstd -d`, 7-Zip, or let your flasher do it), and flash it to the microSD card (Balena Etcher,
`dd`, etc.).

## 2. Install the ROCKNIX bootloader

The ROCKNIX ABL replaces the stock bootloader with one that can boot Linux from the SD card or
internal storage. It is **required** on every device.

The flashed SD card carries the install kit in its `rocknix_abl` folder, visible from Android when
the card is inserted.

1. Copy the `rocknix_abl` folder from the SD card to the root of Android's internal storage.
2. Open **Settings → Handheld Settings → Advanced → Run Script as Root**, go into the `rocknix_abl`
   folder you just copied, and run `backup_abl.sh` (saves your stock bootloader next to the
   scripts), then `flash_abl.sh`.
3. **(Recommended)** copy the `abl_a.img` / `abl_b.img` backups from that folder to somewhere off
   the device. Installing pocknix to internal storage later wipes Android's data, backups
   included, and they are the only way back to the factory bootloader (see
   [restoring the stock bootloader](install-to-internal.md#restoring-the-stock-bootloader)).

## 3. Boot pocknix

1. Hold **Volume −** while powering on to open the ABL menu. Volume keys move through the entries,
   the power key selects.
2. Set **Boot mode** to **Linux** and **Boot source** to **SD Card**, and **set the device model
   to Retroid Pocket 6** (a wrong model gives a black screen).
3. Insert the flashed microSD and boot.

The first boot into game mode can take a long while, especially from an SD card. Leave it be; it
will come up.

> [!IMPORTANT]
> **Then change the default password.** It is `pocknix` and publicly known: run `passwd` (and
> `sudo passwd root`) in a terminal. SSH is off by default.

## Updating

Updates, kernel included, arrive through the pocknix package repo, with no reflashing. Any of:

- **Pocknix Control (recommended)**: Quick Access Menu → **Pocknix Control** → **Updater** →
  **Check for Updates** → **Install Updates**, without leaving game mode.
- **Pocknix Updater**: in desktop mode, launch the **Pocknix Updater** app.
- **Terminal**: `sudo pacman -Syu`, like any Arch system.

The Steam client updates itself separately and tells you when one is available. If an update goes
wrong, see [snapshots and rollback](snapshots.md).
