#!/bin/sh
# Cat Reminders launcher.
#   --delayed   wait for the logon crunch (used by the autostart entry)
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "${1:-}" = "--delayed" ]; then
    sleep 45
    shift
fi
exec python3 "$here/cat-reminders.py" "$@"
