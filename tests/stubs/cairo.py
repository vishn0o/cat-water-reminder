"""Just enough cairo for cat-reminders.py to import during logic tests.

The real drawing code is not exercised; test_region.py injects its own
region objects to check the HiDPI conversion.
"""

FORMAT_ARGB32 = 0
OPERATOR_CLEAR = 0
OPERATOR_OVER = 1


class ImageSurface:
    def __init__(self, *args, **kwargs):
        pass


class Context:
    def __init__(self, *args, **kwargs):
        pass


class Region:
    pass


class RectangleInt:
    def __init__(self, x=0, y=0, width=0, height=0):
        self.x, self.y = x, y
        self.width, self.height = width, height
