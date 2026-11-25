"""Fake PyGObject namespaces: enough attributes for import and logic tests."""


class _Module:
    def __getattr__(self, name):
        return None


class _Base:
    def __init__(self, *args, **kwargs):
        pass

    def __getattr__(self, name):
        return lambda *args, **kwargs: None


class Window(_Base):
    pass


class Application(_Base):
    def run(self, *_args):
        return 0


class _Gtk(_Module):
    Window = Window
    Application = Application
    WindowType = type("WindowType", (), {"TOPLEVEL": 0})
    WindowPosition = type("WindowPosition", (), {"CENTER": 0})
    PolicyType = type("PolicyType", (), {"AUTOMATIC": 0, "NEVER": 1})
    Orientation = type("Orientation", (), {"VERTICAL": 0, "HORIZONTAL": 1})
    ShadowType = type("ShadowType", (), {"IN": 0})
    WrapMode = type("WrapMode", (), {"WORD_CHAR": 0})
    SelectionMode = type("SelectionMode", (), {"SINGLE": 0})
    PositionType = type("PositionType", (), {"UP": 0})
    IconSize = type("IconSize", (), {"BUTTON": 0})


class _Pango:
    SCALE = 1024
    Alignment = type("Alignment", (), {"CENTER": 0})
    EllipsizeMode = type("EllipsizeMode", (), {"END": 0})
    WrapMode = type("WrapMode", (), {"WORD_CHAR": 0})
    Weight = type("Weight", (), {"BOLD": 1})


class _GdkEventType:
    BUTTON_PRESS = 4
    _2BUTTON_PRESS = 5


class _Gdk:
    EventType = _GdkEventType
    WindowTypeHint = type("WindowTypeHint", (), {"NOTIFICATION": 0})
    EventMask = type("EventMask", (), {
        "BUTTON_PRESS_MASK": 1, "ENTER_NOTIFY_MASK": 2, "LEAVE_NOTIFY_MASK": 4})


class _VariantType:
    def __new__(cls, *args, **kwargs):
        return cls()


class _GLib:
    PRIORITY_DEFAULT = 0
    VariantType = _VariantType


class _Gio:
    class ApplicationFlags:
        FLAGS_NONE = 0

    class DBusCallFlags:
        NONE = 0

    class DBus:
        session = None


Gtk = _Gtk()
Gdk = _Gdk()
GdkPixbuf = _Module()
Gio = _Gio()
GLib = _GLib()
Pango = _Pango()
PangoCairo = _Module()
XApp = None
