"""Run every GTK-free test in this folder: python3 tests/run_all.py"""

import runpy
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

failed = []
for path in sorted(HERE.glob("test_*.py")):
    try:
        runpy.run_path(str(path), run_name="__main__")
    except Exception as exc:
        failed.append((path.name, exc))
        print("FAIL %s: %s" % (path.name, exc))

if failed:
    sys.exit(1)
print("ALL TESTS PASSED")
