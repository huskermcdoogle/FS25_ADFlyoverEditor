# What does the MAP say each junction is, and does the tool agree?
#
# The map's own roads come from FlyoverRoadSplines (<savegame>/ADFlyoverEditor_roadSplines.xml).
# At each junction, a circle is drawn round it and every map lane that crosses the circle is an arm
# (lanes crossing close together are one arm). Two arms facing each other are a road running
# through. That gives a type - T, Y, crossroads - read from the map maker's roads alone. It is read
# at two circle sizes; where they disagree the map reading is marked unsure.
#
#   python analysis/mapcompare.py <tooltypes.txt from dbgtypes.lua> [out.txt]
import math, os, re, sys

FS25 = os.environ.get("FS25_PROFILE") or next(
    (p for p in (os.path.expanduser("~/OneDrive/Documents/My Games/FarmingSimulator2025"),
                 os.path.expanduser("~/Documents/My Games/FarmingSimulator2025")) if os.path.isdir(p)), "")
SAVE = os.path.join(FS25, os.environ.get("FS25_SAVEGAME", "savegame6"))

splines = []
for pts in re.findall(r'points="([^"]*)"', open(os.path.join(SAVE, "ADFlyoverEditor_roadSplines.xml"), encoding="utf8").read()):
    splines.append([tuple(map(float, p.split(","))) for p in pts.split(";") if p])

def sep(a, b):
    d = abs(a - b) % 360
    return 360 - d if d > 180 else d

# Spline ends, so a lane can be followed from one spline into the next.
ends = {}
for si, s_ in enumerate(splines):
    for which, (x, z) in (("start", s_[0]), ("end", s_[-1])):
        ends.setdefault((round(x), round(z)), []).append((si, which))

def carries_on(si, k, forward, cx, cz, R, need=15.0):
    """From a crossing on spline si between points k and k+1, walk the lane AWAY from the centre.
    A road carries on to R + need; a turn lane curves back in first."""
    s_ = splines[si]
    i = k + 1 if forward else k
    step = 1 if forward else -1
    best, walked, hops = 0.0, 0.0, 0
    prev = None
    while walked < 120 and hops < 6:
        while 0 <= i < len(s_):
            x, z = s_[i]
            d = math.hypot(x - cx, z - cz)
            if d >= R + need: return True
            if d < best - 3: return False
            best = max(best, d)
            if prev: walked += math.hypot(x - prev[0], z - prev[1])
            prev = (x, z)
            i += step
        # end of this spline: carry on into one that starts or ends here
        nxt = None
        for dx in (-1, 0, 1):
            for dz in (-1, 0, 1):
                for sj, which in ends.get((round(prev[0]) + dx, round(prev[1]) + dz), []):
                    if sj != si and math.hypot(splines[sj][0 if which == "start" else -1][0] - prev[0],
                                                splines[sj][0 if which == "start" else -1][1] - prev[1]) < 1.5:
                        nxt = nxt or (sj, which)
        if nxt is None: return best >= R + need * 0.5
        si, which = nxt
        s_ = splines[si]
        i, step = (1, 1) if which == "start" else (len(s_) - 2, -1)
        hops += 1
    return best >= R + need

def arms_at(cx, cz, R, tol=25):
    hits = []
    for si, s in enumerate(splines):
        if not any(abs(x - cx) < R + 5 and abs(z - cz) < R + 5 for x, z in s[::3] + [s[-1]]):
            continue
        for k, ((x0, z0), (x1, z1)) in enumerate(zip(s, s[1:])):
            d0 = math.hypot(x0 - cx, z0 - cz) - R
            d1 = math.hypot(x1 - cx, z1 - cz) - R
            if d0 * d1 < 0:
                if not carries_on(si, k, d1 > d0, cx, cz, R):
                    continue   # a turn lane or a lane that ends: not a road leaving the junction
                t = d0 / (d0 - d1)
                x, z = x0 + (x1 - x0) * t, z0 + (z1 - z0) * t
                hits.append(math.degrees(math.atan2(x - cx, cz - z)) % 360)   # compass: 0 = north
    hits.sort()
    groups = []
    for h in hits:
        if groups and sep(h, groups[-1][-1]) <= tol:
            groups[-1].append(h)
        else:
            groups.append([h])
    if len(groups) > 1 and sep(groups[0][0], groups[-1][-1]) <= tol:
        groups[0] = groups.pop() + groups[0]
    means = []
    for g in groups:
        sx = sum(math.sin(math.radians(a)) for a in g); sz = sum(math.cos(math.radians(a)) for a in g)
        means.append(math.degrees(math.atan2(sx, sz)) % 360)
    return sorted(means)

def kind(arms):
    k = len(arms)
    if k == 0: return "none", "no map road"
    if k <= 2: return "none", "map road only bends here" if k == 2 else "map road ends here"
    if k == 3:
        best = max(((sep(arms[i], arms[j]), i, j) for i in range(3) for j in range(i + 1, 3)))
        if best[0] >= 135:
            other = [a for n, a in enumerate(arms) if n not in (best[1], best[2])][0]
            branch = min(sep(other, arms[best[1]]), sep(other, arms[best[2]]))
            if branch >= 62: return "T", "T square"
            if branch >= 38: return "T", "T skew"
            return "Y", "Y merge"
        return "Y", "Y"
    if k == 4:
        opp = sum(1 for i in range(4) for j in range(i + 1, 4) if sep(arms[i], arms[j]) >= 135)
        return ("4W", "4W") if opp >= 2 else ("other", "4 arms, not two roads crossing")
    return "other", "%d arms" % k

def tool_cat(t):
    t = t.strip()
    if t.startswith("T "): return "T"
    if t.startswith("Y merge"): return "T"     # a shallow T: the map's split point is 38 deg too
    if t.startswith("Y"): return "Y"
    if t.startswith("4W"): return "4W"
    return "other"

lines = [l for l in open(sys.argv[1], encoding="utf8")]
sites = [(float(m.group(2)), float(m.group(3))) for m in (re.match(r"(\d+) (-?[\d.]+) (-?[\d.]+)", l) for l in lines) if m]
def circles(x, z):
    # Stay at THIS junction: no bigger than half the way to the nearest other one.
    nn = min((math.hypot(x - a, z - b) for a, b in sites if (a, b) != (x, z)), default=999)
    r1 = max(12.0, min(25.0, 0.5 * nn))
    return r1, max(r1 + 5, min(40.0, 0.7 * nn))
rows = []
for line in lines:
    m = re.match(r"(\d+) (-?[\d.]+) (-?[\d.]+) \| ([^|]*)\|?(.*)", line.strip())
    if not m: continue
    n, x, z, ttype, troutes = int(m.group(1)), float(m.group(2)), float(m.group(3)), m.group(4).strip(), m.group(5).strip()
    r1, r2 = circles(x, z)
    a25, a40 = arms_at(x, z, r1), arms_at(x, z, r2)
    (c25, k25), (c40, k40) = kind(a25), kind(a40)
    sure = c25 == c40
    tc = tool_cat(ttype)
    if ttype in ("nil", ""):
        verdict = "TOOL NO READ"
    elif c25 == "none":
        verdict = "NO MAP ROAD"
    elif not sure:
        verdict = "MAP UNSURE"
    elif tc == c25:
        verdict = "agree"
    else:
        verdict = "DISAGREE"
    rows.append((n, x, z, ttype, k25, k40, a25, verdict))

out = open(sys.argv[2], "w", encoding="utf8") if len(sys.argv) > 2 else sys.stdout
order = {"DISAGREE": 0, "TOOL NO READ": 1, "MAP UNSURE": 2, "NO MAP ROAD": 3, "agree": 4}
for n, x, z, ttype, k25, k40, a25, v in sorted(rows, key=lambda r: (order[r[7]], r[0])):
    out.write("%-11s j%-3d (%7.1f, %7.1f)  tool: %-26s  map: %-14s (wider circle: %s)  arms %s\n" % (
        v, n, x, z, ttype, k25, k40, " ".join("%.0f" % a for a in a25)))
counts = {}
for r in rows: counts[r[7]] = counts.get(r[7], 0) + 1
out.write("\n" + ", ".join("%s %d" % (k, counts[k]) for k in sorted(counts, key=lambda k: order[k])) + "\n")
