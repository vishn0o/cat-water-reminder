# Tests

These are GTK-free logic tests. They import `cat-reminders.py` with the tiny
fake modules in `stubs/`, so they run on any machine with Python 3 — no PyGObject,
no display, no Linux required.

```bash
python3 tests/run_all.py
```

Covered: PowerShell timestamp parsing, quiet hours, JSON storage, snooze
behaviour, the HiDPI click-through region conversion, and the single bundled
cat asset. Real GTK rendering still has to be checked on a desktop session;
see `docs/TESTING.md`.
