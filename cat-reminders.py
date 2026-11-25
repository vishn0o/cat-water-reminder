#!/usr/bin/env python3
# ================= Cat Reminder Hub (Linux / GTK 3) =================
# A cat in your system tray. Add reminders in two flavors:
#   1) Repeating  - nag me every X minutes (e.g. drink water every 60)
#   2) One time   - pop up once, either "in X minutes" or "at 17:30"
# One-time reminders vanish after they fire.
# Uses the bundled cat_cut.png and meow.wav; no cat/meow folders on Linux.
#
# Linux port of cat-reminders.ps1. Same reminders.json / settings.json
# format, so both versions can read the same data.

import json
import math
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

try:
    import cairo
except ImportError:
    sys.stderr.write("python3-cairo is missing. Install it with:\n"
                     "  sudo apt install python3-cairo\n")
    sys.exit(1)

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
gi.require_version("Pango", "1.0")
gi.require_version("PangoCairo", "1.0")

from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk, Pango, PangoCairo  # noqa: E402

# XApp is the status-icon host Cinnamon/MATE/XFCE on Mint use.
XApp = None
try:
    gi.require_version("XApp", "1.0")
    from gi.repository import XApp  # noqa: F401
except (ValueError, ImportError):
    XApp = None

# AppIndicator typelibs are loaded only if XApp is unavailable: importing them
# on Mint just maps another library into memory for no benefit.
AppIndicator = None


def load_appindicator():
    global AppIndicator
    if AppIndicator is not None:
        return AppIndicator
    import importlib
    for namespace in ("AyatanaAppIndicator3", "AppIndicator3"):
        try:
            gi.require_version(namespace, "0.1")
            AppIndicator = importlib.import_module(
                "gi.repository." + namespace)
            break
        except Exception:
            AppIndicator = None
    return AppIndicator


APP_DIR = Path(__file__).resolve().parent
REMINDERS_FILE = APP_DIR / "reminders.json"
SETTINGS_FILE = APP_DIR / "settings.json"
# the Linux build intentionally uses the one bundled cat and the one bundled
# meow; it does not scan cats/ or meows/ folders
CAT_IMAGE = APP_DIR / "cat_cut.png"
CAT_FALLBACK = APP_DIR / "cat.png"
MEOW_FILE = APP_DIR / "meow.wav"
CACHE_DIR = APP_DIR / "cache"
LOG_FILE = APP_DIR / "debug.log"
ICON_FILE = CACHE_DIR / "tray-icon.png"

AUTO_CLOSE_SECONDS = 300   # popup auto-closes after 5 minutes if ignored

# cat flavor lines - shown in the bubble under the reminder message
FLAVORS = [
    "Pspsps... drink your water, hooman!",
    "Free lap if you hydrate. I keep my word.",
    "Water break! The cat has spoken.",
    "Sip. Sip. Purr. Repeat.",
    "Doctor cat prescribes: one glass of water.",
    "Your body is 70% water. Top it up!",
    "The bowl is empty... yours, not mine.",
    "You, hydrating = purrfect combo.",
    "Mandatory splash time \\_/",
    "Meow. Fluid maintenance, STAT.",
    "That glass won't drink itself.",
    "I heard a rumor you haven't sipped in a while.",
    "If you don't drink, I sit on your keyboard.",
    "Water now, treats later. Deal?",
    "Tail is twitching. That means: drink.",
    "New hour, new glass of water.",
    "Even I drink water. Well, I try not to look like it.",
    "You look dry. Tragic.",
    "Fill my bowl, fill your glass.",
    "The cat overlords demand hydration.",
    "Whisker reminder: hydrate!",
    "Break over. Water, please.",
    "Lap water later, glass water now.",
    "Your skin is basically fur you never grew. Water it.",
]


def log(message):
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (datetime.now().strftime("%H:%M:%S.%f")[:-3], message))
    except OSError:
        pass


def atomic_write(path, text):
    # fill a temp file first, then swap it in, so a crash can never leave
    # an empty reminders.json behind
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


_heap_trim = None


def trim_heap():
    """Best effort: hand freed malloc pages back to the OS (glibc only)."""
    global _heap_trim
    if _heap_trim is None:
        try:
            import ctypes
            _heap_trim = ctypes.CDLL(None).malloc_trim
        except Exception:
            _heap_trim = False
    if _heap_trim:
        try:
            _heap_trim(0)
        except Exception:
            pass


def parse_dt(value):
    """Parse PowerShell's ISO timestamps (7 fractional digits included)."""
    if not value:
        return None
    text = str(value).strip()
    text = re.sub(r"(\.\d{6})\d+", r"\1", text)
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        try:
            dt = datetime.strptime(text[:19], "%Y-%m-%dT%H:%M:%S")
        except ValueError:
            return None
    if dt.tzinfo is not None:
        dt = dt.astimezone().replace(tzinfo=None)
    return dt


def iso_now(dt=None):
    return (dt or datetime.now()).astimezone().isoformat()


def rem_type(rem):
    return str(rem.get("Type") or "repeat").lower()


def round_rect(cr, x, y, w, h, r):
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
    cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
    cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
    cr.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
    cr.close_path()


def logical_region_from_surface(surface, factor):
    """Pixel region of a scaled surface, converted back to window coordinates.

    GTK asks for input shapes in logical pixels but a cairo region read from
    the surface is in device pixels, so shrink every rectangle on HiDPI.
    """
    region = Gdk.cairo_region_create_from_surface(surface)
    if factor == 1:
        return region
    scaled = cairo.Region()
    for index in range(region.num_rectangles()):
        rect = region.get_rectangle(index)
        x0 = rect.x // factor
        y0 = rect.y // factor
        x1 = (rect.x + rect.width + factor - 1) // factor
        y1 = (rect.y + rect.height + factor - 1) // factor
        scaled.union(cairo.RectangleInt(
            x0, y0, max(1, x1 - x0), max(1, y1 - y0)))
    return scaled


def square_icon(pb, size=64):
    """Scale the default cat onto a transparent square canvas for the tray."""
    w, h = pb.get_width(), pb.get_height()
    ratio = min(size / float(w or 1), size / float(h or 1))
    nw = max(1, int(w * ratio))
    nh = max(1, int(h * ratio))
    scaled = pb.scale_simple(nw, nh, GdkPixbuf.InterpType.BILINEAR)
    canvas = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, True, 8, size, size)
    canvas.fill(0x00000000)
    scaled.composite(canvas, (size - nw) // 2, (size - nh) // 2, nw, nh, 0, 0, 1, 1,
                     GdkPixbuf.InterpType.BILINEAR, 255)
    return canvas


# ---------- core ----------

class CatCore:
    def __init__(self, app):
        self.app = app
        self.reminders = []
        self.settings = {}
        self.quiet_until = None
        self.cat_pixbuf = None
        self.font_family = "Sans"
        self.popup_queue = []
        self.popup_active = False
        self.popup = None
        self.panel = None
        self.tray = None
        self.tray_menu = None
        self.tray_quiet_item = None
        self.status_icon = None
        self.audio_player = None
        self.xprop = shutil.which("xprop")
        self.notify_send = shutil.which("notify-send")

    # ----- storage -----

    def load_reminders(self):
        fallback = False
        reminders = []
        if not REMINDERS_FILE.is_file():
            fallback = True
        else:
            try:
                raw = REMINDERS_FILE.read_text(encoding="utf-8-sig").strip()
            except OSError:
                raw = ""
            if not raw:
                fallback = True
            else:
                try:
                    data = json.loads(raw)
                    if isinstance(data, dict):
                        data = [data]
                    for item in data or []:
                        if isinstance(item, dict) and item:
                            item.setdefault("Type", "repeat")
                            item.setdefault("Message", "Drink some water!")
                            item.setdefault("IntervalMinutes", 60)
                            item.setdefault("LastShown", None)
                            item.setdefault("FireAt", None)
                            reminders.append(item)
                except (ValueError, TypeError):
                    fallback = True
                if not reminders:
                    fallback = True
        self.reminders = reminders
        if fallback:
            self.reminders = [{
                "Type": "repeat",
                "Message": "Drink some water! Stay hydrated \\_/_",
                "IntervalMinutes": 60,
                "LastShown": None,
                "FireAt": None,
            }]
            self.save_reminders()
            log("reminders file missing/empty/corrupt - persisted defaults")

    def save_reminders(self):
        try:
            atomic_write(REMINDERS_FILE,
                         json.dumps(self.reminders, indent=4, ensure_ascii=False) + "\n")
        except OSError as exc:
            log("could not save reminders: %s" % exc)

    def load_settings(self):
        defaults = {
            "quietEnabled": False,
            "quietFrom": "23:00",
            "quietTo": "07:00",
            "glasses": 0,
            "glassesDay": datetime.now().strftime("%Y-%m-%d"),
            "glassesTotal": 0,
        }
        if SETTINGS_FILE.is_file():
            try:
                data = json.loads(SETTINGS_FILE.read_text(encoding="utf-8-sig"))
                if isinstance(data, dict):
                    for key in defaults:
                        if key in data:
                            defaults[key] = data[key]
            except (OSError, ValueError, TypeError):
                pass
        today = datetime.now().strftime("%Y-%m-%d")
        if str(defaults.get("glassesDay")) != today:
            defaults["glasses"] = 0
            defaults["glassesDay"] = today
        self.settings = defaults

    def save_settings(self):
        try:
            atomic_write(SETTINGS_FILE,
                         json.dumps(self.settings, indent=4, ensure_ascii=False) + "\n")
        except OSError as exc:
            log("could not save settings: %s" % exc)

    def add_glass(self, n=1):
        today = datetime.now().strftime("%Y-%m-%d")
        if str(self.settings.get("glassesDay")) != today:
            self.settings["glasses"] = 0
            self.settings["glassesDay"] = today
        self.settings["glasses"] = int(self.settings.get("glasses") or 0) + n
        self.settings["glassesTotal"] = int(self.settings.get("glassesTotal") or 0) + n
        self.save_settings()
        self.refresh_panel()

    # ----- quiet hours / fullscreen -----

    def quiet_hours(self, now):
        if not self.settings.get("quietEnabled"):
            return False
        try:
            fh, fm = [int(v) for v in str(self.settings.get("quietFrom", "23:00")).split(":")]
            th, tm = [int(v) for v in str(self.settings.get("quietTo", "07:00")).split(":")]
            start = fh * 60 + fm
            end = th * 60 + tm
            cur = now.hour * 60 + now.minute
        except (ValueError, TypeError):
            return False
        if start <= end:
            return start <= cur < end
        return cur >= start or cur < end   # overnight range

    def screen_locked(self):
        for dest, path in (("org.cinnamon.ScreenSaver", "/org/cinnamon/ScreenSaver"),
                           ("org.gnome.ScreenSaver", "/org/gnome/ScreenSaver"),
                           ("org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver")):
            try:
                reply = Gio.DBus.session.call_sync(
                    dest, path, dest, "GetActive", None,
                    GLib.VariantType.new("(b)"), Gio.DBusCallFlags.NONE, 250, None)
                value = reply.unpack()
                if isinstance(value, tuple):
                    value = value[0]
                if value:
                    return True
            except Exception:
                continue
        return False

    def fullscreen_active(self):
        if not self.xprop:
            return False
        try:
            root = subprocess.run([self.xprop, "-root", "_NET_ACTIVE_WINDOW"],
                                  capture_output=True, text=True, timeout=1).stdout
            match = re.search(r"(0x[0-9a-fA-F]+)", root.replace(",", " "))
            if not match or match.group(1).lower() in ("0x0", "0x00"):
                return False
            state = subprocess.run([self.xprop, "-id", match.group(1), "_NET_WM_STATE"],
                                   capture_output=True, text=True, timeout=1).stdout
            return "_NET_WM_STATE_FULLSCREEN" in state
        except (OSError, subprocess.SubprocessError):
            return False

    def notifications_blocked(self):
        return self.screen_locked() or self.fullscreen_active()

    # ----- bundled cat / meow -----

    def get_cat(self):
        """The one bundled cat cutout, decoded once and shared by all popups."""
        if self.cat_pixbuf is None:
            for path in (CAT_IMAGE, CAT_FALLBACK):
                if not path.is_file():
                    continue
                try:
                    # decode only as large as the popup needs (the bundled
                    # cutout is 650x685) instead of pinning the full image
                    self.cat_pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                        str(path), 400, 420, True)
                    break
                except (GLib.Error, OSError) as exc:
                    log("cat image %s failed: %s" % (path.name, exc))
        return self.cat_pixbuf

    def play_meow(self):
        path = str(MEOW_FILE) if MEOW_FILE.is_file() else ""
        if not path:
            Gdk.beep()
            return
        if self.audio_player is None:
            for candidate in ("paplay", "aplay", "canberra-gtk-play",
                              "ffplay", "pw-play"):
                if shutil.which(candidate):
                    self.audio_player = candidate
                    break
            else:
                self.audio_player = ""
        if not self.audio_player:
            Gdk.beep()
            return
        commands = {
            "paplay": [path],
            "pw-play": [path],
            "aplay": ["-q", path],
            "canberra-gtk-play": ["-f", path],
            "ffplay": ["-nodisp", "-autoexit", "-loglevel", "quiet", path],
        }
        try:
            subprocess.Popen([self.audio_player] + commands[self.audio_player],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        except OSError:
            Gdk.beep()

    def notify(self, title, body):
        if self.notify_send:
            cmd = [self.notify_send, "-a", "Cat Reminders", "-t", "4000"]
            if CAT_IMAGE.is_file():
                cmd += ["-i", str(CAT_IMAGE)]
            cmd += [title, body]
            try:
                subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
                return
            except OSError:
                pass
        Gdk.beep()

    def make_tray_icon(self):
        """Write a small square PNG for the status icon; return its path or None."""
        try:
            cat = self.get_cat()
            if cat is None:
                return None
            pb = square_icon(cat, 64)
            CACHE_DIR.mkdir(parents=True, exist_ok=True)
            pb.savev(str(ICON_FILE), "png", [], [])
            return ICON_FILE
        except (GLib.Error, OSError) as exc:
            log("tray icon failed: %s" % exc)
            return None
    # ----- lifecycle -----

    def start(self):
        self.load_reminders()
        self.load_settings()
        log("=== %s launch ===" % datetime.now().strftime("%H:%M:%S"))
        log("reminders loaded: %d" % len(self.reminders))
        try:
            settings = Gtk.Settings.get_default()
            family = Pango.FontDescription(settings.props.gtk_font_name).get_family()
            self.font_family = family or "Sans"
        except Exception:
            self.font_family = "Sans"
        # the panel is built only when someone opens it: a hidden Gtk window
        # with a TreeView would otherwise sit in RAM for the whole session
        self.build_tray()
        self.startup_timer = GLib.timeout_add(1500, self._first_check)
        self.check_timer = GLib.timeout_add_seconds(15, self._check_tick)
        GLib.timeout_add_seconds(20, self._startup_notification)
        trim_heap()  # release scratch pages from startup image/icon work

    def _first_check(self):
        self.check_reminders()
        return False

    def _check_tick(self):
        self.check_reminders()
        return True

    def _startup_notification(self):
        if self.tray is not None or self.status_icon is not None:
            self.notify("Cat Reminders",
                        "The cat lives next to your clock. Click it to open the "
                        "reminder panel or to snooze it.")
        return False

    # ----- popups -----

    def show_popup(self, message, rem=None):
        self.popup_queue.append((message, rem))
        self._start_next_popup()

    def _start_next_popup(self):
        if self.popup_active or not self.popup_queue:
            return False
        message, rem = self.popup_queue.pop(0)
        self.popup_active = True
        try:
            self.popup = CatPopup(self, message, rem)
        except Exception as exc:
            log("popup failed: %s" % exc)
            self.popup = None
            self.popup_active = False
            if self.popup_queue:
                GLib.timeout_add_seconds(5, self._start_next_popup)
            return False
        self.play_meow()
        return False

    def popup_done(self):
        self.popup_active = False
        self.popup = None
        if self.popup_queue:
            GLib.idle_add(self._start_next_popup)

    # ----- reminder engine -----

    def snooze(self, rem, minutes=10):
        if rem is None:
            return False
        now = datetime.now()
        if rem_type(rem) == "once":
            rem["FireAt"] = iso_now(now + timedelta(minutes=minutes))
            if rem not in self.reminders:
                self.reminders.append(rem)
        else:
            try:
                interval = max(1, int(rem.get("IntervalMinutes") or 60))
            except (ValueError, TypeError):
                interval = 60
            duration = min(minutes, interval)
            # next fire in `duration` minutes
            rem["LastShown"] = iso_now(now - timedelta(minutes=interval - duration))
        self.save_reminders()
        self.refresh_panel()
        return True

    def check_reminders(self):
        # never nest popups: reminders due while one is open fire on the next tick
        if self.popup_active:
            return
        now = datetime.now()
        if self.quiet_until and now < self.quiet_until:
            return
        if self.quiet_hours(now):
            return
        if self.notifications_blocked():
            return
        changed = False
        keep = []
        for rem in self.reminders:
            if rem_type(rem) == "once":
                fire_at = parse_dt(rem.get("FireAt"))
                if fire_at is not None and now >= fire_at:
                    changed = True          # dropped, not kept
                    self.show_popup(rem.get("Message") or "Drink some water!", rem)
                else:
                    keep.append(rem)
            else:
                last = parse_dt(rem.get("LastShown"))
                try:
                    interval = max(1, int(rem.get("IntervalMinutes") or 60))
                except (ValueError, TypeError):
                    interval = 60
                if last is None or (now - last).total_seconds() / 60.0 >= interval:
                    rem["LastShown"] = iso_now(now)
                    changed = True
                    self.show_popup(rem.get("Message") or "Drink some water!", rem)
                keep.append(rem)
        self.reminders = keep
        if changed:
            self.save_reminders()
        self.refresh_panel()

    # ----- tray -----

    def build_tray(self):
        menu = Gtk.Menu()
        item = Gtk.MenuItem(label="Open reminder panel")
        item.connect("activate", lambda *_: self.show_panel())
        menu.append(item)
        item = Gtk.MenuItem(label="Show the cat now")
        item.connect("activate", lambda *_: self.show_popup(
            "Miau! Right meow? Anything you added will look like this."))
        menu.append(item)

        self.tray_quiet_item = Gtk.CheckMenuItem()
        self.tray_quiet_item.set_active(bool(self.settings.get("quietEnabled")))
        self._update_quiet_label()
        self.tray_quiet_item.connect("toggled", self._toggle_quiet)
        menu.append(self.tray_quiet_item)

        menu.append(Gtk.SeparatorMenuItem())
        item = Gtk.MenuItem(label="Exit (fire the cat)")
        item.connect("activate", lambda *_: self.quit())
        menu.append(item)
        menu.show_all()
        self.tray_menu = menu

        icon_path = self.make_tray_icon()
        self.icon_path = icon_path
        if XApp is not None:
            try:
                self.tray = XApp.StatusIcon()
                self.tray.set_name("cat-reminders")
                self.tray.set_tooltip_text("Cat Reminders - on duty")
                if icon_path:
                    self.tray.set_icon_name(str(icon_path))
                else:
                    self.tray.set_icon_name("applications-system")
                self.tray.set_primary_menu(menu)
                self.tray.set_secondary_menu(menu)
                self.tray.connect("activate", lambda *_: self.show_panel())
                self.tray.set_visible(True)
                log("tray icon created (XApp)")
                return
            except Exception as exc:
                log("XApp status icon failed: %s" % exc)
                self.tray = None

        if load_appindicator() is not None:
            try:
                indicator = AppIndicator.Indicator.new(
                    "cat-reminders",
                    str(icon_path) if icon_path else "applications-system",
                    AppIndicator.IndicatorCategory.APPLICATION_STATUS)
                indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
                indicator.set_title("Cat Reminders")
                if hasattr(indicator, "set_icon_full") and icon_path:
                    indicator.set_icon_full(str(icon_path), "Cat Reminders")
                indicator.set_menu(menu)
                self.tray = indicator
                log("tray icon created (appindicator)")
                return
            except Exception as exc:
                log("appindicator failed: %s" % exc)
                self.tray = None

        # last resort: legacy XEmbed tray icon
        try:
            pixbuf = GdkPixbuf.Pixbuf.new_from_file(str(icon_path)) if icon_path else None
            status = Gtk.StatusIcon.new_from_pixbuf(pixbuf) if pixbuf else \
                Gtk.StatusIcon.new_from_icon_name("applications-system")
            status.set_tooltip_text("Cat Reminders - on duty")
            status.connect("activate", lambda *_: self.show_panel())
            status.connect("popup-menu", self._status_popup)
            status.set_visible(True)
            self.status_icon = status
            log("tray icon created (Gtk.StatusIcon)")
        except Exception as exc:
            log("no tray icon available: %s" % exc)

    def _status_popup(self, icon, button, activate_time):
        try:
            self.tray_menu.popup(None, None, Gtk.StatusIcon.position_menu,
                                 icon, button, activate_time)
        except Exception:
            pass

    def _update_quiet_label(self):
        self.tray_quiet_item.set_label(
            "Quiet hours (%s-%s): %s" % (
                self.settings.get("quietFrom", "23:00"),
                self.settings.get("quietTo", "07:00"),
                "ON" if self.settings.get("quietEnabled") else "OFF"))

    def _toggle_quiet(self, item):
        self.settings["quietEnabled"] = bool(item.get_active())
        self.save_settings()
        self._update_quiet_label()
        if self.settings["quietEnabled"]:
            self.notify("Cat Reminders",
                        "Quiet from %s to %s. The cat naps (and so should you)."
                        % (self.settings.get("quietFrom"), self.settings.get("quietTo")))
        else:
            self.notify("Cat Reminders", "Quiet hours off. The cat resumes hydrating you.")

    # ----- panel -----

    def build_panel(self):
        self.panel = Panel(self)

    def show_panel(self):
        if self.panel is None:
            self.build_panel()
        self.refresh_panel()
        self.panel.show_all()
        self.panel.present()

    def refresh_panel(self):
        if self.panel is not None:
            self.panel.refresh()

    # ----- shutdown -----

    def quit(self):
        log("quitting")
        try:
            if self.tray is not None:
                if XApp is not None and isinstance(self.tray, XApp.StatusIcon):
                    self.tray.set_visible(False)
                elif AppIndicator is not None:
                    self.tray.set_status(AppIndicator.IndicatorStatus.PASSIVE)
                self.tray = None
        except Exception:
            pass
        if self.status_icon is not None:
            try:
                self.status_icon.set_visible(False)
            except Exception:
                pass
            self.status_icon = None
        GLib.idle_add(self.app.quit)
# ---------- the popup (floating cat + speech bubble, no window box) ----------

class CatPopup:
    W, H = 420, 575

    def __init__(self, core, message, rem=None):
        self.core = core
        self.message = message
        self.rem = rem
        self.flavor = random.choice(FLAVORS)
        self.counting = False
        self.countdown = 0
        self.ack = None
        self.closed = False
        self.quieted = False
        self.last_click = 0.0

        self.hover_timer = 0
        self.ack_timer = 0
        self.safety_timer = 0
        self.single_timer = 0

        self.surface = None
        self.factor = 1
        self.input_region = None
        self.cat = core.get_cat()
        self.scaled_cat = None
        self.scaled_for = 0

        self.win = Gtk.Window()
        self.win.set_app_paintable(True)
        self.win.set_decorated(False)
        self.win.set_resizable(False)
        self.win.set_skip_taskbar_hint(True)
        self.win.set_skip_pager_hint(True)
        self.win.set_keep_above(True)
        self.win.set_accept_focus(False)
        self.win.set_focus_on_map(False)
        self.win.set_title("Your cat says...")
        self.win.set_type_hint(Gdk.WindowTypeHint.NOTIFICATION)
        self.win.set_default_size(self.W, self.H)
        self.win.set_size_request(self.W, self.H)

        screen = self.win.get_screen()
        visual = screen.get_rgba_visual()
        self.composited = bool(screen.is_composited() and visual is not None)
        if self.composited:
            self.win.set_visual(visual)

        self.win.add_events(Gdk.EventMask.BUTTON_PRESS_MASK |
                            Gdk.EventMask.ENTER_NOTIFY_MASK |
                            Gdk.EventMask.LEAVE_NOTIFY_MASK)
        self.win.connect("draw", self._on_draw)
        self.win.connect("button-press-event", self._on_press)
        self.win.connect("enter-notify-event", self._on_enter)
        self.win.connect("destroy", self._on_destroy)

        display = Gdk.Display.get_default()
        monitor = display.get_primary_monitor() if display else None
        if monitor is None and display is not None:
            monitor = display.get_monitor(0)
        if monitor is not None:
            area = monitor.get_workarea()
            self.win.move(area.x + area.width - self.W - 10,
                          area.y + area.height - self.H - 10)

        self.win.show_all()
        self.safety_timer = GLib.timeout_add_seconds(AUTO_CLOSE_SECONDS, self._safety)

    # ----- drawing -----

    def _on_draw(self, widget, cr):
        factor = widget.get_scale_factor()
        if self.surface is None or factor != self.factor:
            self.factor = factor
            self.surface = cairo.ImageSurface(cairo.FORMAT_ARGB32,
                                              int(self.W * factor),
                                              int(self.H * factor))
            self.scaled_cat = None
            self.input_region = None
        self._render()
        cr.save()
        cr.scale(1.0 / factor, 1.0 / factor)
        cr.set_source_surface(self.surface, 0, 0)
        cr.paint()
        cr.restore()
        self._apply_input_shape()
        return False

    def _apply_input_shape(self):
        # transparent areas are truly click-through, like the Windows version
        if not self.composited:
            return
        try:
            gdk_window = self.win.get_window()
            if gdk_window is None:
                return
            if self.input_region is None:
                self.input_region = logical_region_from_surface(
                    self.surface, self.factor)
            gdk_window.input_shape_combine_region(self.input_region, 0, 0)
        except Exception:
            pass

    def _render(self):
        f = self.factor
        cr = cairo.Context(self.surface)
        cr.set_operator(cairo.OPERATOR_CLEAR)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)
        cr.scale(f, f)

        if not self.composited:
            # no compositor: keep the bubble readable on a soft backing panel
            cr.set_source_rgb(0.97, 0.96, 0.99)
            cr.paint()

        # speech bubble (Material You, soft lavender)
        bubble = (232 / 255, 222 / 255, 248 / 255)
        edge = (199 / 255, 183 / 255, 236 / 255)
        round_rect(cr, 14, 6, 392, 96, 18)
        cr.set_source_rgb(*bubble)
        cr.fill_preserve()
        cr.set_source_rgb(*edge)
        cr.set_line_width(1.5)
        cr.stroke()

        # tail pointing at the cat's head
        cr.move_to(170, 100)
        cr.line_to(254, 100)
        cr.line_to(215, 146)
        cr.close_path()
        cr.set_source_rgb(*bubble)
        cr.fill()

        self._draw_text(cr, self.message, 32, 16, 356, 58, 11, True,
                        (74 / 255, 68 / 255, 88 / 255))

        hint = self.flavor
        if self.ack:
            hint = self.ack
        elif self.counting:
            hint = "closing in %ss..." % self.countdown
        self._draw_text(cr, hint, 32, 80, 356, 18, 8, False,
                        (125 / 255, 115 / 255, 140 / 255))

        if self.cat is not None:
            self._draw_cat(cr, f)
        else:
            self._draw_ascii_cat(cr)

    def _draw_cat(self, cr, factor):
        pw, ph = self.cat.get_width(), self.cat.get_height()
        if not pw or not ph:
            return
        box_w, box_h = 400, 420
        ratio = min(box_w / float(pw), box_h / float(ph))
        dw = max(1, int(pw * ratio))
        dh = max(1, int(ph * ratio))
        if self.scaled_cat is None or self.scaled_for != (dw, dh, factor):
            self.scaled_cat = self.cat.scale_simple(
                max(1, int(dw * factor)), max(1, int(dh * factor)),
                GdkPixbuf.InterpType.BILINEAR)
            self.scaled_for = (dw, dh, factor)
        cx = 10 + (box_w - dw) / 2.0
        cy = 140 + (box_h - dh) / 2.0
        cr.save()
        cr.translate(cx, cy)
        Gdk.cairo_set_source_pixbuf(cr, self.scaled_cat, 0, 0)
        cr.paint()
        cr.restore()

    def _draw_ascii_cat(self, cr):
        layout = PangoCairo.create_layout(cr)
        desc = Pango.FontDescription("monospace 26")
        layout.set_font_description(desc)
        layout.set_text("   /\\_/\\\n  ( o.o )\n   > ^ <", -1)
        layout.set_alignment(Pango.Alignment.CENTER)
        layout.set_width(200 * Pango.SCALE)
        lw, lh = layout.get_pixel_size()
        cr.set_source_rgb(74 / 255, 68 / 255, 88 / 255)
        cr.move_to(110, 210 + max(0, (160 - lh) / 2))
        PangoCairo.show_layout(cr, layout)

    def _draw_text(self, cr, text, x, y, w, h, size, bold, color):
        layout = PangoCairo.create_layout(cr)
        desc = Pango.FontDescription()
        desc.set_family(self.core.font_family)
        desc.set_size(int(size * Pango.SCALE))
        if bold:
            desc.set_weight(Pango.Weight.BOLD)
        layout.set_font_description(desc)
        layout.set_text(text, -1)
        layout.set_width(int(w * Pango.SCALE))
        layout.set_alignment(Pango.Alignment.CENTER)
        layout.set_wrap(Pango.WrapMode.WORD_CHAR)
        layout.set_ellipsize(Pango.EllipsizeMode.END)
        layout.set_height(int(h * Pango.SCALE))
        lw, lh = layout.get_pixel_size()
        cr.set_source_rgb(*color)
        cr.move_to(x, y + max(0, (h - lh) / 2.0))
        PangoCairo.show_layout(cr, layout)

    # ----- dismissal -----

    def _drop(self, name):
        timer = getattr(self, name, 0)
        if timer:
            try:
                GLib.source_remove(timer)
            except Exception:
                pass
            setattr(self, name, 0)

    def _on_enter(self, widget, event):
        # first touch starts the countdown; re-touching does NOT reset it
        if self.closed or self.counting or self.ack:
            return False
        self.counting = True
        self.countdown = 10
        self.hover_timer = GLib.timeout_add(1000, self._hover_tick)
        self.win.queue_draw()
        return False

    def _hover_tick(self):
        if self.closed:
            return False
        self.countdown -= 1
        if self.countdown <= 0:
            self.close()
            return False
        self.win.queue_draw()
        return True

    def _on_press(self, widget, event):
        if self.closed:
            return False
        if event.type == Gdk.EventType._2BUTTON_PRESS:
            if event.button == 1:
                self._quiet()
            return True
        if event.type != Gdk.EventType.BUTTON_PRESS:
            return False
        if event.button == 1:
            now = time.monotonic()
            if now - self.last_click <= 0.40:
                self.last_click = 0.0
                self._quiet()
            else:
                self.last_click = now
                self.single_timer = GLib.timeout_add(400, self._single_click)
            return True
        if event.button == 3:
            self._snooze()
            return True
        return False

    def _single_click(self):
        self.single_timer = 0
        if self.closed or not self.last_click:
            return False
        if time.monotonic() - self.last_click >= 0.35:
            self.last_click = 0.0
            # clicking the cat to dismiss it = the water was actually drunk
            if self.rem is not None:
                self.core.add_glass(1)
            self.close()
        return False

    def _snooze(self):
        if self.rem is not None:
            self.core.snooze(self.rem, 10)
            self.ack = "Snoozed for 10 minutes, meow."
        else:
            self.ack = "Nothing to snooze - just vibes."
        self.counting = False
        self._drop("hover_timer")
        self.win.queue_draw()
        self.ack_timer = GLib.timeout_add(1800, self._ack_done)

    def _ack_done(self):
        self.ack_timer = 0
        self.close()
        return False

    def _quiet(self):
        # double-click = quiet mode for one hour
        if self.quieted or self.closed:
            return
        self.quieted = True
        self.core.quiet_until = datetime.now() + timedelta(hours=1)
        self.core.notify("Cat Reminders",
                         "Quiet for 1 hour. Zzz. (tray icon > Open reminder panel)")
        self.close()

    def _safety(self):
        self.safety_timer = 0
        self.close()
        return False

    def close(self):
        if self.closed:
            return
        self.closed = True
        for name in ("hover_timer", "ack_timer", "safety_timer", "single_timer"):
            self._drop(name)
        try:
            self.win.destroy()
        except Exception:
            pass

    def _on_destroy(self, widget):
        for name in ("hover_timer", "ack_timer", "safety_timer", "single_timer"):
            self._drop(name)
        # drop the big buffers now instead of waiting for garbage collection
        self.cat = None
        self.scaled_cat = None
        self.surface = None
        self.input_region = None
        self.win = None
        try:
            self.core.popup_done()
        except Exception:
            pass
        trim_heap()

# ---------- control panel ----------

class Panel(Gtk.Window):
    def __init__(self, core):
        super().__init__(title="Cat Reminders")
        self.core = core
        self.set_default_size(478, 600)
        self.set_resizable(False)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_skip_taskbar_hint(True)
        self.connect("delete-event", self._on_delete)
        try:
            if CAT_IMAGE.is_file():
                self.set_icon_from_file(str(CAT_IMAGE))
        except GLib.Error:
            pass

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        outer.set_margin_top(12)
        outer.set_margin_bottom(12)
        outer.set_margin_start(12)
        outer.set_margin_end(12)
        self.add(outer)

        # header: title + water tally
        header = Gtk.Box(spacing=6)
        header.pack_start(Gtk.Label(label="Active reminders:", xalign=0), False, False, 0)
        self.tally = Gtk.Label(xalign=1)
        self.tally.set_hexpand(True)
        header.pack_start(self.tally, True, True, 0)
        outer.pack_start(header, False, False, 0)

        # reminder list
        self.store = Gtk.ListStore(str, str, str)
        self.view = Gtk.TreeView(model=self.store)
        for index, (title, width) in enumerate((("Message", 226),
                                                ("Pattern", 104),
                                                ("Next", 108))):
            renderer = Gtk.CellRendererText()
            renderer.set_property("ellipsize", Pango.EllipsizeMode.END)
            column = Gtk.TreeViewColumn(title, renderer, text=index)
            column.set_fixed_width(width)
            if index == 0:
                column.set_expand(True)
            self.view.append_column(column)
        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroller.set_size_request(-1, 128)
        scroller.add(self.view)
        outer.pack_start(scroller, False, False, 0)

        # add reminder
        frame = Gtk.Frame(label="Add a reminder")
        inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        inner.set_margin_top(10)
        inner.set_margin_bottom(10)
        inner.set_margin_start(12)
        inner.set_margin_end(12)
        frame.add(inner)
        outer.pack_start(frame, False, False, 0)

        inner.pack_start(Gtk.Label(label="What should the cat say?", xalign=0),
                         False, False, 0)
        self.text = Gtk.TextView()
        self.text.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.text.set_border_width(4)
        text_scroller = Gtk.ScrolledWindow()
        text_scroller.set_shadow_type(Gtk.ShadowType.IN)
        text_scroller.set_size_request(-1, 46)
        text_scroller.add(self.text)
        inner.pack_start(text_scroller, False, False, 0)

        self.rb_repeat = Gtk.RadioButton.new_with_label_from_widget(None, "Repeat: every")
        self.rb_once_in = Gtk.RadioButton.new_with_label_from_widget(
            self.rb_repeat, "One time: in")
        self.rb_once_at = Gtk.RadioButton.new_with_label_from_widget(
            self.rb_repeat, "One time: at")

        row = Gtk.Box(spacing=8)
        row.pack_start(self.rb_repeat, False, False, 0)
        self.spin_repeat = Gtk.SpinButton.new_with_range(1, 100000, 1)
        self.spin_repeat.set_value(60)
        self.spin_repeat.set_size_request(72, -1)
        row.pack_start(self.spin_repeat, False, False, 0)
        row.pack_start(Gtk.Label(label="minutes", xalign=0), False, False, 0)
        inner.pack_start(row, False, False, 0)

        row = Gtk.Box(spacing=8)
        row.pack_start(self.rb_once_in, False, False, 0)
        self.spin_once = Gtk.SpinButton.new_with_range(1, 100000, 1)
        self.spin_once.set_value(30)
        self.spin_once.set_size_request(72, -1)
        row.pack_start(self.spin_once, False, False, 0)
        row.pack_start(Gtk.Label(label="minutes from now", xalign=0), False, False, 0)
        inner.pack_start(row, False, False, 0)

        row = Gtk.Box(spacing=8)
        row.pack_start(self.rb_once_at, False, False, 0)
        soon = datetime.now() + timedelta(hours=1)
        self.spin_hour = Gtk.SpinButton.new_with_range(0, 23, 1)
        self.spin_hour.set_wrap(True)
        self.spin_hour.set_value(soon.hour)
        self.spin_hour.set_size_request(56, -1)
        self.spin_minute = Gtk.SpinButton.new_with_range(0, 59, 1)
        self.spin_minute.set_wrap(True)
        self.spin_minute.set_value(soon.minute)
        self.spin_minute.set_size_request(56, -1)
        row.pack_start(self.spin_hour, False, False, 0)
        row.pack_start(Gtk.Label(label=":"), False, False, 0)
        row.pack_start(self.spin_minute, False, False, 0)
        inner.pack_start(row, False, False, 0)
        note = Gtk.Label(label="(tomorrow if that time already passed)", xalign=0)
        note.get_style_context().add_class("dim-label")
        inner.pack_start(note, False, False, 0)

        actions = Gtk.Box(spacing=8)
        add = Gtk.Button(label="Add reminder")
        add.get_style_context().add_class("suggested-action")
        add.connect("clicked", self._on_add)
        actions.pack_start(add, False, False, 0)
        preview = Gtk.Button(label="Show the cat now")
        preview.connect("clicked", self._on_preview)
        actions.pack_start(preview, False, False, 0)
        inner.pack_start(actions, False, False, 0)

        # bottom actions
        bottom = Gtk.Box(spacing=8)
        glass = Gtk.Button(label="I drank a glass")
        glass.get_style_context().add_class("suggested-action")
        glass.connect("clicked", lambda *_: self.core.add_glass(1))
        delete = Gtk.Button(label="Delete selected")
        delete.connect("clicked", self._on_delete_selected)
        bottom.pack_start(glass, False, False, 0)
        bottom.pack_end(delete, False, False, 0)
        outer.pack_start(bottom, False, False, 0)

        hint = Gtk.Label(
            label="One-time reminders disappear when they fire. Closing this window "
                  "keeps the cat in the tray (click the tray cat to reopen). Quiet hours "
                  "lives in the tray menu. This build uses the bundled cat and meow. "
                  "Clicking the cat counts a glass.")
        hint.set_line_wrap(True)
        hint.set_xalign(0)
        hint.set_max_width_chars(60)
        hint.get_style_context().add_class("dim-label")
        outer.pack_start(hint, False, False, 0)

        for button in (self.rb_repeat, self.rb_once_in, self.rb_once_at):
            button.connect("toggled", self._sync_modes)
        self._sync_modes()

    def _sync_modes(self, *_):
        self.spin_repeat.set_sensitive(self.rb_repeat.get_active())
        self.spin_once.set_sensitive(self.rb_once_in.get_active())
        self.spin_hour.set_sensitive(self.rb_once_at.get_active())
        self.spin_minute.set_sensitive(self.rb_once_at.get_active())

    def _on_add(self, *_):
        buffer = self.text.get_buffer()
        text = buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), True).strip()
        if not text:
            text = "Psst... time for your reminder!"
        now = datetime.now()
        if self.rb_repeat.get_active():
            rem = {"Type": "repeat", "Message": text,
                   "IntervalMinutes": int(self.spin_repeat.get_value()),
                   "LastShown": None, "FireAt": None}
        elif self.rb_once_in.get_active():
            fire = now + timedelta(minutes=int(self.spin_once.get_value()))
            rem = {"Type": "once", "Message": text, "IntervalMinutes": None,
                   "LastShown": None, "FireAt": iso_now(fire)}
        else:
            fire = now.replace(hour=int(self.spin_hour.get_value()),
                               minute=int(self.spin_minute.get_value()),
                               second=0, microsecond=0)
            if fire <= now:
                fire += timedelta(days=1)
            rem = {"Type": "once", "Message": text, "IntervalMinutes": None,
                   "LastShown": None, "FireAt": iso_now(fire)}
        self.core.reminders.append(rem)
        self.core.save_reminders()
        self.refresh()
        buffer.set_text("")

    def _on_preview(self, *_):
        self.core.show_popup("Miau! This is what a reminder looks like. Meow meow.")

    def _on_delete_selected(self, *_):
        model, tree_iter = self.view.get_selection().get_selected()
        if tree_iter is None:
            return
        index = model.get_path(tree_iter).get_indices()[0]
        if 0 <= index < len(self.core.reminders):
            del self.core.reminders[index]
            self.core.save_reminders()
            self.refresh()

    def _on_delete(self, *_):
        # free the widget tree; it is rebuilt on the next open
        self.core.panel = None
        self.destroy()
        trim_heap()
        return True

    def refresh(self):
        self.store.clear()
        now = datetime.now()
        for rem in self.core.reminders:
            if rem_type(rem) == "once":
                fire = parse_dt(rem.get("FireAt"))
                if fire is None:
                    next_text = "-"
                elif fire <= now:
                    next_text = "due now!"
                else:
                    next_text = fire.strftime("%H:%M")
                pattern = "one-time"
            else:
                last = parse_dt(rem.get("LastShown"))
                try:
                    interval = max(1, int(rem.get("IntervalMinutes") or 60))
                except (ValueError, TypeError):
                    interval = 60
                if last is None:
                    next_text = "on next check"
                else:
                    coming = last + timedelta(minutes=interval)
                    next_text = "due now!" if coming <= now else coming.strftime("%H:%M")
                pattern = "every %d min" % interval
            self.store.append([rem.get("Message") or "", pattern, next_text])

        glasses = int(self.core.settings.get("glasses") or 0)
        total = int(self.core.settings.get("glassesTotal") or 0)
        unit = "glass" if glasses == 1 else "glasses"
        self.tally.set_markup(
            '<span foreground="#6750A4">Water: %d %s today - total %d</span>'
            % (glasses, unit, total))
# ---------- app ----------

class CatApplication(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="io.github.catreminders.CatReminders",
                         flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.core = None
        self.activated = False
        self.show_panel_on_start = "--show-panel" in sys.argv

    def do_startup(self):
        Gtk.Application.do_startup(self)
        self.hold()   # the cat lives in the tray, not in a window
        GLib.set_application_name("Cat Reminders")
        self.core = CatCore(self)
        self.core.start()
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, self._on_signal)
            except Exception:
                pass

    def _on_signal(self):
        if self.core is not None:
            self.core.quit()
        return False

    def do_activate(self):
        # second launch just brings up the panel of the cat already on duty
        if self.activated or self.show_panel_on_start:
            self.core.show_panel()
        self.activated = True

    def do_shutdown(self):
        try:
            if self.core is not None:
                if self.core.tray is not None and XApp is not None and \
                        isinstance(self.core.tray, XApp.StatusIcon):
                    self.core.tray.set_visible(False)
                if self.core.status_icon is not None:
                    self.core.status_icon.set_visible(False)
        except Exception:
            pass
        Gtk.Application.do_shutdown(self)


def main():
    app = CatApplication()
    # only pass the program name: --show-panel is ours, not GLib's
    return app.run([sys.argv[0]])


if __name__ == "__main__":
    sys.exit(main())
