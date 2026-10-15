"""Draw what builds actually laid, side by side, north up, same scale.
    python drawbuilt.py out.svg "Title A" dumpA.txt ["Title B" dumpB.txt ...]
Each dump comes from tools/junction-harness/dump_build.lua: grey = lanes left by the clear, red = the
build's links (orange = two-way), dots = its points, rings = points where two or more paths come in."""
import sys, math

out = sys.argv[1]
pairs = [(sys.argv[i], sys.argv[i + 1]) for i in range(2, len(sys.argv), 2)]
S, PANEL, GAP = 16, 460, 24
svg_w = len(pairs) * PANEL + (len(pairs) - 1) * GAP
svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{svg_w}" height="{PANEL + 90}" viewBox="0 0 {svg_w} {PANEL + 90}" font-family="sans-serif">',
       '<rect width="100%" height="100%" fill="#fff"/>',
       '<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto">'
       '<path d="M0,0 L10,5 L0,10 z" fill="context-stroke"/></marker></defs>']
for k, (title, path) in enumerate(pairs):
    C, B = [], []
    for line in open(path):
        p = line.split()
        if p[0] == "VIEW": vx, vz = float(p[1]), float(p[2])
        elif p[0] in ("C", "B"):
            (C if p[0] == "C" else B).append(((float(p[1]), float(p[2])), (float(p[3]), float(p[4])), p[5] == "1"))
    x0 = k * (PANEL + GAP)
    P = lambda x, z: (x0 + PANEL / 2 + (x - vx) * S, 40 + PANEL / 2 + (z - vz) * S)
    svg.append(f'<rect x="{x0}" y="40" width="{PANEL}" height="{PANEL}" fill="#f8fafc" stroke="#e2e8f0"/>')
    svg.append(f'<clipPath id="c{k}"><rect x="{x0}" y="40" width="{PANEL}" height="{PANEL}"/></clipPath><g clip-path="url(#c{k})">')
    # The lanes as they are after the build: a lane link the build split shows as build links.
    final = B + [c for c in C]
    inc = {}
    for a, b, d in B:
        inc.setdefault(b, set()).add(a)
        if d: inc.setdefault(a, set()).add(b)
    for a, b, d in C:
        (x1, y1), (x2, y2) = P(*a), P(*b)
        svg.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="#cbd5e1" stroke-width="3"/>')
    pts = set()
    for a, b, d in B:
        (x1, y1), (x2, y2) = P(*a), P(*b)
        n = math.hypot(x2 - x1, y2 - y1) or 1
        col = "#d97706" if d else "#dc2626"
        mk = '' if d else ' marker-end="url(#a)"'
        svg.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2 - (x2 - x1) * 3 / n:.1f}" y2="{y2 - (y2 - y1) * 3 / n:.1f}" stroke="{col}" stroke-width="1.8"{mk}/>')
        pts.add(a); pts.add(b)
    for p in pts:
        x, y = P(*p)
        svg.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="2" fill="#1e293b"/>')
        if len(inc.get(p, ())) >= 2:
            svg.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="6" fill="none" stroke="#2563eb" stroke-width="1.8"/>')
    svg.append('</g>')
    svg.append(f'<text x="{x0 + 4}" y="26" font-size="15" font-weight="bold" fill="#0f172a">{title}</text>')
    bx, by = x0 + 14, 40 + PANEL - 14
    svg.append(f'<line x1="{bx}" y1="{by}" x2="{bx + 5 * S}" y2="{by}" stroke="#334155" stroke-width="2"/>')
    svg.append(f'<text x="{bx}" y="{by - 6}" font-size="11" fill="#334155">5 m</text>')
svg.append(f'<text x="4" y="{PANEL + 66}" font-size="12" fill="#334155">Grey: lanes kept by the clear. Red: links the build laid (orange: two-way). Blue ring: two or more paths come in. North up.</text>')
svg.append('</svg>')
open(out, "w", encoding="utf-8").write("\n".join(svg))
print("wrote", out)
