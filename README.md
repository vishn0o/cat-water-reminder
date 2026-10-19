# cat-water-reminder

A little tray app for Windows that pops a cat in the corner of your screen to tell you to drink water. I built it because I kept forgetting, and because a cat nagging you is easier to ignore than an alarm.

It's one PowerShell script plus a tiny compiled helper. No dependencies, no installer — if you have Windows 10/11, it just runs.

![popup](docs/screenshot-popup.png)

## What it does

Reminders come in three kinds:

- **Repeating** — nags you every N minutes, like "drink water" every 60
- **One time, in a while** — "remind me in 30 minutes"
- **One time, at a time** — "remind me at 17:30" (rolls to tomorrow if that already passed)

One-time reminders disappear once they've fired. Everything survives restarts.

The popup itself is a borderless transparent window — no window chrome, no rectangle, just the speech bubble and the cat. Click it to close it. If you hover the cat, a 10-second countdown shows up in the bubble and it dismisses itself when the countdown hits zero; touching the cat again doesn't reset the count, and clicking still closes it instantly.

The gestures:
- **Right-click the cat** → snoozes that reminder by 10 minutes
- **Double-click** → quiet for one hour (you get a tray balloon confirming it)

The bubble text is the reminder message, and below it a random flavor line — "Sip. Sip. Purr. Repeat.", "Pspsps... drink your water, hooman!", that sort of thing. There's also a bundled cat meow sound when it pops up; drop your own `meow.wav` in if you'd rather hear a different cat.

## Getting it running

Clone the repo, then launch `launch-cat.vbs`. That's it — it starts with no console window and lives in the system tray. Double-click the tray icon for the control panel:

![panel](docs/screenshot-panel.png)

Close it whenever — the cat keeps running in the tray. For auto-start after boot, put a shortcut to `autostart-cat.vbs` in `shell:startup` (it waits 45 seconds after logon so it doesn't fight your browser for boot time).

## Reminders file

`reminders.json`, created next to the script:

```json
[
  { "Message": "Drink some water!", "Type": "repeat", "IntervalMinutes": 60, "LastShown": null },
  { "Message": "Meeting at 17:30", "Type": "one-time-at", "LastShown": null, "FireAt": "2026-10-19T17:30:00" }
]
```

You rarely need to touch this by hand — the panel writes it for you. `FireAt` is a local ISO timestamp.

## Your own cat

Drop your own picture in as `cat.png`. The app cleans up the image automatically: it strips flat checkerboard/white backgrounds (flood-fill from the borders plus a cleanup pass for leftover squares), crops tight around the subject, and caches the result as `cat_cut.png`. A PNG with real transparency looks best, but a screenshot of one gets handled too. Want a different meow? Replace `meow.wav`.

## How it's put together

`cat-reminders.ps1` is the whole app — panel, scheduler, tray icon, popup. Image cleanup lives in `catproc.dll` (a small C# helper; the same source is embedded in the script as a fallback that compiles in-memory, so deleting the DLL is harmless). The app keeps a low profile: ~13 MB resident, BelowNormal priority, working set trimmed whenever a popup closes.

## License

MIT. The bundled meow is CC0 (Wikimedia Commons).
