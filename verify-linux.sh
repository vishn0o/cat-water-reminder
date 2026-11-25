#!/usr/bin/env bash
# Quick environment/install check for the Linux build.
# The full manual GUI checklist lives in docs/TESTING.md.
set -u

echo "Cat Reminders - Linux environment check"
echo

session=${XDG_SESSION_TYPE:-unknown}
echo "Session type: $session"
case "$session" in
    x11) ;;
    wayland) echo "WARNING: Wayland is not supported; use an X11 session." ;;
    *) echo "NOTE: expected an X11 session (XDG_SESSION_TYPE=x11)." ;;
esac
echo

if python3 - <<'PY'
import cairo
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Gtk, GdkPixbuf, PangoCairo  # noqa: F401
PY
then
    echo "GTK 3 Python bindings: OK"
else
    echo "GTK 3 Python bindings: MISSING (see README for apt/dnf/pacman packages)"
fi

for tool in xprop notify-send paplay aplay canberra-gtk-play ffplay pw-play; do
    if command -v "$tool" >/dev/null 2>&1; then
        echo "tool $tool: found"
    fi
done
echo

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
DEST="$DATA_DIR/cat-reminders"

for file in "$DEST/cat-reminders.py" "$DEST/cat-reminders-launcher.sh" \
            "$DEST/cat_cut.png" "$DEST/meow.wav" \
            "$DATA_DIR/applications/cat-reminders.desktop" \
            "$CONFIG_DIR/autostart/cat-reminders.desktop"; do
    if [ -f "$file" ]; then
        echo "OK      $file"
    else
        echo "MISSING $file (run 'bash install.sh' from the repo)"
    fi
done
echo

if command -v smem >/dev/null 2>&1; then
    smem -P cat-reminders || true
else
    echo "Install 'smem' to see PSS/USS memory (optional)."
fi

echo
echo "Full manual checklist: docs/TESTING.md"
