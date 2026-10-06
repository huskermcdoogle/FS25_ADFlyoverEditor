# PHASE 1 OF THE EDITOR SPLIT (docs/editor-modules-spec.md): the junction state that is assigned again
# after its declaration becomes fields of one table, jxState, under the same names - an alias in another
# file would keep the old value. Only code changes: comments and strings keep the old names, and a name
# read as a field (x.jxStage) or a method is left alone. Each `local` declaration line becomes an
# assignment to the table, in the same place, so everything runs in the same order.
#   python tools/modsplit/phase1.py [--dry-run]
import re, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from split import FE, read_lines, write_lines  # noqa: E402

NAMES = ["jxJournal", "jxStage", "jxKeptRoad", "jxTwinKeep", "jxTwinHeld", "jxWhy", "jxWasLoose", "jxCut",
         "jxExisted", "jxInRespace", "jxRespaceRun", "jxBuildNew", "jxCentreNode", "jxLayLabel", "jxLinkLabel",
         "jxNodeLabel", "jxLaySeq", "jxShallowJoins", "jxSquaredJoins"]
TABLE = "jxState"
HEAD = ["-- THE JUNCTION TOOL'S STATE THAT IS ASSIGNED AGAIN AFTER ITS DECLARATION (docs/editor-modules-spec.md,",
        "-- phase 1). These were file-level locals. Once the editor is split into modules, a file can't assign",
        "-- another file's local, and an alias would keep the old value, so each is a field of this one table,",
        "-- under its old name.",
        "local %s = {}" % TABLE]
NAME_RX = re.compile(r"(?<![\w.:])(" + "|".join(NAMES) + r")(?!\w)")


def code_spans(lines):
    """For each line, the (start, end) spans that are code: not inside a comment or a string."""
    out, in_long, long_eq, long_is_comment = [], False, "", False
    for line in lines:
        spans, i, n, start = [], 0, len(line), 0
        while i < n:
            if in_long:
                close = "]" + long_eq + "]"
                j = line.find(close, i)
                if j < 0:
                    i = n
                    start = n
                    break
                i = j + len(close)
                in_long = False
                start = i
                continue
            c = line[i]
            if line.startswith("--", i):
                spans.append((start, i))
                m = re.match(r"--\[(=*)\[", line[i:])
                if m:
                    in_long, long_eq, long_is_comment = True, m.group(1), True
                    i += len(m.group(0))
                    continue
                start = n
                i = n
                break
            m = re.match(r"\[(=*)\[", line[i:])
            if m:
                spans.append((start, i))
                in_long, long_eq, long_is_comment = True, m.group(1), False
                i += len(m.group(0))
                continue
            if c in "\"'":
                spans.append((start, i))
                j = i + 1
                while j < n and line[j] != c:
                    j += 2 if line[j] == "\\" else 1
                i = j + 1
                start = i
                continue
            i += 1
        if not in_long and start < n:
            spans.append((start, n))
        out.append([(a, b) for a, b in spans if b > a])
    return out


def main(dry):
    lines, crlf = read_lines(FE)
    spans = code_spans(lines)
    decl = [i for i, l in enumerate(lines) if re.match(r"^local ", l) and NAME_RX.search(l)]
    count = 0
    for i, l in enumerate(lines):
        if not spans[i]:
            continue
        out, pos = [], 0
        for a, b in spans[i]:
            out.append(l[pos:a])
            seg, k = NAME_RX.subn(TABLE + r".\1", l[a:b])
            count += k
            out.append(seg)
            pos = b
        out.append(l[pos:])
        lines[i] = "".join(out)
    for i in decl:
        names = re.match(r"^local ([\w., ]+?)\s*(=|$)", lines[i]).group(1)
        if any(not x.strip().startswith(TABLE + ".") for x in names.split(",")):
            sys.exit("STOP: line %d declares state and something else: %s" % (i + 1, lines[i]))
        if "=" not in lines[i].split("--")[0]:
            sys.exit("STOP: line %d declares without a value: %s" % (i + 1, lines[i]))
        lines[i] = lines[i][len("local "):]
    first = decl[0]
    lines[first:first] = HEAD
    left = [n for n in NAMES if any(NAME_RX.search(l[a:b]) and not l[a:b].count(TABLE + "." + n)
                                    for l, sp in zip(lines, code_spans(lines)) for a, b in sp)]
    print("%d uses renamed; %d declaration line(s) made assignments; table at line %d" % (count, len(decl), first + 1))
    if dry:
        print("(dry run: nothing written)")
        return
    write_lines(FE, lines, crlf)
    print("written")


if __name__ == "__main__":
    main("--dry-run" in sys.argv[1:])
