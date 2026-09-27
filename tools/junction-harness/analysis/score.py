# Score the tool's and the map's junction readings against the user's own (truth_types.txt).
#   python analysis/score.py compare.txt [truth_types.txt]
# "Kind" is T / Y / crossroads; a Y merge counts as a T (a shallow one), "?" answers are shown
# but not scored.
import re, sys

truth = {}
for line in open(sys.argv[2] if len(sys.argv) > 2 else "truth_types.txt", encoding="utf8"):
    line = line.split("#")[0].strip()
    if line:
        n, k = line.split(None, 1)
        truth[int(n)] = k.strip()

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
