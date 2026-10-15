# Two networks side by side around one spot, for plot.py (left panel = A, right panel = B): any two
# exported graphs (export_graph.py), e.g. a course before and after building, or before and after a run.
#   python graph_dump.py A.lua B.lua CX CZ SPAN out.txt
# Two-way links draw grey, one-way blue with an arrow head, as plot.py draws a site dump.
import sys, re

a, b, cx, cz, span, out = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5]), sys.argv[6]
pat = re.compile(r"\{id=(\d+),x=([-\d.]+),y=[-\d.]+,z=([-\d.]+),flags=\d+,out=\{([\d,]*)\}\}")

def load(path):
    wps = {}
    for m in pat.finditer(open(path).read()):
        wps[int(m.group(1))] = (float(m.group(2)), float(m.group(3)), [int(v) for v in m.group(4).split(",") if v])
    return wps

L = [f"VIEW {cx} {cz} {span}"]
for tag, path in (("BL", a), ("AL", b)):
    wps = load(path)
    near = lambda p: abs(p[0] - cx) <= span * 1.2 and abs(p[1] - cz) <= span * 1.2
    for i, (x, z, outs) in wps.items():
        for o in outs:
            q = wps.get(o)
            if q is None or not (near((x, z)) or near(q)):
                continue
            two = i in q[2]
            if two and o < i:
                continue
            L.append(f"{tag} {x} {z} {q[0]} {q[1]} {1 if two else 0}")
open(out, "w").write("\n".join(L) + "\n")
print(f"{len(L) - 1} links -> {out}")
