# Score the tool's and the map's junction readings against the user's own (truth_types.txt).
#   python analysis/score.py compare.txt [truth_types.txt] [tooltypes.txt]
# With tooltypes.txt (from dbgtypes.lua), junctions whose answer names the main road ("main=NE-S")
# are also checked: some through route must leave within 45 degrees of both named directions.
# "Kind" is T / Y / crossroads; a Y merge counts as a T (a shallow one), "?" answers are shown
# but not scored.
import re, sys

COMPASS = {"N": 0, "NE": 45, "E": 90, "SE": 135, "S": 180, "SW": 225, "W": 270, "NW": 315}
truth, mainOf = {}, {}
for line in open(sys.argv[2] if len(sys.argv) > 2 else "truth_types.txt", encoding="utf8"):
    line = line.split("#")[0].strip()
    if line:
        n, k = line.split(None, 1)
        m = re.search(r"main=(\w+)-(\w+)", k)
        if m: mainOf[int(n)] = (COMPASS[m.group(1)], COMPASS[m.group(2)])
        truth[int(n)] = re.sub(r"\s*main=\S+", "", k).strip()
toolMain = {}
if len(sys.argv) > 3:
    for line in open(sys.argv[3], encoding="utf8"):
        m = re.match(r"(\d+) .*\| main (.*)$", line.strip())
        if m and m.group(2) != "none":
            # "a/b" is read 25 m out, "fara/b" where the route ends; either may match the answer
            toolMain[int(m.group(1))] = [tuple(int(v) for v in p.replace("far", "").split("/")) for p in m.group(2).split(",")]
def sep(a, b):
    d = abs(a - b) % 360
    return 360 - d if d > 180 else d
def mainRight(n):
    a, b = mainOf[n]
    return any((sep(a, x) <= 45 and sep(b, y) <= 45) or (sep(a, y) <= 45 and sep(b, x) <= 45)
               for x, y in toolMain.get(n, []))

def kind(k):
    k = k.strip().rstrip("?").strip()
    if k.startswith("T ") or k.startswith("Y merge"): return "T"
    if k == "Y": return "Y"
    if k.startswith("4W"): return "4W"
    return "other"

rx = re.compile(r".*?\bj(\d+)\s+\(.*?\)\s+tool: (.*?)\s{2,}map: (.*?)\s+\(wider")
tool_ok = map_ok = scored = 0
print("%-4s %-14s %-28s %-6s %-30s %s" % ("jn", "you", "tool", "", "map", ""))
for line in open(sys.argv[1], encoding="utf8"):
    m = rx.match(line)
    if not m or int(m.group(1)) not in truth: continue
    n, t, mp = int(m.group(1)), m.group(2).strip(), m.group(3).strip()
    you = truth[n]
    unsure = "?" in you
    t_ok, m_ok = kind(t) == kind(you), kind(mp) == kind(you)
    if not unsure:
        scored += 1
        tool_ok += t_ok
        map_ok += m_ok
    mark = (lambda ok: "(?)" if unsure else ("ok" if ok else "WRONG"))
    print("%-4d %-14s %-28s %-6s %-30s %s" % (n, you, t, mark(t_ok), mp, mark(m_ok)))
print("\nkind right, of the %d you were sure about: tool %d, map %d" % (scored, tool_ok, map_ok))
if toolMain and mainOf:
    print("main road right, of the %d you named: %d" % (len(mainOf), sum(mainRight(n) for n in mainOf)))
    for n in sorted(mainOf):
        print("  j%d  you: %s   tool: %s   %s" % (n, "/".join(str(v) for v in mainOf[n]),
              ", ".join("%d/%d" % p for p in toolMain.get(n, [])) or "none", "ok" if mainRight(n) else "WRONG"))
