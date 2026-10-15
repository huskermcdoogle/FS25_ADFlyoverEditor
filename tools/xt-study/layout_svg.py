"""Draw the T and X layouts (6 m size), north up, for docs/junction-tool/05-placeable-junctions.md."""
import math, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from legal import T, TL, X, XL

OUT = sys.argv[1]
L, SC, PAD = 6, 22, 40

def draw(name, N, links, shared, title):
    R = 1.5 * L
    W = int(2 * R * SC + 2 * PAD)
    P = lambda n: (PAD + (N[n][0] * L + R) * SC, PAD + (N[n][1] * L + R) * SC)   # z south = down = north up
    two = {(a, b) for a, b in links if (b, a) in links}
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W + 55}" viewBox="0 0 {W} {W + 55}" font-family="sans-serif">',
         '<rect width="100%" height="100%" fill="#fff"/>',
         '<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
         '<path d="M0,0 L10,5 L0,10 z" fill="#475569"/></marker></defs>']
    for a, b in links:
        if (b, a) in two and a > b: continue
        (x1, y1), (x2, y2) = P(a), P(b)
        dx, dy = x2 - x1, y2 - y1; n = math.hypot(dx, dy); k = 7 / n
        col = '#d97706' if (a, b) in two else '#475569'
        ends = 'marker-start="url(#a)" marker-end="url(#a)"' if (a, b) in two else 'marker-end="url(#a)"'
        s.append(f'<line x1="{x1 + dx * k:.1f}" y1="{y1 + dy * k:.1f}" x2="{x2 - dx * k:.1f}" y2="{y2 - dy * k:.1f}" '
                 f'stroke="{col}" stroke-width="2" {ends}/>')
    for n in N:
        x, y = P(n)
        if n in shared:
            s.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="9" fill="none" stroke="#dc2626" stroke-width="2.5"/>')
        fill = '#0d9488' if n == 1 else '#1e293b'
        s.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{5 if n == 1 else 3.5}" fill="{fill}"/>')
        s.append(f'<text x="{x + 8:.1f}" y="{y - 7:.1f}" font-size="11" fill="#64748b">{n}</text>')
    s.append(f'<text x="{PAD}" y="{W + 12}" font-size="13" fill="#0f172a">{title}</text>')
    s.append(f'<text x="{PAD}" y="{W + 30}" font-size="11" fill="#475569">Red ring: two paths come in (AutoDrive can make one wait).</text>')
    s.append(f'<text x="{PAD}" y="{W + 45}" font-size="11" fill="#475569">Teal: centre, also a destination. Orange: two-way.</text>')
    s.append(f'<text x="{W - PAD}" y="22" font-size="12" text-anchor="end" fill="#475569">North up. Lanes 6 m apart.</text>')
    s.append('</svg>')
    open(os.path.join(OUT, name), 'w', encoding='utf-8').write('\n'.join(s))

def sharedPoints(N, links):
    out = {}; inc = {}
    for a, b in links: out.setdefault(a, set()).add(b); inc.setdefault(b, set()).add(a)
    return {n for n in N if len(inc.get(n, ())) >= 2}

draw('t-layout.svg', T, TL, sharedPoints(T, TL), 'T, 6 m size (side road to the south)')
draw('x-layout.svg', X, XL, sharedPoints(X, XL), 'X, 6 m size')
print('ok')
