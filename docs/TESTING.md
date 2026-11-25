# Linux manual validation checklist

Run these on an X11 desktop (Linux Mint Cinnamon is the reference). The
GTK-free logic tests can be run anywhere with `python3 tests/run_all.py`;
the steps below need a real desktop session.

## 1. Environment

```bash
echo "$XDG_SESSION_TYPE"        # must say x11, not wayland
bash verify-linux.sh            # checks bindings, tools and installed files
```

If `XDG_SESSION_TYPE` is `wayland`, log out and choose a "Cinnamon" (or other
X11) session at the login screen.

## 2. Install

```bash
bash install.sh
```

Expected: app folder at `~/.local/share/cat-reminders`, a desktop entry in
`~/.local/share/applications/cat-reminders.desktop`, an autostart entry in
`~/.config/autostart/cat-reminders.desktop`, and the tray icon appears.

## 3. Tray and panel

- [ ] Cat icon appears next to the clock.
- [ ] Left-click opens the menu; "Open reminder panel" shows the settings window.
- [ ] "Show the cat now" pops up the translucent cat immediately.
- [ ] Quiet hours menu item toggles ON/OFF and shows a notification.
- [ ] Closing the panel does not quit the app; the tray icon remains.
- [ ] "Exit (fire the cat)" actually quits and removes the icon.

## 4. Popup interactions

- [ ] The cat sits at the bottom-right with no window frame; transparent areas are click-through.
- [ ] Hovering starts a 10-second countdown ("closing in Ns..."), then it closes.
- [ ] Left-click logs one glass and closes the popup; the panel tally increments.
- [ ] Right-click snoozes for 10 minutes, shows "Snoozed...", then closes.
- [ ] Double-click activates quiet mode for one hour (a notification confirms it).
- [ ] The bundled meow plays (if a player is available).
- [ ] An ignored popup closes itself after 5 minutes.

## 5. Reminder engine

- [ ] Add a repeating reminder every 1 minute; it pops up, then again a minute later.
- [ ] Add a one-time reminder "in 1 minute"; it fires once and disappears from the list.
- [ ] A one-time reminder set in the past fires on the next 15-second check.
- [ ] With quiet hours ON, no popups appear during the quiet window (overnight ranges included).
- [ ] Fullscreen a video/game: due reminders wait until it is no longer fullscreen.

## 6. Startup and memory

- [ ] Log out and back in; the cat appears roughly 45 seconds later.
- [ ] After a few minutes idle, check memory: `smem -P cat-reminders` (PSS column).
- [ ] Open/close the panel and trigger a popup; memory should fall back afterwards.
- [ ] `~/.local/share/cat-reminders/debug.log` shows launches, tray setup and shutdown.

## 7. Screenshots for the README

The images currently in `docs/` are from Windows. To replace them on Linux,
trigger "Show the cat now" from the tray, then capture the screen with whichever
tool is installed:

```bash
gnome-screenshot -f docs/screenshot-popup-linux.png   # GNOME/Mint
# or: scrot docs/screenshot-popup-linux.png
# or: import -window root docs/screenshot-popup-linux.png
```

Open the panel and capture it likewise to `docs/screenshot-panel-linux.png`,
then add both images to the README if you want Linux-specific pictures.
