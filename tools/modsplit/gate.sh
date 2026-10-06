# THE GATE FOR ONE STEP OF THE EDITOR SPLIT (docs/editor-modules-spec.md): the working tree against a
# commit, on every offline test, and the static checks. Nothing may change: every test's output must be
# the base commit's, byte for byte, and the working tree's clear and check must give the same output
# twice.
#   bash tools/modsplit/gate.sh [--full] [BASE_COMMIT]  (default HEAD; run from anywhere in the repo)
# Quick (the default, one module's move, ~4 min): the static checks, a load check, and the clear, the
# check, the build and place (exact) for the base and the working tree. --full (the end of each phase,
# ~16 min): every test below, the split registry too, and the working tree's clear and check twice.
# Env: GATE_NETS="name=path.lua ..." extra networks for reg75 / reg75check / regtwin (graph_data.lua,
# the harness's default network, always runs); PAR (default 6) parallel junctions inside each test;
# REGBASE the junction file the split registry is made from (default the 2026-10-02 backup before the
# split decisions, else savegame6's own file).
# Prints the static checks, then one line per test output: same / DIFFERS (base vs working tree) and
# STABLE / UNSTABLE (the working tree's two runs of reg75 and reg75check). Exit 0 only if everything is
# same and stable. All outputs stay in tools/modsplit/out/<time>/ (git-ignored).
set -u
ROOT=$(git rev-parse --show-toplevel)
H="$ROOT/tools/junction-harness"
FULL=0
if [ "${1:-}" = "--full" ]; then FULL=1; shift; fi
BASE="${1:-HEAD}"
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
LC="${LUAC:-/c/Program Files (x86)/Lua/5.1/luac.exe}"
GD="$ROOT/tools/modsplit/out/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$GD"
export RIG_TRAILER=11 PAR="${PAR:-6}" LUA="$L"
SG="$HOME/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6"
REGBASE="${REGBASE:-$SG/flyoverBackups/ADFlyoverEditor_junctions.2026-10-02_before-split-decisions.xml}"
[ -f "$REGBASE" ] || REGBASE="$SG/ADFlyoverEditor_junctions.xml"
fail=0

# ------------------------------------------------------------------ both builds, as one file each
# The tests run on these (both sides alike); the load check below loads the working tree's own files,
# the way the game does.
python "$ROOT/tools/modsplit/bundle.py" --commit "$BASE" "$GD/base.lua" > /dev/null || { echo "STOP: could not bundle $BASE"; exit 1; }
python "$ROOT/tools/modsplit/bundle.py" "$GD/cand.lua" > /dev/null || { echo "STOP: could not bundle the working tree"; exit 1; }

# ------------------------------------------------------------------ static checks on the working tree
# (Python on Windows ends lines with CR LF: the CR would end up in every file name but the last)
FILES=$(python "$ROOT/tools/modsplit/bundle.py" --list | tr -d '\r')
echo "== static checks (working tree: $(echo "$FILES" | wc -l) editor file(s); base: $BASE)"
: > "$GD/globals_cand.txt"
# Every check runs on a copy of the editor's files taken first, so all of them see the same files.
mkdir -p "$GD/src"
for f in $FILES; do
  mkdir -p "$GD/src/$(dirname "$f")"
  cp "$ROOT/$f" "$GD/src/$f" || { echo "FAIL could not read $f"; fail=1; }
done
for f in $FILES; do
  [ -f "$GD/src/$f" ] || continue
  if ! "$LC" -p "$GD/src/$f" 2> "$GD/luac_err.txt"; then echo "FAIL luac $f: $(cat "$GD/luac_err.txt")"; fail=1; continue; fi
  slots=$("$LC" -l -p "$GD/src/$f" | grep -m1 -A1 "^main <" | tail -1 | grep -oE "[0-9]+ slots?" | grep -oE "[0-9]+")
  printf "  %-48s %6d lines, main chunk %3d of 250 slots\n" "$f" "$(wc -l < "$GD/src/$f")" "$slots"
  "$LC" -l -p "$GD/src/$f" | grep -oE "[GS]ETGLOBAL.*; [A-Za-z_][A-Za-z0-9_]*" | sed -E 's/.*; //' >> "$GD/globals_cand.txt"
done
"$LC" -l -p "$GD/base.lua" | grep -oE "[GS]ETGLOBAL.*; [A-Za-z_][A-Za-z0-9_]*" | sed -E 's/.*; //' | sort -u > "$GD/globals_base.txt"
sort -u -o "$GD/globals_cand.txt" "$GD/globals_cand.txt"
new=$(comm -13 "$GD/globals_base.txt" "$GD/globals_cand.txt")
gone=$(comm -23 "$GD/globals_base.txt" "$GD/globals_cand.txt")
if [ -n "$new" ]; then echo "FAIL global names the base does not use (a helper lost its local?): $(echo $new)"; fail=1; else echo "  global names: none new"; fi
[ -n "$gone" ] && echo "  global names no longer used: $(echo $gone)"
# the editor loads offline as in game (editor_load.lua, Prelude's list), and no module misses a helper
load=$(cd "$H" && FE_SRC= "$L" -e 'dofile("harness.lua")' 2>&1 | grep -iE "error|cannot open|needs .* which no file|attempt to|stack traceback" | head -5)
if [ -n "$load" ]; then echo "FAIL loading the editor: $load"; fail=1; else echo "  loads: no errors"; fi

# ------------------------------------------------------------------ the split registry (REGDIR)
mkdir -p "$GD/regdir"
(cd "$H" && FE_SRC="$GD/base.lua" "$L" split_registry.lua "$REGBASE" split_decisions.txt "$GD/regdir/ADFlyoverEditor_junctions.xml" > /dev/null) || { echo "STOP: split_registry.lua failed"; exit 1; }

# ------------------------------------------------------------------ the tests, in three waves
# Everything at once spends its time starting processes (Git Bash on Windows), so the tests run in
# waves, the base and the working tree side by side in each; the working tree's second run (the
# determinism check) is the first wave's - the clear and the check, where pairs() order has bitten.
# wave TAG FE WAVE  (FE: the build's one-file bundle)
wave() {
  local T=$1 FE=$2 W=$3
  local RD="$GD/rd_$T"; mkdir -p "$RD"
  cd "$H" || exit 1
  export FE_SRC="$FE"
  unset GRAPH
  local nets="graph_data=graph_data.lua ${GATE_NETS:-}"
  if [ "$W" = A ] && [ $FULL = 0 ]; then
    ( bash reg75.sh "${T}_graph_data" > /dev/null 2>&1 ) &
    ( bash reg75check.sh "${T}_graph_data" > /dev/null 2>&1 ) &
  elif [ "$W" = B ] && [ $FULL = 0 ]; then
    ( bash regbuild.sh "$T" > /dev/null 2>&1 ) &
    ( PATTERN=exact bash regplace.sh "${T}x" > /dev/null 2>&1 ) &
  elif [ "$W" = A ]; then
    for nv in $nets; do
      local n=${nv%%=*} g=${nv#*=}
      ( GRAPH="$g" bash reg75.sh "${T}_$n" > /dev/null 2>&1 ) &
      ( GRAPH="$g" bash reg75check.sh "${T}_$n" > /dev/null 2>&1 ) &
      ( mkdir -p "$RD/a_$n"; cp "$GD/regdir/"* "$RD/a_$n/"; GRAPH="$g" REGDIR="$RD/a_$n" bash reg75.sh "${T}R_$n" > /dev/null 2>&1 ) &
      ( mkdir -p "$RD/b_$n"; cp "$GD/regdir/"* "$RD/b_$n/"; GRAPH="$g" REGDIR="$RD/b_$n" bash reg75check.sh "${T}R_$n" > /dev/null 2>&1 ) &
    done
  elif [ "$W" = B ]; then
    ( bash regbuild.sh "$T" > /dev/null 2>&1 ) &
    ( PATTERN=exact bash regplace.sh "${T}x" > /dev/null 2>&1 ) &
    ( PATTERN=smooth bash regplace.sh "${T}s" > /dev/null 2>&1 ) &
    ( bash reg75undo.sh "$T" > /dev/null 2>&1 ) &
  else
    for nv in $nets; do
      local n=${nv%%=*} g=${nv#*=}
      ( mkdir -p "$RD/t_$n"; cp "$GD/regdir/"* "$RD/t_$n/"; GRAPH="$g" REGDIR="$RD/t_$n" bash regtwin.sh "${T}_$n" > /dev/null 2>&1 ) &
    done
    ( JOBS=$PAR bash reg75click.sh "$T" > /dev/null 2>&1 ) &
    ( bash reg_extra.sh "$T" > /dev/null 2>&1 ) &
    ( OUT="$RD/names" bash regnames.sh > "$GD/regnames_$T.txt" 2>&1 ) &
    ( OUT="$RD/missed" bash regmissed.sh "$T" > /dev/null 2>&1 ) &
    ( "$L" dbgtypes.lua "$SG/ADFlyoverEditor_junctions.xml" > "$GD/types_$T.txt" 2>&1 ) &
  fi
  wait
}
# every output a build wrote, into the gate folder, named without the tag
collect() {
  local T=$1
  cd "$H" || exit 1
  mkdir -p "$GD/$T"
  for f in reg75${T}_* reg75${T}R_* reg75check${T}_* reg75check${T}R_* regtwin${T}_* reg75click${T}_*            reg75undo${T}_* reg_extra${T}.txt regbuild${T}.txt regplace${T}x.txt regplace${T}s.txt regmissed${T}.txt; do
    [ -f "$f" ] && mv "$f" "$GD/$T/$(echo "$f" | sed "s/$T//")"
  done
  [ -f "$GD/regnames_$T.txt" ] && mv "$GD/regnames_$T.txt" "$GD/$T/regnames.txt"
  [ -f "$GD/types_$T.txt" ] && mv "$GD/types_$T.txt" "$GD/$T/types.txt"
  rm -rf "click$T" 2>/dev/null
}

WAVES="A B"; [ $FULL = 1 ] && WAVES="A B C"
echo "== $( [ $FULL = 1 ] && echo full || echo quick ) tests (base $BASE vs the working tree) - outputs in $GD"
start=$(date +%s)
for W in $WAVES; do
  ws=$(date +%s)
  ( wave MSb "$GD/base.lua" $W ) &
  ( wave MSc "$GD/cand.lua" $W ) &
  [ $W = A ] && [ $FULL = 1 ] && ( wave MSd "$GD/cand.lua" A ) &
  wait
  echo "  wave $W: $(( $(date +%s) - ws )) s"
done
for T in MSb MSc MSd; do collect $T; done
echo "  all tests: $(( $(date +%s) - start )) s"

# ------------------------------------------------------------------ compare
n=0
for f in $(ls "$GD/MSb"); do
  n=$((n + 1))
  a="$GD/MSb/$f" b="$GD/MSc/$f" c="$GD/MSd/$f"
  s="same"; [ -f "$b" ] && cmp -s "$a" "$b" || { s="DIFFERS"; fail=1; }
  t="-"
  if [ -f "$c" ]; then t="STABLE"; cmp -s "$b" "$c" || { t="UNSTABLE"; fail=1; }; fi
  printf "  %-34s %-8s %s\n" "$f" "$s" "$t"
done
for f in $(ls "$GD/MSc"); do [ -f "$GD/MSb/$f" ] || { echo "  $f: only in the working tree's run"; fail=1; }; done
errs=$(cat "$GD"/MSc/reg75_*.txt "$GD"/MSc/reg75R_*.txt 2>/dev/null | grep -c "err=[1-9]")
echo "  $n outputs compared; Lua errors in the working tree's reg75: $errs"
if [ $fail = 0 ]; then echo "GATE: PASS"; else echo "GATE: FAIL (see above; outputs in $GD)"; fi
exit $fail
