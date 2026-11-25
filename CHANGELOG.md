# Changelog

## [1.1] - 2026-11-25

### Added
- Linux port: `cat-reminders.py` (Python 3 + GTK 3) for Linux Mint and other X11 desktops.
- `install.sh` / `uninstall.sh` with XDG menu entry and 45-second logon delay.
- `cat-reminders-launcher.sh` for running without installing (`--delayed` for autostart).
- Tray icon via XApp, with AppIndicator and legacy `Gtk.StatusIcon` fallbacks.
- `verify-linux.sh`, `docs/TESTING.md`, and GTK-free logic tests under `tests/`.

### Changed
- README documents direct install on both Windows and Linux.
- Linux build uses only the bundled `cat_cut.png` and `meow.wav`; `cats/` and `meows/` folders are ignored.
- Panel is built on demand and popup buffers are released on close to keep idle memory low.

### Notes
- X11 and a compositor are required; Wayland is not supported.
- Windows implementation (`cat-reminders.ps1`) is unchanged.

## [1.0] - 2026-11-09

- Windows release: repeating and one-time reminders, tray menu, cat popup,
  snooze/quiet controls, quiet hours, fullscreen deferral, water tally,
  installer/uninstaller and 45-second autostart delay.
