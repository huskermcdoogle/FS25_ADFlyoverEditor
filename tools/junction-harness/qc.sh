# QUICK CHECK: clear the named junctions offline, both through modes, and print what the game's card
# and log would say. Seconds, not minutes - for use while working; reg75.sh / reg75check.sh are the
# full pass before a commit.
#   GRAPH=<network .lua> bash qc.sh 39 26 [x,z ...]
# Junction numbers are looked up in REG (default: savegame6's ADFlyoverEditor_junctions.xml). Unless
# REGDIR is set, a private copy of that file is used as REGDIR, so the user's split decisions name
# the parts (j39se) exactly as in game. MODES="1" or "0" limits it to one mode (1 = through roads kept).
export RIG_TRAILER=11
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
REG="${REG:-$HOME/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6/ADFlyoverEditor_junctions.xml}"
[ -z "$GRAPH" ] && { echo "set GRAPH=<network .lua> (e.g. the scratchpad live.lua, or export_route.py of a capture's pre.xml)"; exit 1; }
tmp=$(mktemp -d)
if [ -z "$REGDIR" ]; then mkdir -p "$tmp/reg"; cp "$REG" "$tmp/reg/ADFlyoverEditor_junctions.xml"; export REGDIR="$tmp/reg"; fi
export L GRAPH FE_SRC TERRAIN SHUFFLE REGDIR
i=0
for s in "$@"; do
  if [[ "$s" == *,* ]]; then x=${s%,*}; z=${s#*,}; label="($x, $z)"
  else
    xz=$(grep -oE "n=\"$s\" x=\"-?[0-9.]+\" z=\"-?[0-9.]+\"" "$REG" | sed -E 's/.*x="([^"]+)" z="([^"]+)"/\1 \2/')
    [ -z "$xz" ] && { echo "j$s: not in $REG"; continue; }
    x=${xz% *}; z=${xz#* }; label="j$s"
  fi
  for m in ${MODES:-1 0}; do i=$((i + 1)); printf "%03d|%s|%s|%s|%s\n" "$i" "$label" "$x" "$z" "$m"; done
done > "$tmp/jobs"
one() {
  IFS='|' read -r idx label x z m <<< "$1"
  mkdir -p "$TMPQ/r$idx"; cp -r "$REGDIR"/. "$TMPQ/r$idx/"
  o=$(REGDIR="$TMPQ/r$idx" ALL=1 LEAVE=$m "$L" dbgcheck.lua "$x" "$z" </dev/null 2>&1)
  mode=$([ "$m" = 1 ] && echo "through roads kept" || echo "through roads off")
  {
    if echo "$o" | grep -q "^REFUSED"; then
      echo "$label, $mode: refused - $(echo "$o" | grep -m1 '^REFUSED' | sed 's/^REFUSED: //')"
    else
      name=$(echo "$o" | grep -m1 '^NAME ' | sed 's/^NAME //')
      took=$(echo "$o" | grep -m1 -o 'took [0-9]* point(s) in all, the farthest [0-9]* m')
      echo "$label, $mode: locked as $name, $took"
      echo "$o" | grep '^CARD ' | sed 's/^CARD /    card: /'
      echo "$o" | grep 'junction - check: \|junction - check (' | sed -E 's/^.*junction - check/    check/'
      echo "$o" | grep -ciE 'attempt to|stack traceback' | grep -v '^0$' | sed 's/^/    LUA ERRORS: /'
    fi
  } > "$TMPQ/out$idx"
}
export -f one; export TMPQ="$tmp"
tr '\n' '\0' < "$tmp/jobs" | xargs -0 -P "${PAR:-16}" -I{} bash -c 'one "$@"' _ {}
for f in $(ls "$tmp" | grep '^out' | sort); do cat "$tmp/$f"; done
rm -rf "$tmp"
