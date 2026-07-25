#!/usr/bin/env python3
"""SDF (Signed Distance Field) font atlas generator for Forge IDE.

Generates a single texture atlas containing all ASCII glyphs as SDF,
plus a JSON metadata file with glyph positions and metrics.

The GPU backend samples this atlas to render crisp text at any size
without per-glyph FreeType rendering.

Usage:
    python3 scripts/generate_sdf_atlas.py \
        --font packages/renderer/assets/fonts/DejaVuSansMono.ttf \
        --size 48 \
        --output-png packages/renderer/assets/sdf_atlas.png \
        --output-json packages/renderer/assets/sdf_atlas.json

Requires: Pillow (PIL), freetype-py
Install: pip3 install Pillow freetype-py
"""

import argparse
import json
import os
import sys
import math

def generate_sdf_atlas(font_path, font_size, atlas_size, padding, spread, output_png, output_json):
    try:
        import freetype
        from PIL import Image
    except ImportError as e:
        print(f"error: {e}", file=sys.stderr)
        print("Install: pip3 install Pillow freetype-py", file=sys.stderr)
        return False

    if not os.path.exists(font_path):
        print(f"error: font not found: {font_path}", file=sys.stderr)
        return False

    face = freetype.Face(font_path)
    face.set_pixel_sizes(0, font_size)

    # Shelf packing: place glyphs left-to-right, wrap to next row
    atlas = Image.new("L", (atlas_size, atlas_size), 0)
    glyphs = {}

    x = padding
    y = padding
    row_height = 0

    for cp in range(32, 127):  # ASCII printable
        char = chr(cp)
        face.load_char(char, freetype.FT_LOAD_RENDER)
        bitmap = face.glyph.bitmap
        bw = bitmap.width
        bh = bitmap.rows

        if bw == 0 or bh == 0:
            # Space or non-renderable — store metrics only
            glyphs[cp] = {
                "codepoint": cp,
                "x": 0, "y": 0, "width": 0, "height": 0,
                "advance": face.glyph.advance.x >> 6,
                "bearing_x": face.glyph.bitmap_left,
                "bearing_y": face.glyph.bitmap_top,
            }
            continue

        # Add padding around glyph for SDF spread
        cell_w = bw + 2 * spread
        cell_h = bh + 2 * spread

        # Wrap to next row if needed
        if x + cell_w > atlas_size - padding:
            x = padding
            y += row_height + padding
            row_height = 0

        if y + cell_h > atlas_size - padding:
            print(f"warning: atlas full at char {char} ({cp})", file=sys.stderr)
            break

        row_height = max(row_height, cell_h)

        # Render glyph bitmap into atlas at (x+spread, y+spread)
        glyph_img = Image.frombytes("L", (bw, bh), bytes(bitmap.buffer))
        atlas.paste(glyph_img, (x + spread, y + spread))

        # Compute SDF: for each pixel in cell, find distance to nearest edge
        # Simple approach: distance transform via brute force (slow but correct)
        # For production, use scipy.ndimage.distance_transform_edt or implement
        # Felzenszwalb's algorithm. For now, use a simplified 2-pass approach.
        sdf_values = compute_sdf_simple(atlas, x, y, cell_w, cell_h, spread)

        # Write SDF values into atlas
        for py in range(cell_h):
            for px in range(cell_w):
                atlas.putpixel((x + px, y + py), sdf_values[py * cell_w + px])

        glyphs[cp] = {
            "codepoint": cp,
            "x": x,
            "y": y,
            "width": cell_w,
            "height": cell_h,
            "advance": face.glyph.advance.x >> 6,
            "bearing_x": face.glyph.bitmap_left,
            "bearing_y": face.glyph.bitmap_top,
        }

        x += cell_w + padding

    # Save atlas
    atlas.save(output_png)
    print(f"Atlas saved: {output_png} ({atlas_size}x{atlas_size})", file=sys.stderr)

    # Save metadata
    metadata = {
        "font_path": font_path,
        "font_size": font_size,
        "atlas_width": atlas_size,
        "atlas_height": atlas_size,
        "padding": padding,
        "spread": spread,
        "glyph_count": len(glyphs),
        "glyphs": list(glyphs.values()),
    }
    with open(output_json, "w") as f:
        json.dump(metadata, f, indent=2)
    print(f"Metadata saved: {output_json} ({len(glyphs)} glyphs)", file=sys.stderr)

    return True


def compute_sdf_simple(atlas, x, y, w, h, spread):
    """Compute signed distance field for a cell in the atlas.
    Simplified: uses the original glyph bitmap to determine inside/outside,
    then computes distance to nearest edge pixel.
    For production, use a proper distance transform algorithm."""
    from PIL import Image

    # Extract the cell (without spread padding) to get original glyph
    # The glyph is at (x+spread, y+spread) with size (w-2*spread, h-2*spread)
    glyph_w = w - 2 * spread
    glyph_h = h - 2 * spread

    # Get original glyph pixels (binary: inside=1, outside=0)
    glyph_pixels = []
    for py in range(glyph_h):
        for px in range(glyph_w):
            val = atlas.getpixel((x + spread + px, y + spread + py))
            glyph_pixels.append(1 if val > 128 else 0)

    # For each pixel in the cell, compute distance to nearest edge
    sdf = []
    max_dist = float(spread)
    for py in range(h):
        for px in range(w):
            # Map to glyph coordinates
            gx = px - spread
            gy = py - spread

            # Find nearest inside/outside transition
            min_dist = max_dist
            for dy in range(-spread, spread + 1):
                for dx in range(-spread, spread + 1):
                    nx = gx + dx
                    ny = gy + dy
                    if nx < 0 or nx >= glyph_w or ny < 0 or ny >= glyph_h:
                        continue
                    idx = ny * glyph_w + nx
                    # Check if this pixel is an edge (different from center)
                    center_val = 1 if (0 <= gx < glyph_w and 0 <= gy < glyph_h and glyph_pixels[gy * glyph_w + gx] > 0) else 0
                    neighbor_val = glyph_pixels[idx]
                    if neighbor_val != center_val:
                        dist = math.sqrt(dx * dx + dy * dy)
                        if dist < min_dist:
                            min_dist = dist

            # Normalize: inside = positive, outside = negative
            if 0 <= gx < glyph_w and 0 <= gy < glyph_h and glyph_pixels[gy * glyph_w + gx] > 0:
                # Inside glyph: positive distance
                normalized = 128 + (min_dist / max_dist) * 127
            else:
                # Outside glyph: negative distance
                normalized = 128 - (min_dist / max_dist) * 127

            sdf.append(int(max(0, min(255, normalized))))

    return sdf


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate SDF font atlas")
    parser.add_argument("--font", default="packages/renderer/assets/fonts/DejaVuSansMono.ttf")
    parser.add_argument("--size", type=int, default=48)
    parser.add_argument("--atlas-size", type=int, default=1024)
    parser.add_argument("--padding", type=int, default=4)
    parser.add_argument("--spread", type=int, default=8)
    parser.add_argument("--output-png", default="packages/renderer/assets/sdf_atlas.png")
    parser.add_argument("--output-json", default="packages/renderer/assets/sdf_atlas.json")
    args = parser.parse_args()

    if generate_sdf_atlas(args.font, args.size, args.atlas_size, args.padding, args.spread, args.output_png, args.output_json):
        print("SDF atlas generation complete.")
        sys.exit(0)
    else:
        sys.exit(1)
