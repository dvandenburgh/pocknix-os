# Using the controller in desktop mode

In game mode Steam owns the controller. In desktop mode, KWin's game controller support turns it
into a keyboard and pointer, so you can get around Plasma without touching the screen. As soon as a
game or emulator opens the controller, KWin stops and the game gets a normal gamepad; when it
closes, the desktop controls come back.

## The controls

Face buttons are listed by position, because the printed letters differ between devices.

| Control | In desktop mode |
|---|---|
| D-pad | arrow keys: move between home screen icons, list items, and keys on the on-screen keyboard |
| Bottom face button | Enter: open the highlighted app, press the highlighted key |
| Right face button | Escape: close a dialog or menu |
| Left face button | hide the on-screen keyboard (see [Typing](#typing)) |
| Top face button | Space |
| Left or right stick | move the pointer |
| R2 / L2 | left click / right click (press fully) |
| L1 / R1 | Ctrl / Alt (hold, then press another button) |
| Start | Meta (the Super/Windows key) |

## Moving around the home screen

Press the D-pad and a highlight appears on the apps; keep pressing to move it between them, and
press the bottom button to open the highlighted one. On a fresh install the apps are on the dock
along the bottom, so press down to reach them. On desktop Plasma the same works on desktop icons
once the desktop has focus (click an empty spot first).

## Typing

Tap a text field to bring up the on-screen keyboard. While it is up:

- the **D-pad** moves a highlight over the keys
- the **bottom button** presses the highlighted key, once a key is highlighted
- the **left face button** hides it

To bring it back, tap the field again. KWin only shows the keyboard for touch or a stylus, so
selecting a field with the pointer leaves it hidden.

## Turning it off

On desktop Plasma: **System Settings > Game Controller**, and switch off **Allow using as pointer
and keyboard**. On either flavour, from a terminal:

```bash
kwriteconfig6 --file kwinrc --group Plugins --key gamecontrollerEnabled false
```

then switch to game mode and back. Set it to `true` (or delete the line from `~/.config/kwinrc`)
to turn it on again. The on-screen keyboard's D-pad navigation is a separate switch,
**Keyboard navigation** in the virtual keyboard's settings.
