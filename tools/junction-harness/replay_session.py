# REPLAY A GAME SESSION: read the game's log.txt, find every junction clear in it (where it was
# locked, which through-road mode, what it took, what the check said), replay each one offline on the
# network the game had at that moment, and say whether offline matches the game.
#   python replay_session.py <log.txt> [--net <network>] [--since "2026-10-02 14:00"] [--out report.txt]
# The network for a clear is its own debug capture's pre.xml when the log names one (exact), else
# --net: a .lua the harness reads, or an AutoDrive_config.xml / route .xml (converted here). A clear
# that followed another clear without an undo, and has no capture, is marked "not in order": it is
# replayed on --net as if alone. Junction names come from a private copy of REG (savegame6's
# ADFlyoverEditor_junctions.xml by default), so split parts read as in game. FE_SRC passes through.
import hashlib, os, re, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

LUA = os.environ.get("LUA", r"C:/Program Files (x86)/Lua/5.1/lua.exe")
HERE = os.path.dirname(os.path.abspath(__file__))
REG = os.environ.get("REG", os.path.expanduser(
    "~/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6/ADFlyoverEditor_junctions.xml"))

a = sys.argv[1:]
if not a:
    sys.exit(__doc__ if __doc__ else "usage: python replay_session.py <log.txt> [--net N] [--since T] [--out F]")
logf = a.pop(0)
def opt(name, default=None):
    if name in a:
        i = a.index(name); v = a[i + 1]; del a[i:i + 2]; return v
    return default
net, since, outf = opt("--net"), opt("--since", ""), opt("--out")

TS = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)")
clears, cur, leave, leave_known, last_clear_open = [], None, 1, False, False
for line in open(logf, encoding="utf8", errors="replace"):
    m = TS.match(line); ts = m.group(1) if m else ""
    if since and ts and ts < since:
        continue
    if "junction clear will leave through paths in place" in line:
        leave, leave_known = 1, True
    elif "junction clear will clear through paths too" in line:
        leave, leave_known = 0, True
    m = re.search(r"junction site locked at (-?[\d.]+), (-?[\d.]+)(?: \(([^)]*)\))? - .*mode (clear|build)", line)
    if m:
        cur = None
        if m.group(4) == "clear":
            tr = re.search(r"turn radius (\d+(?:\.\d+)?) m", line)
            cur = dict(ts=ts, x=m.group(1), z=m.group(2), name=m.group(3) or "unnumbered", leave=leave,
                       turnr=tr.group(1) if tr else None,
                       leave_known=leave_known, cap=None, took=None, summary=None, lines=[],
                       after_open=last_clear_open)
        continue
    if cur is None:
        if "undid 'clear junction'" in line:
            last_clear_open = False
        continue
    m = re.search(r"debug capture \d+ - recording this clear into (.+?)/?\s*$", line)
    if m:
        cur["cap"] = m.group(1).strip()
    m = re.search(r"took (\d+) point\(s\) in all, the farthest (\d+) m", line)
    if m:
        cur["took"] = (int(m.group(1)), int(m.group(2)))
    m = re.search(r"junction - check after the clear(?: \([^)]*\))?: (.*)$", line)
    if m:
        cur["summary"] = m.group(1).strip(); clears.append(cur); last_clear_open = True
    m = re.search(r"junction - check(: | \(note\): )(.*)$", line)
    if m and cur["summary"] is not None:
        cur["lines"].append(("check" + m.group(1) + m.group(2)).strip())
    if "undid 'clear junction'" in line:
        last_clear_open = False

tmp = tempfile.mkdtemp()
os.makedirs(os.path.join(tmp, "reg")); shutil.copy(REG, os.path.join(tmp, "reg", "ADFlyoverEditor_junctions.xml"))
converted = {}
def to_lua(path):
    if path.endswith(".lua"):
        return path
    if path in converted:
        return converted[path]
    out = os.path.join(tmp, "net_%s.lua" % hashlib.md5(path.encode()).hexdigest()[:10])
    tool = "export_graph.py" if os.path.basename(path).lower().startswith("autodrive_config") else "export_route.py"
    subprocess.run([sys.executable, tool, path, out], cwd=HERE, capture_output=True)
    converted[path] = out
    return out

def capture_leave(cap):
    try:
        for l in open(os.path.join(cap, "meta.txt"), encoding="utf8", errors="replace"):
            v = re.match(r"^leave through paths\s+(\S+)", l)
            if v:
                return 1 if v.group(1) == "on" else 0
    except OSError:
        pass
    return None

def replay(k, c):
    note = []
    graph = None
    if c["cap"] and os.path.exists(os.path.join(c["cap"], "pre.xml")):
        graph = to_lua(os.path.join(c["cap"], "pre.xml"))
        cl = capture_leave(c["cap"])
        if cl is not None:
            c["leave"] = cl; c["leave_known"] = True
    elif net:
        graph = to_lua(net)
        if c["after_open"]:
            note.append("not in order: an earlier clear was not undone and there is no capture")
    else:
        return dict(c, off=None, note=["no capture and no --net: not replayed"])
    if not c["leave_known"]:
        note.append("mode assumed (no toggle line before it)")
    d = os.path.join(tmp, "r%03d" % k); shutil.copytree(os.path.join(tmp, "reg"), d)
    env = dict(os.environ, GRAPH=graph, REGDIR=d, LEAVE=str(c["leave"]), ALL="1",
               RIG_TRAILER=os.environ.get("RIG_TRAILER", "11"))
    # The game's settings: this clear's own capture, else the session's first capture (settings rarely
    # change within a session), and the card's turn radius from the lock line.
    meta = os.path.join(c["cap"], "meta.txt") if c["cap"] else first_meta
    if meta and os.path.exists(meta):
        env["ADOPT"] = meta
    else:
        note.append("harness default settings (no capture in this session)")
    if c.get("turnr"):
        env["TURNR"] = c["turnr"]
    r = subprocess.run([LUA, "dbgcheck.lua", c["x"], c["z"]], cwd=HERE, env=env, capture_output=True,
                       text=True, errors="replace")
    o = r.stdout + r.stderr
    t = re.search(r"took (\d+) point\(s\) in all, the farthest (\d+) m", o)
    s = re.search(r"junction - check after the clear(?: \([^)]*\))?: (.*)$", o, re.M)
    lines = [("check" + m.group(1) + m.group(2)).strip()
             for m in re.finditer(r"junction - check(: | \(note\): )(.*)$", o, re.M)]
    errs = len(re.findall(r"attempt to|stack traceback", o))
    return dict(c, off=dict(took=(int(t.group(1)), int(t.group(2))) if t else None,
                            summary=s.group(1).strip() if s else None, lines=lines, errs=errs,
                            refused=re.search(r"^REFUSED: (.*)$", o, re.M) is not None), note=note)

first_meta = next((os.path.join(c["cap"], "meta.txt") for c in clears if c["cap"]), None)
# Convert every network once, before the replays run side by side (two replays converting the same
# file at once read it half-written).
for c in clears:
    if c["cap"] and os.path.exists(os.path.join(c["cap"], "pre.xml")):
        to_lua(os.path.join(c["cap"], "pre.xml"))
if net:
    to_lua(net)
with ThreadPoolExecutor(max_workers=int(os.environ.get("PAR", "16"))) as ex:
    res = list(ex.map(lambda kc: replay(*kc), enumerate(clears)))
shutil.rmtree(tmp, ignore_errors=True)

out, nmatch, nclose = [], 0, [0]
out.append("Replayed %d clear(s) from %s%s" % (len(res), logf, (" since " + since) if since else ""))
out.append("")
for r in res:
    mode = "through roads kept" if r["leave"] == 1 else "through roads off"
    head = "%s  %s at (%s, %s), %s" % (r["ts"], r["name"], r["x"], r["z"], mode)
    o = r["off"]
    if o is None:
        out.append(head + "  -> NOT REPLAYED (" + "; ".join(r["note"]) + ")"); out.append(""); continue
    same_took = o["took"] == r["took"]
    same_sum = o["summary"] == r["summary"]
    same_lines = sorted(o["lines"]) == sorted(r["lines"])
    ok = same_took and same_sum and same_lines and not o["errs"]
    # CLOSE: the same check findings (notes aside) and points taken within 3 - what a network that is
    # not exactly the game's (no capture for this clear, positions rounded to 1 cm) gives.
    def findings(ls): return sorted(l for l in ls if not l.startswith("check (note)"))
    def counts(sm): return re.sub(r"; \d+ notes?\.?$|\.$", "", sm or "")
    close = (not ok and o["took"] and r["took"] and abs(o["took"][0] - r["took"][0]) <= 3
             and findings(o["lines"]) == findings(r["lines"]) and counts(o["summary"]) == counts(r["summary"])
             and not o["errs"])
    nmatch += ok
    nclose[0] += bool(close)
    out.append(head + ("  -> MATCH" if ok else ("  -> CLOSE" if close else "  -> DIFFERS")))
    if r["note"]:
        out.append("    note: " + "; ".join(r["note"]))
    out.append("    game:    took %s | %s" % ("%d, farthest %d m" % r["took"] if r["took"] else "?", r["summary"]))
    if not ok:
        out.append("    offline: took %s | %s" % ("%d, farthest %d m" % o["took"] if o["took"] else ("refused" if o["refused"] else "?"), o["summary"]))
        for l in sorted(set(r["lines"]) - set(o["lines"])):
            out.append("      only in game:    " + l)
        for l in sorted(set(o["lines"]) - set(r["lines"])):
            out.append("      only offline:    " + l)
        if o["errs"]:
            out.append("      offline Lua errors: %d" % o["errs"])
    else:
        for l in r["lines"]:
            out.append("      " + l)
    out.append("")
out.append("%d of %d clears replay exactly as in game; %d more give the same check findings with points taken within 3 (CLOSE)." % (nmatch, len(res), nclose[0]))
text = "\n".join(out)
if outf:
    open(outf, "w", encoding="utf8").write(text + "\n")
print(text)
