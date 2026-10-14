# Picture (SVG) of bendplot.lua's dump: paint, the walker's own path, the laid line. North (small z) up.
#   py bendplot.py out/bend.txt out/bend.svg "title"
import sys
src, out = sys.argv[1], sys.argv[2]
title = sys.argv[3] if len(sys.argv) > 3 else ""
col = {1: "#8b5a2b", 2: "#e6c84a", 3: "#9a9a9a", 4: "#7fb2ff", 5: "#e8b0b0"}
names = {1: "dirt", 2: "gravel", 3: "asphalt", 4: "road shoulder", 5: "field"}
cells, walk, line = [], [], []
for ln in open(src):
    p = ln.split()
    if not p:
        continue
    if p[0] == "c":
        cells.append((float(p[1]), float(p[2]), int(p[3])))
    elif p[0] == "w":
        walk.append((float(p[1]), float(p[2])))
    elif p[0] == "l":
        line.append((float(p[1]), float(p[2])))
x0, x1 = min(c[0] for c in cells), max(c[0] for c in cells)
z0, z1 = min(c[1] for c in cells), max(c[1] for c in cells)
S = 14  # pixels per metre
W, H = (x1 - x0 + 0.5) * S, (z1 - z0 + 0.5) * S
pad, legend = 40, 150
def px(x): return pad + (x - x0) * S
def pz(z): return pad + 20 + (z - z0) * S
o = []
o.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W + 2 * pad + legend:.0f}" height="{H + 2 * pad + 20:.0f}" font-family="sans-serif" font-size="12">')
o.append('<rect width="100%" height="100%" fill="#2f4a2a"/>')
o.append(f'<text x="{pad}" y="24" fill="white" font-size="15">{title}</text>')
for x, z, c in cells:
    if c in col:
        o.append(f'<rect x="{px(x) - S / 4:.1f}" y="{pz(z) - S / 4:.1f}" width="{S / 2:.1f}" height="{S / 2:.1f}" fill="{col[c]}"/>')
def inbox(P): return [p for p in P if x0 - 1 <= p[0] <= x1 + 1 and z0 - 1 <= p[1] <= z1 + 1]
def poly(P, colour, w, dots):
    if len(P) < 2:
        return
    pts = " ".join(f"{px(x):.1f},{pz(z):.1f}" for x, z in P)
    o.append(f'<polyline points="{pts}" fill="none" stroke="{colour}" stroke-width="{w}"/>')
    if dots:
        for x, z in P:
            o.append(f'<circle cx="{px(x):.1f}" cy="{pz(z):.1f}" r="2.5" fill="{colour}"/>')
poly(inbox(walk), "#ff9f1c", 2, False)
poly(inbox(line), "#3050ff", 3, True)
# grid every 5 m
for gx in range(int(x0 // 5 * 5), int(x1) + 1, 5):
    if gx >= x0:
        o.append(f'<line x1="{px(gx):.1f}" y1="{pz(z0) - 6}" x2="{px(gx):.1f}" y2="{pz(z1) + 6}" stroke="white" stroke-opacity="0.15"/>')
        o.append(f'<text x="{px(gx) - 10:.1f}" y="{pz(z1) + 22}" fill="#ddd" font-size="10">{gx}</text>')
for gz in range(int(z0 // 5 * 5), int(z1) + 1, 5):
    if gz >= z0:
        o.append(f'<line x1="{px(x0) - 6}" y1="{pz(gz):.1f}" x2="{px(x1) + 6}" y2="{pz(gz):.1f}" stroke="white" stroke-opacity="0.15"/>')
        o.append(f'<text x="2" y="{pz(gz) + 4:.1f}" fill="#ddd" font-size="10">{gz}</text>')
lx, ly = pad + W + 15, pad + 30
for i, (k, n) in enumerate(names.items()):
    o.append(f'<rect x="{lx}" y="{ly + i * 20}" width="12" height="12" fill="{col[k]}"/><text x="{lx + 18}" y="{ly + i * 20 + 11}" fill="white">{n}</text>')
i = len(names)
o.append(f'<line x1="{lx}" y1="{ly + i * 20 + 6}" x2="{lx + 12}" y2="{ly + i * 20 + 6}" stroke="#ff9f1c" stroke-width="2"/><text x="{lx + 18}" y="{ly + i * 20 + 11}" fill="white">walker\'s path</text>')
i += 1
o.append(f'<line x1="{lx}" y1="{ly + i * 20 + 6}" x2="{lx + 12}" y2="{ly + i * 20 + 6}" stroke="#3050ff" stroke-width="3"/><text x="{lx + 18}" y="{ly + i * 20 + 11}" fill="white">laid line</text>')
o.append("</svg>")
open(out, "w").write("\n".join(o))
print("wrote", out)
