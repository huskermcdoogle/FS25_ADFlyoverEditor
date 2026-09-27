# A map of every numbered junction, north up. Pure stdlib SVG.
import re, math
reg = []
for line in open("reg_now.txt"):
    m = re.match(r"\s*j(\d+)\s+(-?[\d.]+)\s+(-?[\d.]+)", line)
    if m: reg.append((int(m.group(1)), float(m.group(2)), float(m.group(3))))
pts, links = {}, []
for m in re.finditer(r"\{id=(\d+),x=(-?[\d.]+),y=(-?[\d.]+),z=(-?[\d.]+),flags=\d+,out=\{([^}]*)\}\}", open("graph_data.lua").read()):
    i = int(m.group(1)); pts[i] = (float(m.group(2)), float(m.group(4)))
    for t in m.group(5).split(","):
        t = t.strip()
        if t: links.append((i, int(t)))
xs = [p[0] for p in pts.values()]; zs = [p[1] for p in pts.values()]
minx, maxx, minz, maxz = min(xs), max(xs), min(zs), max(zs)
PAD, W = 40, 1500
sc = (W - 2*PAD) / max(maxx-minx, maxz-minz)
H = int((maxz-minz)*sc) + 2*PAD
def sx(x): return PAD + (x-minx)*sc
def sy(z): return PAD + ((maxz-z))*sc          # north up: z increases southward
o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">']
o.append('<style>text{font-family:ui-sans-serif,system-ui,sans-serif}'
         '.n{font-size:13px;font-weight:700;fill:#111}'
         '.h{font-size:13px;font-weight:700;fill:#fff}</style>')
o.append(f'<rect width="100%" height="100%" fill="#fbfbfa"/>')
seen = set()
for a, b in links:
    if a in pts and b in pts and (b, a) not in seen:
        seen.add((a, b))
        o.append(f'<line x1="{sx(pts[a][0]):.1f}" y1="{sy(pts[a][1]):.1f}" '
                 f'x2="{sx(pts[b][0]):.1f}" y2="{sy(pts[b][1]):.1f}" stroke="#c9d6cc" stroke-width="1"/>')
FOCUS = {60: "worked today", 15: "", 19: "", 36: "", 13: "", 35: "", 27: ""}
for n, x, z in reg:
    cx, cy = sx(x), sy(z)
    hot = n in FOCUS
    o.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{13 if hot else 11}" '
             f'fill="{"#d93025" if n==60 else ("#f4a300" if hot else "#fff")}" stroke="#333" stroke-width="1.4"/>')
    o.append(f'<text class="{"h" if n==60 else "n"}" x="{cx:.1f}" y="{cy+4.5:.1f}" text-anchor="middle">{n}</text>')
o.append(f'<text x="{PAD}" y="{H-14}" font-size="13" fill="#555">'
         f'{len(reg)} numbered junctions - north is up - red: j60, the crossing worked on today - '
         f'amber: the ones under discussion</text>')
o.append('</svg>')
open("junction_key.svg","w",encoding="utf8").write("\n".join(o))
print("wrote junction_key.svg  (%d junctions, %d waypoints)" % (len(reg), len(pts)))
