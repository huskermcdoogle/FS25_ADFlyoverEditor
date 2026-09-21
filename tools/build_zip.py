#!/usr/bin/env python3
"""Package the mod: stamp the build number, zip what ships, and check it is complete.

    python tools/build_zip.py [output.zip]              a dev build
    python tools/build_zip.py --release [output.zip]    a build meant to be published

Three things it will not let you get wrong.

STAMPED FIRST. P.BUILD is written from modDesc's version plus the commit, so the number on the card
and in every debug capture names the code inside this zip and not whatever was there last time.

BUILT FROM THE REPOSITORY, not from whatever zip happens to be installed. Taking the file list from
the installed mod is how a build nearly shipped without SweptPath.lua and SweptSim.lua: they were
absent from an older zip, Prelude sources them, and the mod would have died at load.

CHECKED. Every file Prelude sources must be in the archive, and every path must use forward slashes
- Compress-Archive writes backslashes and the game will not read those.

AND, FOR A RELEASE, LABELLED HONESTLY. The zip carries no listing metadata: whatever modDesc says is
what FS25 shows someone who installs it. Publish a zip still holding a development number and the
mod page says one thing while the game says another - which is how this mod came to have a published
history (1.0.0.0, then 3.0.2.0) that appears nowhere in the repository at all. --release refuses to
package unless modDesc holds four single digits and a git tag of the same name exists, so the number
in the zip, the tag, the GitHub release and the listing are all the same number.
"""
import re, subprocess, sys, zipfile, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SKIP_DIRS = ("docs/", "tools/", ".github/")
SKIP_FILES = {"LICENSE", "icon_512.png", ".gitignore", "CLAUDE.md"}

def tag_exists(v):
    try:
        subprocess.check_output(["git", "rev-parse", "-q", "--verify", f"refs/tags/v{v}"],
                                cwd=ROOT, stderr=subprocess.DEVNULL)
        return True
    except subprocess.CalledProcessError:
        return False

def main():
    args = [a for a in sys.argv[1:] if a != "--release"]
    is_release = "--release" in sys.argv
    out = pathlib.Path(args[0]) if args else ROOT / "FS25_ADFlyoverEditor.zip"

    if is_release:
        v = re.search(r"<version>\s*([0-9.]+)", (ROOT / "modDesc.xml").read_text(encoding="utf8")).group(1)
        parts = v.split(".")
        if len(parts) != 4 or any((not p.isdigit()) or len(p) != 1 for p in parts):
            sys.exit(f"REFUSED: modDesc version {v} is not four single digits. "
                     f"Set it to the release number before packaging a release.")
        if not tag_exists(v):
            sys.exit(f"REFUSED: no git tag v{v}. Tag the release first, so the repository records "
                     f"what was published - neither 1.0.0.0 nor 3.0.2.0 appears anywhere in it.")
        print(f"release build: modDesc {v}, tag v{v} present")
    print("stamping:")
    subprocess.check_call([sys.executable, str(ROOT / "tools" / "stamp_version.py")])

    tracked = subprocess.check_output(["git", "ls-files"], cwd=ROOT, text=True).split()
    ship = [f for f in tracked
            if not f.startswith(SKIP_DIRS) and not f.endswith(".md") and f not in SKIP_FILES]
    missing = [f for f in ship if not (ROOT / f).exists()]
    if missing:
        sys.exit(f"tracked but not on disk: {missing}")

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for f in ship:
            z.write(ROOT / f, f)

    names = set(zipfile.ZipFile(out).namelist())
    prelude = (ROOT / "scripts" / "Prelude.lua").read_text(encoding="utf8")
    needed = set(re.findall(r'"((?:scripts|textures)/[^"]+\.lua)"', prelude))
    gone = sorted(needed - names)
    if gone:
        sys.exit(f"FAILED: Prelude sources files that are not in the zip: {gone}")
    if any("\\" in n for n in names):
        sys.exit("FAILED: backslash paths in the archive - the game cannot read those")

    version = re.search(r"<version>\s*([0-9.]+)", (ROOT / "modDesc.xml").read_text(encoding="utf8")).group(1)
    build = re.search(r'^P\.BUILD\s*=\s*"([^"]*)"', prelude, re.M).group(1)
    print(f"  {len(names)} files -> {out}")
    print(f"  release {version}   build {build}")
    print(f"  all {len(needed)} sourced file(s) present, forward slashes only")

if __name__ == "__main__":
    main()
