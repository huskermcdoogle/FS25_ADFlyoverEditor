"""Generate a 512x512 DXT1 (1-bit alpha) icon atlas for the flyover editor toolbar.

No Pillow. Each glyph is rasterised as a 1-bit mask (stroke coverage thresholded), then packed as
DXT1 in ALPHA mode: colour0 <= colour1 selects the {c0, c1, mid, TRANSPARENT} palette, so every texel
is either near-white (index 0) or fully transparent (index 3). That gives crisp, full-resolution
glyphs with a transparent background - which flat opaque DXT1 (make_icon.py) cannot - and needs no
real compressor. Icons are white; the HUD tints them per button at render time.

4x4 grid, 128px cells. Cell order is ICON_ORDER below; the HUD computes each tool's UV rect from its
index there.
"""
import struct, sys, math

ATLAS = 512
GRID = 4
CELL = ATLAS // GRID  # 128

ICON_ORDER = [
    "select", "draw", "spline", "fieldloop",
    "parallel", "siding", "move", "smooth",
    "straighten", "divide", "convert", "merge",
    "name", "delete", "ground",
]


def bez(p0, pc, p1, n=10):
    out = []
    for i in range(n + 1):
        t = i / n
        mt = 1 - t
        x = mt * mt * p0[0] + 2 * mt * t * pc[0] + t * t * p1[0]
        y = mt * mt * p0[1] + 2 * mt * t * pc[1] + t * t * p1[1]
        out.append((x, y))
    return out


def sine(x0, x1, ymid, amp, n=14):
    out = []
    for i in range(n + 1):
        t = i / n
        x = x0 + (x1 - x0) * t
        y = ymid + amp * math.sin(t * 2 * math.pi)
        out.append((x, y))
    return out


# Each glyph: list of shapes in normalised cell space (0..1, y down).
#   ("poly", [pts], width)   connected strokes
#   ("dot",  x, y, r)        filled disc
#   ("ring", x, y, r, width) circle outline
W = 0.05
ICONS = {
    "select": [("poly", [(0.30, 0.18), (0.30, 0.76), (0.44, 0.62), (0.53, 0.82),
                          (0.61, 0.79), (0.52, 0.59), (0.66, 0.59), (0.30, 0.18)], 0.05)],
    "draw": [("dot", 0.32, 0.70, 0.065), ("dot", 0.68, 0.32, 0.065),
             ("poly", [(0.37, 0.65), (0.63, 0.37)], W)],
    "spline": [("poly", bez((0.20, 0.76), (0.50, 0.12), (0.80, 0.76)), W)],
    "fieldloop": [("ring", 0.5, 0.5, 0.28, 0.05)],
    "parallel": [("poly", [(0.22, 0.40), (0.78, 0.40)], W),
                 ("poly", [(0.22, 0.60), (0.78, 0.60)], W)],
    "siding": [("poly", [(0.22, 0.40), (0.78, 0.40)], W),
               ("poly", [(0.22, 0.60), (0.78, 0.60)], W),
               ("poly", [(0.26, 0.40), (0.32, 0.60)], 0.04),
               ("poly", [(0.74, 0.40), (0.68, 0.60)], 0.04)],
    "move": [("poly", [(0.5, 0.18), (0.5, 0.82)], 0.045),
             ("poly", [(0.18, 0.5), (0.82, 0.5)], 0.045),
             ("poly", [(0.42, 0.26), (0.5, 0.18), (0.58, 0.26)], 0.045),
             ("poly", [(0.42, 0.74), (0.5, 0.82), (0.58, 0.74)], 0.045),
             ("poly", [(0.26, 0.42), (0.18, 0.5), (0.26, 0.58)], 0.045),
             ("poly", [(0.74, 0.42), (0.82, 0.5), (0.74, 0.58)], 0.045)],
    "smooth": [("poly", sine(0.20, 0.80, 0.5, 0.18), W)],
    "straighten": [("poly", [(0.20, 0.72), (0.80, 0.30)], 0.06)],
    "divide": [("poly", [(0.20, 0.5), (0.80, 0.5)], W),
               ("poly", [(0.40, 0.40), (0.40, 0.60)], 0.045),
               ("poly", [(0.60, 0.40), (0.60, 0.60)], 0.045)],
    "convert": [("poly", [(0.28, 0.40), (0.72, 0.40)], 0.045),
                ("poly", [(0.66, 0.34), (0.72, 0.40), (0.66, 0.46)], 0.045),
                ("poly", [(0.72, 0.60), (0.28, 0.60)], 0.045),
                ("poly", [(0.34, 0.54), (0.28, 0.60), (0.34, 0.66)], 0.045)],
    "merge": [("poly", [(0.30, 0.20), (0.5, 0.5)], W),
              ("poly", [(0.70, 0.20), (0.5, 0.5)], W),
              ("poly", [(0.5, 0.5), (0.5, 0.80)], W)],
    "name": [("poly", [(0.30, 0.30), (0.72, 0.30), (0.72, 0.70), (0.30, 0.70),
                       (0.18, 0.50), (0.30, 0.30)], 0.05),
             ("ring", 0.37, 0.50, 0.035, 0.035)],
    "delete": [("poly", [(0.28, 0.34), (0.72, 0.34)], 0.05),
               ("poly", [(0.42, 0.34), (0.44, 0.27), (0.56, 0.27), (0.58, 0.34)], 0.04),
               ("poly", [(0.33, 0.34), (0.37, 0.76), (0.63, 0.76), (0.67, 0.34)], 0.05),
               ("poly", [(0.45, 0.42), (0.47, 0.70)], 0.035),
               ("poly", [(0.55, 0.42), (0.53, 0.70)], 0.035)],
    "ground": [("poly", [(0.20, 0.72), (0.80, 0.72)], 0.055),
               ("poly", [(0.5, 0.26), (0.5, 0.62)], 0.05),
               ("poly", [(0.42, 0.54), (0.5, 0.62), (0.58, 0.54)], 0.05)],
}


def seg_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    l2 = dx * dx + dy * dy
    if l2 == 0:
        return math.hypot(px - ax, py - ay)
    t = ((px - ax) * dx + (py - ay) * dy) / l2
    t = max(0.0, min(1.0, t))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def raster_icon(mask, ox, oy, shapes):
    def on(px, py):
        if 0 <= px < ATLAS and 0 <= py < ATLAS:
            mask[py][px] = True

    for shape in shapes:
        kind = shape[0]
        if kind == "poly":
            pts = [(ox + x * CELL, oy + y * CELL) for (x, y) in shape[1]]
            hw = shape[2] * CELL / 2.0
            for i in range(len(pts) - 1):
                ax, ay = pts[i]
                bx, by = pts[i + 1]
                x0 = int(min(ax, bx) - hw - 1); x1 = int(max(ax, bx) + hw + 1)
                y0 = int(min(ay, by) - hw - 1); y1 = int(max(ay, by) + hw + 1)
                for py in range(y0, y1 + 1):
                    for px in range(x0, x1 + 1):
                        if seg_dist(px + 0.5, py + 0.5, ax, ay, bx, by) <= hw:
                            on(px, py)
        elif kind == "dot":
            cx, cy, r = ox + shape[1] * CELL, oy + shape[2] * CELL, shape[3] * CELL
            for py in range(int(cy - r - 1), int(cy + r + 2)):
                for px in range(int(cx - r - 1), int(cx + r + 2)):
                    if math.hypot(px + 0.5 - cx, py + 0.5 - cy) <= r:
                        on(px, py)
        elif kind == "ring":
            cx, cy, r, w = ox + shape[1] * CELL, oy + shape[2] * CELL, shape[3] * CELL, shape[4] * CELL
            for py in range(int(cy - r - w - 1), int(cy + r + w + 2)):
                for px in range(int(cx - r - w - 1), int(cx + r + w + 2)):
                    if abs(math.hypot(px + 0.5 - cx, py + 0.5 - cy) - r) <= w:
                        on(px, py)


mask = [[False] * ATLAS for _ in range(ATLAS)]
for i, name in enumerate(ICON_ORDER):
    col, row = i % GRID, i // GRID
    raster_icon(mask, col * CELL, row * CELL, ICONS[name])

header = bytearray(128)
header[0:4] = b"DDS "
struct.pack_into("<I", header, 4, 124)
struct.pack_into("<I", header, 8, 0x00081007)          # CAPS|HEIGHT|WIDTH|PIXELFORMAT|LINEARSIZE
struct.pack_into("<I", header, 12, ATLAS)
struct.pack_into("<I", header, 16, ATLAS)
struct.pack_into("<I", header, 20, ATLAS * ATLAS // 2)
struct.pack_into("<I", header, 28, 1)
struct.pack_into("<I", header, 76, 32)
struct.pack_into("<I", header, 80, 0x4)                 # DDPF_FOURCC
header[84:88] = b"DXT1"
struct.pack_into("<I", header, 108, 0x1000)

body = bytearray()
for by in range(0, ATLAS, 4):
    for bx in range(0, ATLAS, 4):
        idx = 0
        for ty in range(4):
            for tx in range(4):
                val = 0 if mask[by + ty][bx + tx] else 3  # 0 = opaque white, 3 = transparent
                idx |= val << (2 * (ty * 4 + tx))
        # colour0 < colour1 -> DXT1 ALPHA mode; both near-white so index 0 is white.
        body += struct.pack("<HHI", 0xFFFE, 0xFFFF, idx)

out = sys.argv[1] if len(sys.argv) > 1 else "textures/tool_icons.dds"
with open(out, "wb") as f:
    f.write(header)
    f.write(body)
print("wrote %s (%d bytes, expected %d) - %d icons"
      % (out, 128 + len(body), 128 + ATLAS * ATLAS // 2, len(ICON_ORDER)))
