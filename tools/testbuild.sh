# ONE-COMMAND TEST BUILD from committed code, never from the working copy:
#   bash tools/testbuild.sh [commit] [--no-launch] [--dry-run]
# 1. checks out <commit> (default HEAD) into a temporary git worktree, so uncommitted experiments in
#    the working copy can never ship;
# 2. builds the zip there with tools/build_zip.py (which stamps the build number);
# 3. checks the zip's editor file is byte-for-byte the commit's;
# 4. refuses to install while FS25 is running (copying the zip under a running game breaks it);
# 5. installs the zip into the mods folder, then launches FS25 through Steam unless --no-launch.
# --dry-run stops after step 3: builds and checks, installs nothing.
set -e
REPO=$(git rev-parse --show-toplevel)
COMMIT=HEAD; LAUNCH=1; DRY=0
for a in "$@"; do case "$a" in --no-launch) LAUNCH=0 ;; --dry-run) DRY=1 ;; *) COMMIT="$a" ;; esac; done
SHA=$(git -C "$REPO" rev-parse --short "$COMMIT")
TMPW=$(mktemp -d)/build-$SHA
MODS="$USERPROFILE/OneDrive/Documents/My Games/FarmingSimulator2025/mods"
[ -d "$MODS" ] || MODS="$USERPROFILE/Documents/My Games/FarmingSimulator2025/mods"
running() { powershell -NoProfile -Command "if (Get-Process FarmingSimulator2025Game -ErrorAction SilentlyContinue) { 'yes' }" | tr -d '\r'; }
if [ $DRY = 0 ] && [ "$(running)" = "yes" ]; then echo "FS25 is running - close it first (never copy the zip under a running game)."; exit 1; fi
git -C "$REPO" worktree add --detach "$TMPW" "$SHA" -q
trap 'git -C "$REPO" worktree remove --force "$TMPW" >/dev/null 2>&1 || true' EXIT
( cd "$TMPW" && python tools/build_zip.py "$TMPW/FS25_ADFlyoverEditor.zip" ) | tail -2
python - "$TMPW" <<'PY'
import sys, zipfile, subprocess
w = sys.argv[1]
z = zipfile.ZipFile(w + "/FS25_ADFlyoverEditor.zip")
# every editor file (FlyoverEditor.lua and, once it is split, its modules - docs/editor-modules-spec.md)
names = [n for n in z.namelist() if n.startswith("scripts/editor/") and n.endswith(".lua")]
for n in names:
    a = z.read(n).replace(b"\r\n", b"\n")
    b = subprocess.run(["git", "-C", w, "show", "HEAD:" + n], capture_output=True).stdout.replace(b"\r\n", b"\n")
    if a != b:
        print("STOP: the zip's %s is not the commit's" % n); sys.exit(1)
print("zip checked: all %d editor files are the commit's, byte for byte" % len(names))
PY
if [ $DRY = 1 ]; then echo "dry run: built and checked, nothing installed"; exit 0; fi
if [ "$(running)" = "yes" ]; then echo "FS25 started meanwhile - not installing."; exit 1; fi
cp "$TMPW/FS25_ADFlyoverEditor.zip" "$MODS/FS25_ADFlyoverEditor.zip"
echo "installed build of $SHA into $MODS"
if [ $LAUNCH = 1 ]; then powershell -NoProfile -Command "Start-Process 'steam://rungameid/2300320'"; echo "launched FS25"; fi
