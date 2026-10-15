# The current layout, straight from a savegame: the network, loose islands picked out, and every
# junction numbered as the editor's own registry numbers it. North up. Pure stdlib SVG.
#   python analysis/jmap_live.py [out.svg] [highlight numbers...]
import os, re, sys
import xml.etree.ElementTree as ET

FS25 = os.environ.get("FS25_PROFILE") or next(
    (p for p in (os.path.expanduser("~/OneDrive/Documents/My Games/FarmingSimulator2025"),
                 os.path.expanduser("~/Documents/My Games/FarmingSimulator2025")) if os.path.isdir(p)), "")
SAVE = os.path.join(FS25, os.environ.get("FS25_SAVEGAME", "savegame6"))
OUT = sys.argv[1] if len(sys.argv) > 1 else "junction_map_live.svg"
HOT = {int(a) for a in sys.argv[2:]}

wp = ET.parse(os.path.join(SAVE, "AutoDrive_config.xml")).getroot().find(".//waypoints")
ids = [int(v) for v in wp.find("id").text.split(",")]
xs = [float(v) for v in wp.find("x").text.split(",")]
zs = [float(v) for v in wp.find("z").text.split(",")]
outs = [[int(t) for t in s.split(",") if t and t != "-1"] for s in wp.find("out").text.split(";")]
pts = {i: (x, z) for i, x, z in zip(ids, xs, zs)}
links = [(a, b) for a, o in zip(ids, outs) for b in o if b in pts]

# Connected pieces, ignoring direction.
adj = {i: [] for i in pts}
for a, b in links:
    adj[a].append(b); adj[b].append(a)
piece, sizes = {}, []
for s in pts:
    if s in piece: continue
    k, st, n = len(sizes), [s], 0
    piece[s] = k
    while st:
        a = st.pop(); n += 1
        for b in adj[a]:
            if b not in piece: piece[b] = k; st.append(b)
    sizes.append(n)
main = max(range(len(sizes)), key=lambda k: sizes[k])

reg = [(int(j.get("n")), float(j.get("x")), float(j.get("z")))
       for j in ET.parse(os.path.join(SAVE, "ADFlyoverEditor_junctions.xml")).getroot().iter("junction")]

minx, maxx = min(xs), max(xs); minz, maxz = min(zs), max(zs)
PAD, W = 40, 1600
sc = (W - 2 * PAD) / max(maxx - minx, maxz - minz)
H = int((maxz - minz) * sc) + 2 * PAD + 30
sx = lambda x: PAD + (x - minx) * sc
sy = lambda z: PAD + (z - minz) * sc   # FS25: z grows southward, so north is small z
o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
     '<style>text{font-family:ui-sans-serif,system-ui,sans-serif;font-size:12px;font-weight:700}</style>',
     '<rect width="100%" height="100%" fill="#fbfbfa"/>']
seen, loose = set(), 0
for a, b in links:
    if (b, a) in seen: continue
    seen.add((a, b))
    isl = piece[a] != main
    o.append(f'<line x1="{sx(pts[a][0]):.1f}" y1="{sy(pts[a][1]):.1f}" x2="{sx(pts[b][0]):.1f}" '
             f'y2="{sy(pts[b][1]):.1f}" stroke="{"#1a73e8" if isl else "#b9c8bd"}" '
             f'stroke-width="{2.2 if isl else 1}"/>')
nIsl = sum(1 for k in range(len(sizes)) if k != main and sizes[k] > 1)
for n, x, z in reg:
    hot = n in HOT
    o.append(f'<circle cx="{sx(x):.1f}" cy="{sy(z):.1f}" r="{13 if hot else 10}" fill="{"#d93025" if hot else "#fff"}" '
             f'stroke="#333" stroke-width="1.3"/>')
    o.append(f'<text x="{sx(x):.1f}" y="{sy(z) + 4:.1f}" text-anchor="middle" fill="{"#fff" if hot else "#111"}">{n}</text>')
o.append(f'<text x="{PAD}" y="{H - 14}" fill="#444" font-weight="400">{len(reg)} junctions (registry numbers) - '
         f'{len(pts)} waypoints - blue: {nIsl} loose piece(s) not joined to the main network - north up'
         + (f' - red: {", ".join(map(str, sorted(HOT)))}' if HOT else '') + '</text>')
o.append('</svg>')
open(OUT, "w", encoding="utf8").write("\n".join(o))
print(f"wrote {OUT}: {len(reg)} junctions, {len(pts)} waypoints, {nIsl} loose pieces")
