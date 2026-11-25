#!/usr/bin/env bash
# Cat Reminders - clean removal: menu entries, autostart and the program folder
set -u

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
DEST="$DATA_DIR/cat-reminders"
APPS="$DATA_DIR/applications"
AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"

echo "Removing Cat Reminders..."
rm -f "$APPS/cat-reminders.desktop"
rm -f "$AUTOSTART/cat-reminders.desktop"

pkill -f "$DEST/cat-reminders.py" 2>/dev/null || true
pkill -f "$DEST/cat-reminders-launcher.sh" 2>/dev/null || true
sleep 1

rm -rf "$DEST"
echo "Done. The cat has left the house."
