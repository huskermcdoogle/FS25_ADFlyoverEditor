# Copy ONE tool's entry (default: road runs) from tools/make_help.py into scripts/editor/Help.lua and docs/manual.md.
# make_help.py is behind hand edits made to the other tools' help for 1.0.2.2, so running it whole would
# undo those; this splices one tool's block and leaves everything else as it is.
#   python tools/road-runs/sync_help.py ["spline"]
import os, sys, importlib.util

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
spec = importlib.util.spec_from_file_location("make_help", os.path.join(ROOT, "tools", "make_help.py"))
mh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mh)

KEY = sys.argv[1] if len(sys.argv) > 1 else "road runs"
_keys = [t["key"] for t in mh.TOOLS]
_names = {t["key"]: t["name"] for t in mh.TOOLS}
NEXT_KEY = _keys[_keys.index(KEY) + 1]
NAME, NEXT_NAME = _names[KEY], _names[NEXT_KEY]


def lua_block(text):
    i = text.index('T["%s"] = {' % KEY)
    j = text.index('T["%s"] = {' % NEXT_KEY)
    return i, j


def md_block(lines):
    s = [k for k, l in enumerate(lines) if l.startswith("#") and NAME in l][0]
    e = [k for k, l in enumerate(lines) if k > s and l.startswith("#") and NEXT_NAME in l][0]
    return s, e


gen_lua = mh.emit_lua()
gi, gj = lua_block(gen_lua)
path = os.path.join(ROOT, "scripts", "editor", "Help.lua")
cur = open(path, encoding="utf-8").read()
ci, cj = lua_block(cur)
open(path, "w", encoding="utf-8", newline="\n").write(cur[:ci] + gen_lua[gi:gj] + cur[cj:])

gen_md = mh.emit_md().split("\n")
gs, ge = md_block(gen_md)
path = os.path.join(ROOT, "docs", "manual.md")
cur = open(path, encoding="utf-8").read().split("\n")
cs, ce = md_block(cur)
cur[cs:ce] = gen_md[gs:ge]
open(path, "w", encoding="utf-8", newline="\n").write("\n".join(cur))
print(KEY + " help synced")
