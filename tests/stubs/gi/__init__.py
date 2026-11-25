"""Minimal stubs so cat-reminders.py can be imported without GTK installed."""


def require_version(*_args, **_kwargs):
    return None


class _Module:
    def __getattr__(self, name):
        return None
