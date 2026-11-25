"""Logic tests for the Linux port. Run with: python3 tests/run_all.py"""

import importlib.util
import json
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE / "stubs"))

spec = importlib.util.spec_from_file_location(
    "cat_reminders", ROOT / "cat-reminders.py")
cr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cr)

# --- PowerShell writes 7 fractional digits and an offset
raw = "2026-11-09T20:13:30.5796606+05:30"
parsed = cr.parse_dt(raw)
assert parsed is not None, "failed to parse PowerShell timestamp"
assert parsed.tzinfo is None, "timestamps must come back as local naive"
assert cr.parse_dt(None) is None
assert cr.parse_dt("") is None
assert cr.parse_dt("garbage") is None

now = datetime.now()
back = cr.parse_dt(cr.iso_now(now))
assert abs((back - now).total_seconds()) < 1.0, (back, now)

# --- quiet hours, including the overnight range
core = cr.CatCore(None)
core.settings = {"quietEnabled": True, "quietFrom": "23:00", "quietTo": "07:00"}
assert core.quiet_hours(datetime(2026, 1, 1, 23, 30)) is True
assert core.quiet_hours(datetime(2026, 1, 1, 3, 0)) is True
assert core.quiet_hours(datetime(2026, 1, 1, 7, 0)) is False
assert core.quiet_hours(datetime(2026, 1, 1, 12, 0)) is False
core.settings = {"quietEnabled": True, "quietFrom": "08:00", "quietTo": "17:00"}
assert core.quiet_hours(datetime(2026, 1, 1, 8, 0)) is True
assert core.quiet_hours(datetime(2026, 1, 1, 17, 0)) is False
core.settings = {"quietEnabled": False, "quietFrom": "23:00", "quietTo": "07:00"}
assert core.quiet_hours(datetime(2026, 1, 1, 23, 30)) is False
core.settings = {"quietEnabled": True, "quietFrom": "nonsense", "quietTo": "07:00"}
assert core.quiet_hours(datetime(2026, 1, 1, 23, 30)) is False

# --- storage round trip in a temp folder
tmp = Path(tempfile.mkdtemp(prefix="cat-reminders-test-"))
cr.REMINDERS_FILE = tmp / "reminders.json"
cr.SETTINGS_FILE = tmp / "settings.json"
cr.CACHE_DIR = tmp / "cache"

core = cr.CatCore(None)
core.load_reminders()
assert len(core.reminders) == 1
assert core.reminders[0]["Type"] == "repeat"
core.load_settings()
assert core.settings["quietEnabled"] is False
assert core.settings["glasses"] == 0

core.add_glass(2)
assert core.settings["glasses"] == 2
assert core.settings["glassesTotal"] == 2
saved = json.loads(cr.SETTINGS_FILE.read_text(encoding="utf-8"))
assert saved["glasses"] == 2, saved

core.load_settings()
assert core.settings["glasses"] == 2

# --- snooze: repeat reminders come back in ~10 minutes
rem = {"Type": "repeat", "Message": "water", "IntervalMinutes": 60,
       "LastShown": cr.iso_now(datetime.now()), "FireAt": None}
core.reminders = [rem]
core.snooze(rem, 10)
last = cr.parse_dt(rem["LastShown"])
mins = (datetime.now() - last).total_seconds() / 60.0
assert 49 < mins < 51, mins

# --- snooze: one-time reminders are put back on the list
once = {"Type": "once", "Message": "later", "IntervalMinutes": None,
        "LastShown": None, "FireAt": cr.iso_now(datetime.now() - timedelta(minutes=5))}
core.reminders = []
core.snooze(once, 10)
assert len(core.reminders) == 1
assert cr.parse_dt(once["FireAt"]) > datetime.now() + timedelta(minutes=9)

# --- a one-time reminder due now is dropped and sent to the popup
core.reminders = [dict(once, FireAt=cr.iso_now(datetime.now() - timedelta(minutes=1)))]
core.popup_active = False
sent = []
core.show_popup = lambda message, rem=None: sent.append((message, rem))
core.check_reminders()
assert core.reminders == [], core.reminders
assert len(sent) == 1 and sent[0][1]["Message"] == "later"

print("test_logic.py: OK")
