#!/usr/bin/env python3
"""Stamp Prelude's P.BUILD from modDesc's version plus this commit.

TWO NUMBERS, ONE OF THEM AUTOMATIC.

modDesc's <version> is the RELEASE number and the only one KingMods sees. It wants four single
digits - 1st major, 2nd new functionality, 3rd and 4th minor and bug fix - so it is bumped by hand
and rarely, and this script never touches it.

P.BUILD is the DEVELOPMENT number: the release, plus how many commits deep this build is, plus the
short SHA.

    1.0.0.0+318.bec85b6

Nobody types it and nobody has to remember to bump it. The commit count only ever goes up, so two
dev builds can be ordered; the SHA names the exact code, which is what turns "it did something odd"
into something reproducible - the version on the card, in the log and in every debug capture points
at one commit.

It also stops development eating release numbers, which is how this mod reached 0.31.77 with two
components over 9 and none of them a release.

    python tools/stamp_version.py            stamp P.BUILD (run before packaging)
    python tools/stamp_version.py --check     report, change nothing; non-zero if it needs stamping
"""
import re, subprocess, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODDESC = ROOT / "modDesc.xml"
PRELUDE = ROOT / "scripts" / "Prelude.lua"

def git(*a):
    return subprocess.check_output(["git", *a], cwd=ROOT, text=True).strip()

def release():
    m = re.search(r"<version>\s*([0-9.]+)\s*</version>", MODDESC.read_text(encoding="utf8"))
    if not m:
        sys.exit("modDesc.xml has no <version>")
    return m.group(1)

def check_release(v):
    """KingMods takes four single digits. Warn rather than fail: a dev build is not a release."""
    parts = v.split(".")
    bad = len(parts) != 4 or any((not p.isdigit()) or len(p) != 1 for p in parts)
    if bad:
        print(f"  note: release {v} is not four single digits - KingMods will not accept it as published")
    return not bad

def wanted():
    return f"{release()}+{git('rev-list', '--count', 'HEAD')}.{git('rev-parse', '--short', 'HEAD')}"

def current():
    m = re.search(r'^P\.BUILD\s*=\s*"([^"]*)"', PRELUDE.read_text(encoding="utf8"), re.M)
    return m.group(1) if m else None

def main():
    want, have = wanted(), current()
    check_release(release())
    if "--check" in sys.argv:
        print(f"  P.BUILD is {have}\n  should be {want}")
        return 0 if have == want else 1
    if have == want:
        print(f"  P.BUILD already {want}")
        return 0
    text = PRELUDE.read_text(encoding="utf8")
    new, n = re.subn(r'^P\.BUILD\s*=\s*"[^"]*"', f'P.BUILD = "{want}"', text, count=1, flags=re.M)
    if n != 1:
        sys.exit("could not find P.BUILD in Prelude.lua")
    PRELUDE.write_text(new, encoding="utf8")
    print(f"  P.BUILD {have} -> {want}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
