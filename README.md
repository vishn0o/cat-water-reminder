# cat-water-reminder

A cat lives in your system tray and pops up now and then to tell you to drink water. Made because I kept forgetting and alarms are annoying.

One PowerShell script, no installer, no dependencies. Runs on any Windows 10/11.

![popup](docs/screenshot-popup.png)

- Cat says things every N minutes, or once at a set time (then leaves)
- Click the cat to shoo it away. Hover it and it gives you 10 seconds before leaving on its own
- Right-click = snooze 10 min, double-click = quiet for an hour

The looks are customizable: drop in any image as `cat.png` (it auto-crops and strips the background, even if you screenshot it off some website) and any sound as `meow.wav`. The popup lines the cat says can be changed in the script too — there's a list of them at the top.

Panel looks like this, if you're into settings:

![panel](docs/screenshot-panel.png)

Launch `launch-cat.vbs`, forget about it. Reminders survive reboots, the app idles at ~13 MB, and it starts itself 45 seconds after login so it doesn't slow your boot.

MIT. Meow is CC0 from Wikimedia.
