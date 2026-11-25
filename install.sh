#!/usr/bin/env bash
# Cat Reminders - installs into ~/.local/share/cat-reminders and wires autostart
set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
DEST="$DATA_DIR/cat-reminders"
APPS="$DATA_DIR/applications"
AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"

echo "Cat Reminders installer"
echo

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required, but was not found."
    exit 1
fi

if ! python3 - <<'PY'
import cairo
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Gtk, GdkPixbuf, PangoCairo  # noqa: F401
PY
then
    echo "The GTK 3 Python bindings are missing. Install them with:"
    echo
    if command -v apt-get >/dev/null 2>&1; then
        echo "  sudo apt install python3-gi python3-cairo gir1.2-gtk-3.0 \\"
        echo "                   gir1.2-pango-1.0 gir1.2-gdkpixbuf-2.0"
        echo "  sudo apt install gir1.2-xapp-1.0    # tray icon on Linux Mint"
    elif command -v dnf >/dev/null 2>&1; then
        echo "  sudo dnf install python3-gobject python3-cairo gtk3 pango \\"
        echo "                   gdk-pixbuf2 libxapp"
    elif command -v pacman >/dev/null 2>&1; then
        echo "  sudo pacman -S python-gobject python-cairo gtk3 pango \\"
        echo "                 gdk-pixbuf2 xapp"
    else
        echo "  Install GTK 3 + PyGObject + pycairo + Pango + GdkPixbuf + XApp."
    fi
    echo
    exit 1
fi

python3 - <<'PY' || echo "note: XApp not found - the tray will use appindicator / Gtk.StatusIcon instead"
import gi
gi.require_version("XApp", "1.0")
from gi.repository import XApp  # noqa: F401
PY

echo "Installing to $DEST ..."
mkdir -p "$DEST" "$APPS" "$AUTOSTART"
install -m 755 "$SRC/cat-reminders.py" "$DEST/cat-reminders.py"
install -m 755 "$SRC/cat-reminders-launcher.sh" "$DEST/cat-reminders-launcher.sh"

# the Linux build uses only the bundled cutout and sound
if [ -f "$SRC/cat_cut.png" ]; then cp -f "$SRC/cat_cut.png" "$DEST/"; fi
if [ -f "$SRC/meow.wav" ]; then cp -f "$SRC/meow.wav" "$DEST/"; fi

ICON="$DEST/cat_cut.png"
if [ ! -f "$ICON" ] && [ -f "$DEST/cat.png" ]; then ICON="$DEST/cat.png"; fi
if [ ! -f "$ICON" ] && [ -f "$SRC/cat.png" ]; then ICON="$SRC/cat.png"; fi
if [ ! -f "$ICON" ]; then ICON="applications-system"; fi

echo "Creating Start Menu entry..."
cat > "$APPS/cat-reminders.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Cat Reminders
GenericName=Hydration Reminder
Comment=A cat in the tray reminds you to drink water
Exec="$DEST/cat-reminders-launcher.sh" --show-panel
Icon=$ICON
Terminal=false
Categories=Utility;
StartupNotify=false
EOF

echo "Creating logon auto-start (45 second delay)..."
cat > "$AUTOSTART/cat-reminders.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Cat Reminders
Comment=The cat wakes up shortly after login
Exec="$DEST/cat-reminders-launcher.sh" --delayed
Icon=$ICON
Terminal=false
X-GNOME-Autostart-enabled=true
StartupNotify=false
EOF

echo "Starting the cat ..."
nohup "$DEST/cat-reminders-launcher.sh" >/dev/null 2>&1 &
echo
echo "Done. The cat lives next to your clock now."
echo "(reminders.json keeps your data; uninstall.sh removes everything)"
