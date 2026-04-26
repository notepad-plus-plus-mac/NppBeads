#!/usr/bin/env python3
"""
Generate the DMG installer background image for Beads.app.

Produces resources/dmg-background.png (and @2x / .tiff) with the same
Chrome-style vertical layout the Notepad++ macOS DMG uses: app icon
centered near the top, a lavender rounded-rectangle drop zone centered
below it, a chunky white download arrow inside the drop zone pointing
into the Applications folder, and the Applications folder centered in
the drop zone.

All coordinates are derived from APP_ICON_CENTER / APPS_ICON_CENTER /
ICON_SIZE so the Python render and the AppleScript icon positions in
tools/build-release.sh can never drift apart. The AppleScript MUST use
the APP_ICON_CENTER and APPS_ICON_CENTER values defined here verbatim.

The arrow is pure white with no shadow and no outline: it is visible
because it sits entirely inside the lavender panel, never on white
canvas.

This is a port of notepad-plus-plus-macos/tools/generate-dmg-background.py
with identical geometry — keeps the macOS port family of apps visually
coherent.
"""

import subprocess
from PIL import Image, ImageDraw
from pathlib import Path

# ── Canvas (logical points). Slightly smaller than the DMG window's content
#    area so Finder never shows a scrollbar. ───────────────────────────────
W, H = 600, 640

# ── Icon centers (content-area pixel coordinates).
#    These are the AppleScript positions too — mirror them in build-release.sh
ICON_SIZE = 128
APP_ICON_CENTER = (300, 130)
APPS_ICON_CENTER = (300, 474)

# ── Lavender drop-zone panel: large enough to hold the arrow above the
#    folder and the folder's label below it, with even margins. ─────────────
PANEL_TOP = 255
PANEL_BOTTOM = 600
PANEL_HALF_W = 190
PANEL_RADIUS = 24
PANEL_FILL = (220, 216, 240, 170)

PANEL_RECT = (
    APPS_ICON_CENTER[0] - PANEL_HALF_W,
    PANEL_TOP,
    APPS_ICON_CENTER[0] + PANEL_HALF_W,
    PANEL_BOTTOM,
)

# ── White down-arrow. Sits INSIDE the panel, between the panel top and the
#    Applications folder. White-on-lavender reads cleanly with no stroke or
#    shadow. Arrow tip stops a few points above the folder icon top edge. ──
ARROW_CENTER_X = APPS_ICON_CENTER[0]
ARROW_SHAFT_W = 52
ARROW_SHAFT_H = 62
ARROW_HEAD_W = 112
ARROW_HEAD_H = 58
ARROW_CORNER = 8
ARROW_GAP_TO_FOLDER = 14
ARROW_BOTTOM_Y = APPS_ICON_CENTER[1] - ICON_SIZE // 2 - ARROW_GAP_TO_FOLDER
ARROW_FILL = (255, 255, 255, 255)

SCALE = 2


def render(scale: int) -> Image.Image:
    w, h = W * scale, H * scale
    img = Image.new("RGBA", (w, h), (255, 255, 255, 255))
    draw = ImageDraw.Draw(img, "RGBA")

    def s(v: float) -> int:
        return int(round(v * scale))

    def sp(xy):
        return (s(xy[0]), s(xy[1]))

    def sbox(box):
        return (s(box[0]), s(box[1]), s(box[2]), s(box[3]))

    # Drop-zone panel.
    draw.rounded_rectangle(
        sbox(PANEL_RECT),
        radius=s(PANEL_RADIUS),
        fill=PANEL_FILL,
    )

    # Arrow polygon (shaft + head in one path so the shape has a single
    # clean silhouette — no seam between rectangle and triangle).
    sx = ARROW_CENTER_X
    shaft_half = ARROW_SHAFT_W / 2
    head_half = ARROW_HEAD_W / 2
    tip_y = ARROW_BOTTOM_Y
    shoulder_y = tip_y - ARROW_HEAD_H
    shaft_top_y = shoulder_y - ARROW_SHAFT_H

    # Rounded top: draw shaft as a rounded rectangle clipped at the shoulder
    # so the top edge is rounded while the bottom edge meets the head.
    shaft_box = (
        sx - shaft_half,
        shaft_top_y,
        sx + shaft_half,
        shoulder_y + ARROW_CORNER,  # extend below shoulder so the rounded
                                    # bottom corners are hidden by the head
    )
    draw.rounded_rectangle(sbox(shaft_box), radius=s(ARROW_CORNER), fill=ARROW_FILL)

    head_pts = [
        (sx - head_half, shoulder_y),
        (sx + head_half, shoulder_y),
        (sx, tip_y),
    ]
    draw.polygon([sp(p) for p in head_pts], fill=ARROW_FILL)

    return img


def main():
    repo = Path(__file__).resolve().parent.parent
    out_dir = repo / "resources"
    out_dir.mkdir(parents=True, exist_ok=True)

    hi = render(SCALE)
    std = hi.resize((W, H), Image.LANCZOS)

    std_path = out_dir / "dmg-background.png"
    hi_path = out_dir / "dmg-background@2x.png"
    tiff_path = out_dir / "dmg-background.tiff"

    std.save(std_path, "PNG")
    hi.save(hi_path, "PNG")

    print(f"wrote {std_path} ({W}x{H})")
    print(f"wrote {hi_path} ({W * SCALE}x{H * SCALE})")

    subprocess.run(
        ["tiffutil", "-cathidpicheck", str(std_path), str(hi_path), "-out", str(tiff_path)],
        check=True,
    )
    print(f"wrote {tiff_path} (multi-res HiDPI)")

    # Print the authoritative icon positions so you can paste them into
    # tools/build-release.sh if they ever drift out of sync.
    print(f"icon positions: app={APP_ICON_CENTER} apps={APPS_ICON_CENTER}")


if __name__ == "__main__":
    main()
