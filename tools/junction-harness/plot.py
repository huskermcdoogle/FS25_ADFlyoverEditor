# Render a dump_site.lua output as a two-panel PNG (before | after). Pure stdlib.
#   python plot.py site.txt out.png
import sys, zlib, struct, math

src, out = sys.argv[1], sys.argv[2]
W = H = 900
GAP = 20
img = bytearray([255]) * ((W * 2 + GAP) * H * 3)
FULLW = W * 2 + GAP

def px(x, y, col, panel):
    x = int(x) + panel * (W + GAP)
    y = int(y)
    if 0 <= x - panel * (W + GAP) < W and 0 <= y < H:
        i = (y * FULLW + x) * 3
        img[i:i + 3] = bytes(col)

def line(x0, y0, x1, y1, col, panel, thick=1):
    n = int(max(abs(x1 - x0), abs(y1 - y0))) + 1
    for k in range(n + 1):
        t = k / n
        x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
        for dx in range(-(thick // 2), thick // 2 + 1):
            for dy in range(-(thick // 2), thick // 2 + 1):
                px(x + dx, y + dy, col, panel)

def dot(x, y, r, col, panel):
    for dx in range(-r, r + 1):
        for dy in range(-r, r + 1):
            if dx * dx + dy * dy <= r * r:
                px(x + dx, y + dy, col, panel)

def ring(x, y, r, col, panel):
    for a in range(0, 360, 2):
        px(x + r * math.cos(math.radians(a)), y + r * math.sin(math.radians(a)), col, panel)

rows = [l.split() for l in open(src) if l.strip()]
view = [r for r in rows if r[0] == "VIEW"][0]
vx, vz, span = float(view[1]), float(view[2]), float(view[3])
scale = W / (2 * span)

def T(x, z):
    # x to the right (east), z DOWN the screen is north-up flipped: FS z+ is south, so screen y = z
    return (x - vx) * scale + W / 2, (z - vz) * scale + H / 2

# grid every 10 m
for panel in (0, 1):
    g = -span
    while g <= span:
        gx, gy = T(vx + g, vz + g)
        line(gx, 0, gx, H - 1, (235, 235, 235), panel)
        line(0, gy, W - 1, gy, (235, 235, 235), panel)
        g += 10

for r in rows:
    k = r[0]
    if k in ("BL", "AL"):
        panel = 0 if k == "BL" else 1
        x0, y0 = T(float(r[1]), float(r[2]))
        x1, y1 = T(float(r[3]), float(r[4]))
        col = (120, 120, 120) if r[5] == "1" else (60, 60, 200)
        line(x0, y0, x1, y1, col, panel)
        # arrow head for one-way
        if r[5] == "0":
            ang = math.atan2(y1 - y0, x1 - x0)
            mx, my = x0 + (x1 - x0) * 0.6, y0 + (y1 - y0) * 0.6
            for da in (2.6, -2.6):
                line(mx, my, mx + 6 * math.cos(ang + da), my + 6 * math.sin(ang + da), col, panel)
for r in rows:
    k = r[0]
    if k == "ROAD":
        x0, y0 = T(float(r[2]), float(r[3])); x1, y1 = T(float(r[4]), float(r[5]))
        col = [(0, 160, 0), (200, 120, 0), (160, 0, 160), (0, 150, 150)][(int(r[1]) - 1) % 4]
        for panel in (0, 1):
            line(x0, y0, x1, y1, col, panel)
    elif k == "BAND":
        x0, y0 = T(float(r[1]), float(r[2])); x1, y1 = T(float(r[3]), float(r[4]))
        for panel in (0, 1):
            line(x0, y0, x1, y1, (230, 200, 0), panel, 2)
for r in rows:
    k = r[0]
    if k in ("BN", "AN"):
        panel = 0 if k == "BN" else 1
        x, y = T(float(r[2]), float(r[3]))
        laid = int(r[1]) >= 7000
        dot(x, y, 3, (200, 0, 120) if laid else (0, 0, 0), panel)
    elif k == "DOOMED":
        x, y = T(float(r[1]), float(r[2])); ring(x, y, 6, (255, 0, 0), 0)
    elif k == "SWEPT":
        x, y = T(float(r[1]), float(r[2])); ring(x, y, 8, (255, 120, 0), 0)
    elif k == "END":
        x, y = T(float(r[1]), float(r[2]))
        for panel in (0, 1):
            ring(x, y, 7, (0, 180, 0), panel); ring(x, y, 8, (0, 180, 0), panel)
    elif k == "CLICK":
        x, y = T(float(r[1]), float(r[2])); ring(x, y, float(r[3]) * scale, (150, 150, 255), 0)
    elif k == "LOCKED":
        x, y = T(float(r[1]), float(r[2]))
        for panel in (0, 1):
            line(x - 8, y - 8, x + 8, y + 8, (255, 0, 0), panel, 2); line(x - 8, y + 8, x + 8, y - 8, (255, 0, 0), panel, 2)
    elif k == "BOX":
        x, y = T(float(r[1]), float(r[2]))
        for panel in (0, 1):
            line(x - 9, y, x + 9, y, (0, 140, 0), panel, 2); line(x, y - 9, x, y + 9, (0, 140, 0), panel, 2)
    elif k == "AP":
        x, y = T(float(r[3]), float(r[4]))
        for panel in (0, 1):
            ring(x, y, 5, (0, 0, 255), panel)

def chunk(t, d):
    c = struct.pack(">I", len(d)) + t + d
    return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
raw = bytearray()
for y in range(H):
    raw.append(0)
    raw += img[y * FULLW * 3:(y + 1) * FULLW * 3]
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", FULLW, H, 8, 2, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b"")
open(out, "wb").write(png)
print("wrote", out)
