#!/usr/bin/env python3
"""Capture a screenshot from an X11 display using python-xlib.

Usage: python3 scripts/xlib_screenshot.py <display> <output.png>

Requires: python-xlib, pillow
Install: pip3 install python-xlib pillow
"""

import sys
import os

def capture(display: str, output: str) -> bool:
    try:
        from Xlib import X, display as Xdisplay
        from PIL import Image
    except ImportError as e:
        print(f"error: {e}", file=sys.stderr)
        print("Install: pip3 install python-xlib pillow", file=sys.stderr)
        return False

    try:
        dpy = Xdisplay.Display(display)
    except Exception as e:
        print(f"error: cannot open display {display}: {e}", file=sys.stderr)
        return False

    try:
        root = dpy.screen().root
        geom = root.get_geometry()
        width = geom.width
        height = geom.height

        # GetImage in ZPixmap format
        raw = root.get_image(0, 0, width, height, X.ZPixmap, 0xFFFFFFFF)
        data = raw.data

        # X11 ZPixmap is BGR byte order, PIL needs RGB
        img = Image.frombytes("RGB", (width, height), data, "raw", "BGRX")
        img.save(output)
        print(f"Screenshot saved: {output} ({width}x{height})", file=sys.stderr)
        return True
    except Exception as e:
        print(f"error capturing: {e}", file=sys.stderr)
        return False
    finally:
        dpy.close()


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: xlib_screenshot.py <display> <output.png>", file=sys.stderr)
        sys.exit(1)
    if capture(sys.argv[1], sys.argv[2]):
        sys.exit(0)
    sys.exit(1)
