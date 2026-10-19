# Cat Reminders

A Windows system-tray application that surfaces periodic reminders through a frameless, transparent speech-bubble popup voiced by your cat. Pure PowerShell and WinForms — no frameworks, no installers, no dependencies beyond stock Windows 10/11.

<p align="center">
  <img src="docs/screenshot-popup.png" alt="Reminder popup" width="260">
</p>

## Features

**Reminder scheduling**
- Repeating reminders — fire every *N* minutes (e.g. drink water every 60 min)
- One-shot reminders — either relative ("in 30 minutes") or absolute clock time ("at 17:30", rolled to tomorrow if the time has passed); removed automatically after firing
- Per-reminder custom message

**Popup interaction**
- Borderless layered window: only the speech bubble and the cat are visible; the rest of the window is transparent and click-through
- Click the cat (or the bubble) to dismiss
- Hovering the cat starts a one-shot 10-second visual countdown that dismisses the popup regardless of clicks; the countdown does not reset on re-touch
- Right-click the cat to snooze the responsible reminder by 10 minutes
- Double-click to activate quiet mode for one hour (confirmed via tray balloon)
- 5-minute safety auto-close if ignored

**Power**
- 15-second scheduler tick against persisted reminders, decoupled from the UI
- Tray icon with context menu; closing the panel hides to tray instead of exiting
- Single-instance guard (named mutex); duplicate launches exit silently
- Auto-start 45 seconds after logon (delayed so it does not compete with startup), Start Menu launch remains instant
- Performance profile: ~13 MB resident working set, *BelowNormal* process priority, working-set trim on popup dismissal; the C# image pipeline is precompiled (`catproc.dll`) so no compiler runs at launch

## Getting started

Requires Windows 10 or 11 (Windows PowerShell 5.1, which ships with the OS).

1. Clone or download this repository.
2. Launch with `launch-cat.vbs` — it starts the app with no visible console window. The Start Menu shortcut (if you created one) targets this file.
3. For auto-start at boot, create a shortcut in `shell:startup` pointing at `autostart-cat.vbs` (or `launch-cat.vbs` if you prefer no delay).

The cat lives in the system tray. Double-click the tray icon (or use its context menu) to open the control panel:

<p align="center">
  <img src="docs/screenshot-panel.png" alt="Control panel" width="470">
</p>

## Configuration

Reminders are persisted as JSON in `reminders.json` next to the script and reloaded at launch:

```json
[
  { "Message": "Drink some water! Stay hydrated \\_/", "Type": "repeat", "IntervalMinutes": 60, "LastShown": null },
  { "Message": "Stand up", "Type": "one-time-at", "LastShown": null, "FireAt": "2026-10-19T17:30:00" }
]
```

| Field            | Used by              | Meaning                                                            |
|------------------|----------------------|--------------------------------------------------------------------|
| `Message`        | all                  | Text shown in the speech bubble                                     |
| `Type`           | all                  | `repeat`, `one-time-i-n` (relative) or `one-time-at` (clock time)    |
| `IntervalMinutes`| `repeat`             | Minutes between firings                                             |
| `FireAt`         | one-shot types       | Local ISO 8601 timestamp; absolute fires on it, relative is precomputed when created |
| `LastShown`      | `repeat`             | Managed automatically — the anchor used to compute the next firing   |

One-shot reminders are deleted once they have fired. `LastShown: null` on a repeating reminder makes it fire on the soonest scheduler tick.

## Customization

- **`cat.png`** — replace with your own artwork (PNG). The app automatically removes flat checkerboard/white backgrounds baked into the image (flood fill from the borders + small-island cleanup), crops tight to the subject and caches the result as `cat_cut.png`; a newer `cat.png` triggers regeneration on the next launch. A PNG with genuine transparency works best.
- **`meow.wav`** — any short WAV to play when a reminder appears. A CC0 cat meow is bundled; drop in your own to replace it.

## Technical overview

- `cat-reminders.ps1` — the entire application: panel, reminder engine, tray integration and the layered popup (color-key transparency, custom-painted bubble, managed hover countdown).
- `catproc.dll` — C# helper compiled with the .NET Framework tools: background removal, tight crop, and a memory-trim routine (`SetProcessWorkingSetSize`) used to keep the resident footprint low. The equivalent source is also embedded in the script as a fallback compiled in-memory if the DLL cannot be loaded, so the script remains functional on its own.
- `autostart-cat.vbs` / `launch-cat.vbs` — launchers; the autostart variant waits out the logon spike before handing over to `launch-cat.vbs`.

## Security notes

- **The app performs no network I/O at any point in its runtime.** No telemetry, no update checks, no downloads. Everything is local: JSON state in the script folder, GDI+ rendering, one local WAV file.
- **`catproc.dll` is a build artifact, not a dependency to trust blindly.** Its SHA-256 is
  `492F82BBEE9E5121A5EF2A600DD1D3F43AA9AEDB0917BDD3303E8E26DC6876B2`
  It can be rebuilt from the C# embedded in `cat-reminders.ps1` (extract the block following `Add-Type -TypeDefinition`, compile with
  `csc /nologo /target:library /optimize+ /out:catproc.dll /r:System.Drawing.dll catproc.cs`)
  — or simply deleted: the script then compiles the same source in-memory at launch.
- **The launchers execute a script stored in a user-writable location.** This is standard for per-user software, but it means any process already running as your user could modify `cat-reminders.ps1` and have it executed at the next logon. If you deploy on a shared machine, copy the folder to an admin-only location (e.g. `C:\Program Files\CatReminders`) and point the shortcuts and `shell:startup` entries there.
- The `-ExecutionPolicy Bypass` in the launchers is required to run a standalone-from-path script and is process-scoped only; it does not change the machine-wide execution policy.
- The popup is a TopMost overlay, but every element it shows originates from your own `reminders.json`; nothing can inject content into it without write access to that file (same user context as above).


## License

[MIT](LICENSE). The bundled meow sound ("Meow of a Siamese cat") is CC0, sourced from Wikimedia Commons.
