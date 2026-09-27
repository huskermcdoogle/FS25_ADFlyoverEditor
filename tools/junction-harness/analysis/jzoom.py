import re, math, sys
import os
FS25 = os.environ.get("FS25_PROFILE") or os.path.join(os.path.expanduser("~"), "Documents", "My Games", "FarmingSimulator2025")
SAVE = os.environ.get("FS25_SAVEGAME", "savegame6")
CX, CZ, RAD, OUT = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
FOCUS = int(sys.argv[5])
reg = {}
s = open(os.path.join(FS25, SAVE, "ADFlyoverEditor_junctions.xml"),
         encoding='utf8', errors='ignore').read()
for n, x, z in re.findall(r'n="(\d+)"[^>]*x="(-?[\d.]+)"[^>]*z="(-?[\d.]+)"', s):
    reg[int(n)] = (float(x), float(z))
pts, links = {}, []
for m in re.finditer(r"\{id=(\d+),x=(-?[\d.]+),y=(-?[\d.]+),z=(-?[\d.]+),flags=\d+,out=\{([^}]*)\}\}",
                     open("graph_data.lua").read()):
    i = int(m.group(1)); pts[i] = (float(m.group(2)), float(m.group(4)))
    for t in m.group(5).split(","):
        t = t.strip()
        if t: links.append((i, int(t)))
W = 980; PAD = 30
sc = (W - 2*PAD) / (2*RAD)
def sx(x): return PAD + (x - (CX-RAD)) * sc
def sy(z): return PAD + ((CZ+RAD) - z) * sc      # north up
o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">',
     '<style>text{font-family:ui-sans-serif,system-ui,sans-serif}.n{font-size:14px;font-weight:700}</style>',
     '<rect width="100%" height="100%" fill="#fbfbfa"/>']
for a, b in links:
    if a in pts and b in pts:
        ax, az = pts[a]; bx, bz = pts[b]
        if abs(ax-CX) < RAD*1.2 and abs(az-CZ) < RAD*1.2:
            o.append(f'<line x1="{sx(ax):.1f}" y1="{sy(az):.1f}" x2="{sx(bx):.1f}" y2="{sy(bz):.1f}" '
                     f'stroke="#9fc5a8" stroke-width="1.6"/>')
for n, (x, z) in reg.items():
    if abs(x-CX) <= RAD and abs(z-CZ) <= RAD:
        hot = (n == FOCUS)
        o.append(f'<circle cx="{sx(x):.1f}" cy="{sy(z):.1f}" r="{16 if hot else 13}" '
                 f'fill="{"#d93025" if hot else "#fff"}" stroke="#333" stroke-width="1.6"/>')
        o.append(f'<text class="n" x="{sx(x):.1f}" y="{sy(z)+5:.1f}" text-anchor="middle" '
                 f'fill="{"#fff" if hot else "#111"}">{n}</text>')
o.append(f'<text x="{PAD}" y="{W-10}" font-size="13" fill="#555">'
         f'j{FOCUS} in red - {2*RAD:.0f} m across - north is up</text>')
o.append('<text x="%d" y="%d" font-size="15" font-weight="700" fill="#333">N &#8593;</text>' % (W-60, PAD+22))
o.append('</svg>')
open(OUT, "w", encoding="utf8").write("\n".join(o))
print("wrote", OUT)
