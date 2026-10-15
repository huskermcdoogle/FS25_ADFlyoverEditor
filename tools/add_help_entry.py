# Add ONE new tool's entry from tools/make_help.py to scripts/editor/Help.lua and docs/manual.md, before
# the entry that follows it in make_help's order, and refresh Help.lua's ORDER line. make_help.py is
# behind hand edits to other tools' help, so running it whole would undo those (see road-runs/sync_help.py).
#   python tools/add_help_entry.py junction
import os, sys, re, importlib.util

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("make_help", os.path.join(ROOT, "tools", "make_help.py"))
mh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mh)
KEY = sys.argv[1]
keys = [t["key"] for t in mh.TOOLS]
names = {t["key"]: t["name"] for t in mh.TOOLS}
nxt = keys[keys.index(KEY) + 1]

gen = mh.emit_lua()
i = gen.index('T["%s"] = {' % KEY)
j = gen.index('T["%s"] = {' % nxt)
path = os.path.join(ROOT, "scripts", "editor", "Help.lua")
cur = open(path, encoding="utf-8").read()
assert 'T["%s"] = {' % KEY not in cur, "already there - edit it with a sync instead"
k = cur.index('T["%s"] = {' % nxt)
cur = cur[:k] + gen[i:j] + cur[k:]
order = re.search(r"^ADFlyoverHelp\.ORDER = .*$", gen, re.M).group(0)
cur = re.sub(r"^ADFlyoverHelp\.ORDER = .*$", lambda m: order, cur, count=1, flags=re.M)
open(path, "w", encoding="utf-8", newline="\n").write(cur)

md = mh.emit_md().split("\n")
s = [n for n, l in enumerate(md) if l.startswith("## ") and l[3:].strip() == names[KEY]][0]
e = [n for n, l in enumerate(md) if n > s and l.startswith("## ")][0]
path = os.path.join(ROOT, "docs", "manual.md")
cur = open(path, encoding="utf-8").read().split("\n")
k = [n for n, l in enumerate(cur) if l.startswith("## ") and l[3:].strip() == names[nxt]][0]
cur[k:k] = md[s:e]
# the contents line, if the generated one names it
gc = [l for l in md if ("(#" in l and names[KEY].split(" ")[0].lower() in l.lower())]
open(path, "w", encoding="utf-8", newline="\n").write("\n".join(cur))
print("added", KEY, "before", nxt, "| contents line to check by hand:", gc[:1])
