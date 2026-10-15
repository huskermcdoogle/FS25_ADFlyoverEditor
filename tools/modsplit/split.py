# THE EDITOR SPLIT, ONE MODULE AT A TIME (docs/editor-modules-spec.md).
#   python tools/modsplit/split.py plan              every module still in FlyoverEditor.lua: its lines, the
#                                                    helpers it needs from above it, the helpers files below
#                                                    it need from it, and what blocks moving it
#   python tools/modsplit/split.py move [--dry-run]  move the LAST module still in FlyoverEditor.lua out to
#                                                    its own file (modules.txt), and list it in Prelude
#
# Moving from the last module backwards keeps every step valid: Lua code can only use a local helper
# declared above it, so what stays in FlyoverEditor.lua (the top of the old file) never needs anything
# from a moved module, and each moved file loads after it, in the old order. A helper declared above a
# module and used in it is shared: the file that declares it publishes it on ADFlyoverEditor.shared at
# its end (the MODSPLIT shared block), and the module takes a local alias at its top (the MODSPLIT
# helpers block), so no call site changes. A helper that is ASSIGNED again after its declaration cannot
# be shared that way - an alias would keep the old value - so it blocks the move until it is made a
# table field (phase 1). The five do ... end blocks that kept the one file under Lua's 200-local limit
# are unwrapped where a module boundary cuts them, or when a module holding one whole moves out: a file
# of its own has its own 200.
import re, subprocess, sys
from pathlib import Path

ROOT = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                           check=True).stdout.strip())
FE = ROOT / "scripts/editor/FlyoverEditor.lua"
PRELUDE = ROOT / "scripts/Prelude.lua"
HERE = Path(__file__).resolve().parent
SHARED = "ADFlyoverEditor.shared"
PUB_OPEN = "-- MODSPLIT: SHARED WITH THE FILES LOADED AFTER THIS ONE (tools/modsplit/split.py writes this block)"
PUB_CLOSE = "-- MODSPLIT: end of the shared block"
ALI_OPEN = "-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)"
ALI_CLOSE = "-- MODSPLIT: end of the helpers"
DO_OPEN = ["-- ONE FILE MAY HOLD ONLY 200 LOCAL NAMES AT ONCE (Lua 5.1). The local helpers from here to the",
           "-- matching \"end\" are used nowhere after it, so they are scoped to this block and free their slots.",
           "do"]
DO_CLOSE = "end -- the block of local helpers opened above (Lua 5.1's 200-local limit)"


def read_lines(p):
    t = p.read_text(encoding="utf8")
    return t.replace("\r\n", "\n").split("\n"), ("\r\n" in t)


def write_lines(p, lines, crlf):
    t = "\n".join(lines)
    if crlf:
        t = t.replace("\n", "\r\n")
    p.write_text(t, encoding="utf8", newline="")


# ------------------------------------------------------------------ code without comments and strings
def strip_code(lines):
    """Each line's code with comments removed and string contents blanked, so identifiers can be read."""
    out, in_long, long_eq, long_is_comment = [], False, "", False
    for line in lines:
        res, i, n = [], 0, len(line)
        while i < n:
            if in_long:
                close = "]" + long_eq + "]"
                j = line.find(close, i)
                if j < 0:
                    i = n
                    break
                if not long_is_comment:
                    res.append('""')
                i = j + len(close)
                in_long = False
                continue
            c = line[i]
            if line.startswith("--", i):
                m = re.match(r"--\[(=*)\[", line[i:])
                if m:
                    in_long, long_eq, long_is_comment = True, m.group(1), True
                    i += len(m.group(0))
                    continue
                break  # line comment
            m = re.match(r"\[(=*)\[", line[i:])
            if m:
                in_long, long_eq, long_is_comment = True, m.group(1), False
                i += len(m.group(0))
                continue
            if c in "\"'":
                j = i + 1
                while j < n and line[j] != c:
                    j += 2 if line[j] == "\\" else 1
                res.append('""')
                i = j + 1
                continue
            res.append(c)
            i += 1
        out.append("".join(res))
    return out


IDENT = re.compile(r"(?<![\w.:])([A-Za-z_]\w*)")
KEYWORDS = set("and break do else elseif end false for function if in local nil not or repeat return then "
               "true until while goto self".split())


def file_level_locals(lines, code):
    """(index, name) of every local declared at column 0 (file level, or a do ... end block's level)."""
    out = []
    for i, l in enumerate(lines):
        m = re.match(r"^local function ([A-Za-z_]\w*)", l)
        if m:
            out.append((i, m.group(1)))
            continue
        m = re.match(r"^local ([A-Za-z_][\w, ]*?)\s*(=|$)", code[i])
        if m:
            for n in m.group(1).split(","):
                out.append((i, n.strip()))
    return out


def uses(code, a, b):
    """Every identifier read or written in code[a:b] (not a field or method name)."""
    s = set()
    for l in code[a:b]:
        for m in IDENT.finditer(l):
            if m.group(1) not in KEYWORDS:
                s.add(m.group(1))
    return s


def reassigned(code, name, decl_i, a, b):
    """Lines in code[a:b] (other than the declaration) that assign the local `name` again."""
    pat = re.compile(r"(?:^|[^\w.:])" + re.escape(name) + r"\s*(?:,\s*[\w.\[\]]+\s*)*=(?!=)")
    fn = re.compile(r"^\s*function\s+" + re.escape(name) + r"\s*\(")
    hits = []
    for i in range(a, b):
        if i == decl_i:
            continue
        l = code[i]
        if l.lstrip().startswith("local "):
            continue
        if pat.search(l) or fn.search(l):
            hits.append(i)
    return hits


# ------------------------------------------------------------------ modules and their ranges
def modules():
    mods = []
    for l in (HERE / "modules.txt").read_text(encoding="utf8").split("\n"):
        if not l.strip() or l.startswith("#"):
            continue
        rx, target = l.rsplit(None, 1)
        mods.append((re.compile(rx.strip()), target))
    return mods


def comment_top(lines, i):
    while i > 0 and lines[i - 1].lstrip().startswith("--") and not lines[i - 1].startswith(DO_OPEN[0][:20]):
        i -= 1
    return i


def ranges(lines):
    """The modules still in FlyoverEditor.lua: [(start, end, target)], in file order; start of the first
    is where the core ends."""
    found = []
    for rx, target in modules():
        hit = [i for i, l in enumerate(lines) if rx.search(l)]
        if len(hit) > 1:
            sys.exit("modules.txt: %s matches %d lines in FlyoverEditor.lua" % (rx.pattern, len(hit)))
        if hit:
            found.append((comment_top(lines, hit[0]), target))
    found.sort()
    end = pub_block(lines)[0] if pub_block(lines) else len(lines)
    out = []
    for k, (s, t) in enumerate(found):
        e = found[k + 1][0] if k + 1 < len(found) else end
        out.append((s, e, t))
    return out


def pub_block(lines):
    if PUB_OPEN in lines:
        a = lines.index(PUB_OPEN)
        b = lines.index(PUB_CLOSE)
        return a, b + 1
    return None


def published(lines):
    pb = pub_block(lines)
    if not pb:
        return []
    return [re.match(r"^" + re.escape(SHARED) + r"\.(\w+) = ", l).group(1) for l in lines[pb[0]:pb[1]]
            if l.startswith(SHARED + ".") and " = " in l and not l.startswith(SHARED + " =")]


def do_blocks(lines):
    """(open index of the 'do' comment's first line, close index) for each of the five blocks."""
    opens = [i for i in range(len(lines) - 2) if lines[i:i + 3] == DO_OPEN]
    closes = [i for i, l in enumerate(lines) if l == DO_CLOSE]
    if len(opens) != len(closes):
        sys.exit("FlyoverEditor.lua: %d do-block openers but %d closers" % (len(opens), len(closes)))
    return list(zip(opens, closes))


# ------------------------------------------------------------------ plan
def analyse(lines):
    code = strip_code(lines)
    decl = file_level_locals(lines, code)
    rs = ranges(lines)
    core_end = rs[0][0] if rs else len(lines)
    info = []
    for k, (s, e, t) in enumerate(rs):
        mine = {n for i, n in decl if s <= i < e}
        # helpers in scope at the module's start: declared above it, and not inside a do ... end block
        # that closed above it (those are out of scope there; the same name means something else)
        closed = [(o, c) for o, c in do_blocks(lines) if c < s]
        above = {}
        for i, n in decl:
            if i < s and not any(o < i < c for o, c in closed):
                above[n] = i  # the last declaration above wins, as in Lua
        used = uses(code, s, e)
        needs = sorted(n for n in used if n in above and n not in mine)
        block = []
        for n in needs:
            hits = reassigned(code, n, above[n], 0, len(code))
            if hits:
                block.append("%s (declared line %d, assigned again at line %s)" % (n, above[n] + 1, ", ".join(str(h + 1) for h in hits[:4])))
        info.append(dict(s=s, e=e, target=t, needs=needs, block=block, mine=mine))
    return info, core_end


def cmd_plan():
    lines, _ = read_lines(FE)
    info, core_end = analyse(lines)
    pub = published(lines)
    print("FlyoverEditor.lua: %d lines; the core is lines 1-%d; %d module(s) still in it; shared now: %d helper(s)"
          % (len(lines), core_end, len(info), len(pub)))
    for k, m in enumerate(info):
        later = sorted(set().union(*[set(x["needs"]) for x in info[k + 1:]]) & m["mine"]) if k + 1 < len(info) else []
        moved_need = sorted(set(pub) & m["mine"])
        print("\n%s%s: lines %d-%d (%d)" % ("NEXT " if k == len(info) - 1 else "", m["target"], m["s"] + 1, m["e"], m["e"] - m["s"]))
        print("  needs from above (%d): %s" % (len(m["needs"]), " ".join(m["needs"])))
        if later or moved_need:
            print("  gives to modules below (%d): %s" % (len(set(later) | set(moved_need)), " ".join(sorted(set(later) | set(moved_need)))))
        for b in m["block"]:
            print("  BLOCKS THE MOVE: %s" % b)


# ------------------------------------------------------------------ move
def cmd_move(dry):
    lines, crlf = read_lines(FE)
    info, _ = analyse(lines)
    if not info:
        sys.exit("nothing left to move")
    m = info[-1]
    s, e, target = m["s"], m["e"], m["target"]
    if m["block"]:
        sys.exit("STOP: %s cannot move yet:\n  " % target + "\n  ".join(m["block"]))
    out_path = ROOT / target
    if out_path.exists():
        sys.exit("STOP: %s already exists" % target)
    pub = published(lines)
    pb = pub_block(lines)
    # 1. the do ... end blocks the cut goes through, or that move whole: unwrapped (both ends)
    drop = set()
    for o, c in do_blocks(lines):
        if c >= s:
            drop.update(range(o, o + 3))
            drop.add(c)
            if c + 1 < len(lines) and lines[c + 1] == "":
                drop.add(c + 1)
    # 2. the module's own lines, and what it must publish for the modules already moved below it
    body = [lines[i] for i in range(s, e) if i not in drop]
    while body and body[-1] == "":
        body.pop()
    gives = sorted(set(pub) & m["mine"])
    needs = m["needs"]
    head = ["-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua",
            "-- loads it after FlyoverEditor.lua, in the old file's order."]
    if needs:
        head += [ALI_OPEN,
                 "for _, name in ipairs({ %s }) do" % ", ".join('"%s"' % n for n in needs),
                 "    if %s == nil or %s[name] == nil then" % (SHARED, SHARED),
                 "        Logging.error(\"[FlyoverEditor]: %s needs %%s, which no file loaded before it shares\", name)" % target.split("/")[-1],
                 "    end",
                 "end"]
        head += ["local %s = %s.%s" % (n, SHARED, n) for n in needs]
        head += [ALI_CLOSE]
    head += [""]
    tail = []
    if gives:
        tail = ["", PUB_OPEN] + ["%s.%s = %s" % (SHARED, n, n) for n in gives] + [PUB_CLOSE]
    new_file = head + body + tail + [""]
    # 3. what stays: the lines above the module, the blocks unwrapped, and the shared block rewritten:
    #    what the moved module took with it is no longer this file's to share; what it needs is
    keep = [lines[i] for i in range(0, s) if i not in drop]
    while keep and keep[-1] == "":
        keep.pop()
    still = sorted((set(pub) - m["mine"]) | set(needs))
    if still:
        keep += ["", PUB_OPEN, "%s = %s or {}" % (SHARED, SHARED)] + ["%s.%s = %s" % (SHARED, n, n) for n in still] + [PUB_CLOSE]
    keep += [""]
    # 4. Prelude: the new file right after FlyoverEditor.lua (it comes before every file moved earlier)
    pl, pcrlf = read_lines(PRELUDE)
    k = [i for i, l in enumerate(pl) if l.strip() == '"scripts/editor/FlyoverEditor.lua",']
    if len(k) != 1:
        sys.exit("STOP: Prelude.lua: FlyoverEditor.lua is listed %d times" % len(k))
    ind = pl[k[0]][:len(pl[k[0]]) - len(pl[k[0]].lstrip())]
    pl.insert(k[0] + 1, '%s"%s",' % (ind, target))
    print("%s: lines %d-%d of FlyoverEditor.lua (%d lines; %d do-block line(s) dropped)" % (target, s + 1, e, e - s, len(drop)))
    print("  takes %d helper(s) from above: %s" % (len(needs), " ".join(needs)))
    print("  shares %d helper(s) with the files below it: %s" % (len(gives), " ".join(gives)))
    print("  FlyoverEditor.lua: %d -> %d lines; it shares %d helper(s)" % (len(lines), len(keep), len(still)))
    if dry:
        print("  (dry run: nothing written)")
        return
    out_path.parent.mkdir(parents=True, exist_ok=True)
    write_lines(out_path, new_file, crlf)
    write_lines(FE, keep, crlf)
    write_lines(PRELUDE, pl, pcrlf)
    subprocess.run(["git", "add", "-N", str(out_path)], cwd=ROOT)
    print("  written; Prelude lists it; git add -N done")


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["plan"]:
        cmd_plan()
    elif a[:1] == ["move"]:
        cmd_move("--dry-run" in a)
    else:
        sys.exit(__doc__ or "usage: split.py plan | move [--dry-run]")
