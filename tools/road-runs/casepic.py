# Picture (SVG) of a saved case: paint, the user's drawn middle, and the line walked from each spot.
# North up: small z at the top (FS25 z grows southward).
#   py casepic.py cells.txt walks.txt out.svg "title" [x0 x1 z0 z1]
import sys
cells_f, walks_f, out, title = sys.argv[1:5]
box = [float(v) for v in sys.argv[5:9]] if len(sys.argv) >= 9 else None
col = {1: "#8b5a2b", 2: "#d9bf4a", 3: "#8f8f8f", 4: "#7fb2ff", 5: "#5f7f3a"}
names = {1: "dirt", 2: "gravel", 3: "asphalt", 4: "shoulder", 5: "field"}
spot_col = {1: "#e69f00", 2: "#56b4e9", 3: "#cc79a7", 4: "#d55e00", 5: "#f0e442"}
cells = [(float(p[1]), float(p[2]), int(p[3])) for p in (l.split() for l in open(cells_f)) if p and p[0] == "c"]
mid, spots, lines = [], {}, {}
for l in open(walks_f):
    p = l.split()
    if not p: continue
    if p[0] == "m": mid.append((float(p[1]), float(p[2])))
    elif p[0] == "s": spots[int(p[1])] = (float(p[2]), float(p[3]))
    elif p[0] == "l": lines.setdefault(int(p[1]), []).append((float(p[2]), float(p[3])))
if box: x0, x1, z0, z1 = box
else:
    x0, x1 = min(c[0] for c in cells), max(c[0] for c in cells)
    z0, z1 = min(c[1] for c in cells), max(c[1] for c in cells)
S = 9.0 if not box else 900.0 / max(x1 - x0, z1 - z0)
pad, legend = 30, 190
W, H = (x1 - x0) * S, (z1 - z0) * S
px = lambda x: pad + (x - x0) * S
pz = lambda z: pad + 24 + (z - z0) * S
o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W + 2 * pad + legend:.0f}" height="{H + 2 * pad + 30:.0f}" font-family="sans-serif" font-size="13">',
     '<rect width="100%" height="100%" fill="#2e4228"/>', f'<text x="{pad}" y="20" fill="white" font-size="16">{title}</text>']
for x, z, k in cells:
    if x0 <= x <= x1 and z0 <= z <= z1:
        o.append(f'<rect x="{px(x) - S / 4:.1f}" y="{pz(z) - S / 4:.1f}" width="{S / 2 + 0.3:.1f}" height="{S / 2 + 0.3:.1f}" fill="{col[k]}"/>')
def poly(P, c, w, dash=""):
    P = [q for q in P if x0 - 2 <= q[0] <= x1 + 2 and z0 - 2 <= q[1] <= z1 + 2]
    if len(P) > 1:
        o.append(f'<polyline points="{" ".join(f"{px(x):.1f},{pz(z):.1f}" for x, z in P)}" fill="none" stroke="{c}" stroke-width="{w}" {dash} stroke-linejoin="round"/>')
poly(mid, "white", 5)
for i, P in sorted(lines.items()):
    poly(P, spot_col[i], 2.5, 'stroke-dasharray="8 4"' if i % 2 == 0 else "")
for i, (x, z) in sorted(spots.items()):
    if x0 <= x <= x1 and z0 <= z <= z1:
        o.append(f'<circle cx="{px(x):.1f}" cy="{pz(z):.1f}" r="7" fill="{spot_col[i]}" stroke="black"/><text x="{px(x) + 9:.1f}" y="{pz(z) + 5:.1f}" fill="white" font-weight="bold">{i}</text>')
lx, ly = pad + W + 20, pad + 40
for j, (k, n) in enumerate(names.items()):
    o.append(f'<rect x="{lx}" y="{ly + j * 22}" width="14" height="14" fill="{col[k]}"/><text x="{lx + 20}" y="{ly + j * 22 + 12}" fill="white">{n}</text>')
j = len(names)
o.append(f'<line x1="{lx}" y1="{ly + j * 22 + 7}" x2="{lx + 14}" y2="{ly + j * 22 + 7}" stroke="white" stroke-width="5"/><text x="{lx + 20}" y="{ly + j * 22 + 12}" fill="white">your drawn middle</text>')
for i in sorted(spots):
    j += 1
    o.append(f'<line x1="{lx}" y1="{ly + j * 22 + 7}" x2="{lx + 14}" y2="{ly + j * 22 + 7}" stroke="{spot_col[i]}" stroke-width="3"/><text x="{lx + 20}" y="{ly + j * 22 + 12}" fill="white">click at spot {i} ({len(lines.get(i, []))} pts)</text>')
o.append("</svg>")
open(out, "w").write("\n".join(o))
print("wrote", out)
