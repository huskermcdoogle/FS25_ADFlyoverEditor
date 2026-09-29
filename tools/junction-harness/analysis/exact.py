# Exact T / Y merge labels against the user's answers: how many of the answers the user was SURE of
# (no "?") get the same label - T square, T skew or Y merge - from the tool's branch angle.
#   python analysis/exact.py <tooltypes.txt from dbgtypes.lua> [truth_types.txt] [square_line] [ymerge_line]
# Lines default to the tool's own: over 62 T square, over 38 T skew, else Y merge. Junctions 71+ (cleared,
# set aside by the user) are left out. Prints the score, then every disagreement.
import re, sys

tt = sys.argv[1]
truth_path = sys.argv[2] if len(sys.argv) > 2 else "truth_types.txt"
SQ = float(sys.argv[3]) if len(sys.argv) > 3 else 62
YM = float(sys.argv[4]) if len(sys.argv) > 4 else 38

truth = {}
for line in open(truth_path, encoding="utf8"):
    body = line.split("#")[0].strip()
    if re.match(r"^\d+\s", body):
        n, k = body.split(None, 1)
        truth[int(n)] = re.sub(r"\s*main=\S+", "", k).strip()

rows = []
for line in open(tt, encoding="utf8"):
    m = re.match(r"(\d+) .*\| branch (\d+)", line)
    if not m:
        continue
    n, a = int(m.group(1)), int(m.group(2))
    t = truth.get(n, "")
    if n < 71 and t in ("T square", "T skew", "Y merge"):
        rows.append((a, n, t))

def label(a):
    return "T square" if a > SQ else ("T skew" if a > YM else "Y merge")

right = sum(1 for a, n, t in rows if label(a) == t)
print("exact label right on %d of %d sure T / Y merge answers (lines %g / %g)" % (right, len(rows), SQ, YM))
for a, n, t in sorted(rows):
    if label(a) != t:
        print("  j%d: %d deg -> %s, user %s" % (n, a, label(a), t))
