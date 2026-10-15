"""Fit the mod's X onto a real square crossroads and draw it beside what today's builder lays.
    python fitpattern.py <dump from junction-harness/dump_build.lua> out.svg [rightR] [leftR]
Three panels, north up, same scale: today's build | the mod's X, exact | the same shape with curves.
The fit: the four kept through lanes cross at four inner corners; their middle is the centre, their
spacing the lane gap L, and the lane directions the frame. Curve sizes are in lane gaps (default right
1.5 L, left 1.71 L - the size at which opposite left curves pass exactly through the centre)."""
import math, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from legal import X, XL

src, out = sys.argv[1], sys.argv[2]
RR = float(sys.argv[3]) if len(sys.argv) > 3 else 1.5
LR = float(sys.argv[4]) if len(sys.argv) > 4 else 1.71

C, B = [], []
for line in open(src):
    p = line.split()
    if p[0] == "VIEW": vx, vz = float(p[1]), float(p[2])
    elif p[0] in ("C", "B"):
        (C if p[0] == "C" else B).append(((float(p[1]), float(p[2])), (float(p[3]), float(p[4])), p[5] == "1"))

def cross(s1, s2):
    (ax, az), (bx, bz) = s1; (cx, cz), (dx, dz) = s2
    den = (bx - ax) * (dz - cz) - (bz - az) * (dx - cx)
    if abs(den) < 1e-9: return None
    t = ((cx - ax) * (dz - cz) - (cz - az) * (dx - cx)) / den
    u = ((cx - ax) * (bz - az) - (cz - az) * (bx - ax)) / den
    if 0 < t < 1 and 0 < u < 1: return (ax + t * (bx - ax), az + t * (bz - az))
    return None

def unit(x, z):
    n = math.hypot(x, z); return (x / n, z / n)

# Inner corners: kept lanes crossing at a real angle near the click.
corners = []
for i in range(len(C)):
    for j in range(i + 1, len(C)):
        a, b = C[i], C[j]
        p = cross((a[0], a[1]), (b[0], b[1]))
        if p is None or math.hypot(p[0] - vx, p[1] - vz) > 12: continue
        u, v = unit(a[1][0] - a[0][0], a[1][1] - a[0][1]), unit(b[1][0] - b[0][0], b[1][1] - b[0][1])
        if abs(u[0] * v[0] + u[1] * v[1]) < 0.7: corners.append((p, u, v))
assert len(corners) == 4, "expected 4 inner corners, found %d" % len(corners)
cx = sum(c[0][0] for c in corners) / 4; cz = sum(c[0][1] for c in corners) / 4
# Frame: mod +x is a lane direction whose lane runs on the +z side (right-hand traffic: eastbound runs
# south of the centre line). +z is +x turned a quarter toward the right.
ex = None
for p, u, v in corners:
    for d in (u, v):
        ez = (-d[1], d[0])
        if (p[0] - cx) * ez[0] + (p[1] - cz) * ez[1] > 0: ex = d; break
    if ex: break
ez = (-ex[1], ex[0])
loc = [((p[0] - cx) * ex[0] + (p[1] - cz) * ex[1], (p[0] - cx) * ez[0] + (p[1] - cz) * ez[1]) for p, _, _ in corners]
L = sum(abs(a) + abs(b) for a, b in loc) / 4   # each corner sits at (+-L/2, +-L/2)
W = lambda mx, mz: (cx + L * (mx * ex[0] + mz * ez[0]), cz + L * (mx * ex[1] + mz * ez[1]))

def rot(p, k):   # quarter turns about the centre, mod units: (x, z) -> (-z, x)
    x, z = p
    for _ in range(k): x, z = -z, x
    return (x, z)

def arc(c, r, a0, a1, n=24):
    return [(c[0] + r * math.cos(a0 + (a1 - a0) * i / n), c[1] + r * math.sin(a0 + (a1 - a0) * i / n)) for i in range(n + 1)]

# One approach (eastbound, on z = +0.5), the other three by symmetry.
# Right into the southbound lane (x = -0.5): centre (-0.5 - r, 0.5 + r), from straight above it to its right.
right0 = arc((-0.5 - RR, 0.5 + RR), RR, -math.pi / 2, 0)
# Left into the northbound lane (x = +0.5): centre (0.5 - r, 0.5 - r), from below it round to its right.
left0 = arc((0.5 - LR, 0.5 - LR), LR, math.pi / 2, 0)
curves = []
for k in range(4):
    curves.append(("R", [W(*rot(p, k)) for p in right0]))
    curves.append(("L", [W(*rot(p, k)) for p in left0]))

# ---------------------------------------------------------------- drawing
S, PANEL, GAP, HALF = 14, 460, 24, 16.0
def P(panel, x, z):
    return (panel * (PANEL + GAP) + PANEL / 2 + (x - cx) * S, 40 + PANEL / 2 + (z - cz) * S)
svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{3 * PANEL + 2 * GAP}" height="{PANEL + 110}" '
       f'viewBox="0 0 {3 * PANEL + 2 * GAP} {PANEL + 110}" font-family="sans-serif">',
       '<rect width="100%" height="100%" fill="#fff"/>',
       '<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto">'
       '<path d="M0,0 L10,5 L0,10 z" fill="context-stroke"/></marker></defs>']
def seg(panel, a, b, col, w=2, arrow=True, dash=None):
    (x1, y1), (x2, y2) = P(panel, *a), P(panel, *b)
    extra = (' marker-end="url(#a)"' if arrow else '') + (f' stroke-dasharray="{dash}"' if dash else '')
    svg.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="{col}" stroke-width="{w}"{extra}/>')
def poly(panel, pts, col, w=2.5):
    d = " ".join(f"{x:.1f},{y:.1f}" for x, y in (P(panel, *p) for p in pts))
    svg.append(f'<polyline points="{d}" fill="none" stroke="{col}" stroke-width="{w}" marker-end="url(#a)"/>')
def ring(panel, p, col="#dc2626", r=6):
    x, y = P(panel, *p); svg.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}" fill="none" stroke="{col}" stroke-width="2"/>')
def dot(panel, p, col="#1e293b", r=2.5):
    x, y = P(panel, *p); svg.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}" fill="{col}"/>')
def text(panel, x, y, s, size=13, col="#0f172a", weight="normal"):
    svg.append(f'<text x="{panel * (PANEL + GAP) + x}" y="{y}" font-size="{size}" fill="{col}" font-weight="{weight}">{s}</text>')

GREY, RED, BLUE, GREEN, ORANGE = "#94a3b8", "#dc2626", "#2563eb", "#059669", "#d97706"
for panel in range(3):
    x0 = panel * (PANEL + GAP)
    svg.append(f'<rect x="{x0}" y="40" width="{PANEL}" height="{PANEL}" fill="#f8fafc" stroke="#e2e8f0"/>')
    svg.append(f'<clipPath id="c{panel}"><rect x="{x0}" y="40" width="{PANEL}" height="{PANEL}"/></clipPath>')
    svg.append(f'<g clip-path="url(#c{panel})">')
    for a, b, d in C: seg(panel, a, b, GREY, 2.5, arrow=True)
    if panel == 0:
        pts = set()
        for a, b, d in B:
            seg(panel, a, b, ORANGE if d else RED, 1.6, arrow=False)
            pts.add(a); pts.add(b)
        for p in pts: dot(panel, p, RED, 1.8)
    elif panel == 1:
        two = {(a, b) for a, b in XL if (b, a) in XL}
        for a, b in XL:
            if (b, a) in two and a > b: continue
            seg(panel, W(*X[a]), W(*X[b]), ORANGE if (a, b) in two else BLUE, 2, arrow=(a, b) not in two)
        inc = {}
        for a, b in XL: inc.setdefault(b, set()).add(a)
        for n, p in X.items():
            dot(panel, W(*p), "#0d9488" if n == 1 else BLUE, 4 if n == 1 else 2.5)
            if len(inc.get(n, ())) >= 2: ring(panel, W(*p))
    else:
        for kind, pts in curves: poly(panel, pts, GREEN, 2.2)
        # Shared points: every place a new curve crosses a lane or another curve.
        segs = [((a, b), "lane") for a, b, d in C] + [((p[i], p[i + 1]), k) for k, p in curves for i in range(len(p) - 1)]
        marks = []
        for i in range(len(segs)):
            for j in range(i + 1, len(segs)):
                if segs[i][1] == "lane" and segs[j][1] == "lane": continue
                q = cross(segs[i][0], segs[j][0])
                if q and not any(math.hypot(q[0] - m[0], q[1] - m[1]) < 0.4 for m in marks): marks.append(q)
        for p, _, _ in corners: marks.append(p)
        for m in marks: ring(panel, m)
    svg.append('</g>')
    # 5 m scale bar
    bx, by = x0 + 14, 40 + PANEL - 14
    svg.append(f'<line x1="{bx}" y1="{by}" x2="{bx + 5 * S}" y2="{by}" stroke="#334155" stroke-width="2"/>')
    text(panel, 14, 40 + PANEL - 20, "5 m", 11, "#334155")

text(0, 4, 26, "Today's build (one curve per turn)", 15, weight="bold")
text(1, 4, 26, "The mod's X, exact, fitted here", 15, weight="bold")
text(2, 4, 26, f"Same shape, smooth curves (right {RR:g} L, left {LR:g} L)", 15, weight="bold")
foot = PANEL + 62
text(0, 4, foot, f"Lane gap L = {L:.1f} m. Grey: through lanes kept by the clear.", 12, "#334155")
text(0, 4, foot + 18, "Red: laid today. Red ring: a shared point. North up.", 12, "#334155")
text(1, 4, foot, "Blue: the mod's paths. Teal: the centre every left uses.", 12, "#334155")
text(1, 4, foot + 18, "Orange: two-way. Rights: a short 45 degree cut.", 12, "#334155")
text(2, 4, foot, "Green: placed by the pattern. All four lefts", 12, "#334155")
text(2, 4, foot + 18, "pass through the centre; rights hug each corner.", 12, "#334155")
svg.append('</svg>')
open(out, "w", encoding="utf-8").write("\n".join(svg))
print("lane gap %.2f m, centre %.1f, %.1f, %d curves -> %s" % (L, cx, cz, len(curves), out))
