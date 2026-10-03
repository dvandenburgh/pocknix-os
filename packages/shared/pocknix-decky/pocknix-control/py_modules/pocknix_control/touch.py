from pathlib import Path

from .tweaks import load_tweaks

# The kernel's per-device inhibit switch (5.11+): an inhibited device is closed at the
# driver and emits nothing, to gamescope and Steam alike. It does not survive a reboot.
INPUT_DIR = Path("/sys/class/input")
UDEV_DATA = Path("/run/udev/data")


def touchscreens(input_dir=INPUT_DIR, udev_data=UDEV_DATA):
    # udev's own classification, so any board's panel is found without naming its driver.
    found = []
    for dev in sorted(input_dir.glob("input*")):
        try:
            props = (udev_data / f"+input:{dev.name}").read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        if "E:ID_INPUT_TOUCHSCREEN=1" in props and (dev / "inhibited").exists():
            found.append(dev)
    return found


def touch_disabled_for(tweaks, appid):
    # Same merge as the proton wrapper: per-game values only count while the game is enabled.
    settings = dict(tweaks.get("global") or {})
    game = (tweaks.get("games") or {}).get(str(appid)) if appid else None
    if isinstance(game, dict) and game.get("enabled") is True:
        settings.update(game)
    return bool(appid) and settings.get("touchDisabled") is True


def set_touch(disabled, input_dir=INPUT_DIR, udev_data=UDEV_DATA):
    for dev in touchscreens(input_dir, udev_data):
        try:
            (dev / "inhibited").write_text("1" if disabled else "0")
        except OSError as exc:
            print(f"pocknix-control: failed to set {dev.name} inhibited: {exc}")


def sync_touch(running_appid):
    # None = no game running, which always means touch on.
    set_touch(touch_disabled_for(load_tweaks(), running_appid) if running_appid else False)
