"""The Linux build uses only the bundled cat; no cats/meows folder scanning."""

import importlib.util
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE / "stubs"))

spec = importlib.util.spec_from_file_location(
    "cat_reminders", ROOT / "cat-reminders.py")
cr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cr)

tmp = Path(tempfile.mkdtemp(prefix="cat-default-test-"))
cut = tmp / "cat_cut.png"
cut.write_bytes(b"png")

cr.CAT_IMAGE = cut
cr.CAT_FALLBACK = tmp / "missing.png"
cr.GLib = SimpleNamespace(Error=OSError)
cr.log = lambda message: None

loaded = []


class FakePixbuf:
    pass


def fake_load(path, *_args):
    if not Path(path).is_file():
        raise OSError("missing")
    loaded.append(path)
    return FakePixbuf()


cr.GdkPixbuf = SimpleNamespace(Pixbuf=SimpleNamespace(
    new_from_file=fake_load, new_from_file_at_scale=fake_load))

core = cr.CatCore(None)
first = core.get_cat()
assert isinstance(first, FakePixbuf)
assert core.get_cat() is first          # decoded once, reused by every popup
assert len(loaded) == 1, loaded

# when neither bundled file exists, the ascii cat fallback is used
cr.CAT_IMAGE = tmp / "no-cat.png"
cr.CAT_FALLBACK = tmp / "no-cat-either.png"
assert cr.CatCore(None).get_cat() is None

print("test_default_cat.py: OK")
