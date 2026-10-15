# ONE FILE HOLDING THE WHOLE EDITOR, for the harness (FE_SRC) and A/B comparisons
# (docs/editor-modules-spec.md). The editor is every file Prelude sources from FlyoverEditor.lua on, in
# Prelude's order (P.EDITOR_FILES) - today FlyoverEditor.lua alone, after the split its modules too.
# Each file goes in its own do ... end block, so its local names end with it, as they do in a file of
# its own: the bundle stays inside Lua's 200-locals limit however many modules there are.
#   python tools/modsplit/bundle.py [--commit C] out.lua      a commit's editor (default: the working tree)
#   python tools/modsplit/bundle.py [--commit C] --list       just the editor's files, in load order
import re, subprocess, sys
from pathlib import Path

ROOT = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                           check=True).stdout.strip())
args = sys.argv[1:]
commit = None
if "--commit" in args:
    i = args.index("--commit"); commit = args[i + 1]; del args[i:i + 2]


def read(path):
    if commit is None:
        return (ROOT / path).read_text(encoding="utf8")
    r = subprocess.run(["git", "show", "%s:%s" % (commit, path)], cwd=ROOT, capture_output=True)
    if r.returncode != 0:
        sys.exit("bundle.py: %s is not in %s" % (path, commit))
    return r.stdout.decode("utf8")


def editor_files():
    prelude = read("scripts/Prelude.lua")
    m = re.search(r"P\.EDITOR_FILES\s*=\s*\{(.*?)\n\}", prelude, re.S)
    if m is None:
        sys.exit("bundle.py: no P.EDITOR_FILES list in Prelude.lua")
    files = re.findall(r'"([^"]+)"', m.group(1))
    if "scripts/editor/FlyoverEditor.lua" not in files:
        sys.exit("bundle.py: FlyoverEditor.lua is not in P.EDITOR_FILES")
    return files[files.index("scripts/editor/FlyoverEditor.lua"):]


files = editor_files()
if args == ["--list"]:
    print("\n".join(files))
    sys.exit(0)
if len(args) != 1:
    sys.exit("usage: python tools/modsplit/bundle.py [--commit C] out.lua | --list")
out = ["-- THE EDITOR IN ONE FILE (tools/modsplit/bundle.py), %s: %d file(s), each in its own block\n"
       % ("commit " + commit if commit else "working tree", len(files))]
for f in files:
    body = read(f).replace("\r\n", "\n")
    if not body.endswith("\n"):
        body += "\n"
    out.append("do -- %s\n%send -- %s\n" % (f, body, f))
Path(args[0]).write_text("".join(out), encoding="utf8", newline="\n")
print("%s: %d file(s)" % (args[0], len(files)))
