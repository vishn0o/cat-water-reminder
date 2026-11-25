"""Checks the HiDPI input-shape conversion without a real GDK display."""

import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE / "stubs"))

spec = importlib.util.spec_from_file_location(
    "cat_reminders", ROOT / "cat-reminders.py")
cr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cr)


class Rect:
    def __init__(self, x=0, y=0, width=0, height=0):
        self.x, self.y, self.width, self.height = x, y, width, height

    def __repr__(self):
        return "Rect(%d,%d,%d,%d)" % (self.x, self.y, self.width, self.height)

    def __eq__(self, other):
        return (self.x, self.y, self.width, self.height) == (
            other.x, other.y, other.width, other.height)


class Region:
    def __init__(self, rects=None):
        self.rects = list(rects or [])

    def num_rectangles(self):
        return len(self.rects)

    def get_rectangle(self, index):
        return self.rects[index]

    def union(self, rect):
        self.rects.append(rect)


source = Region([Rect(6, 8, 10, 10), Rect(7, 7, 3, 3)])
cr.Gdk = SimpleNamespace(cairo_region_create_from_surface=lambda surface: source)
cr.cairo = SimpleNamespace(Region=Region, RectangleInt=Rect)

# 1x: the region is returned untouched
assert cr.logical_region_from_surface(None, 1) is source

# 2x device pixels -> logical window pixels
scaled = cr.logical_region_from_surface(None, 2)
assert scaled.rects == [Rect(3, 4, 5, 5), Rect(3, 3, 2, 2)], scaled.rects
assert all(r.width >= 1 and r.height >= 1 for r in scaled.rects)

print("test_region.py: OK")
