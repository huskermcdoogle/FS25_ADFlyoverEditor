# EVERY TURN OF EVERY SPLIT PART, MISSED ON PURPOSE: the check must call it missed, never another part's
# own wiring. For each part the user named in split_decisions.txt (put into a junction file by
# split_registry.lua, read by the editor as the game reads it - REGDIR), in both through-road settings,
# each piece of the part's own turn wiring is kept in turn (missed.lua: the clear refuses its points),
# and the check's verdict on every join that runs over it is printed. Nothing is written outside
# regmissed_out/ (OUT= puts it elsewhere).
#   GRAPH=<network .lua> REG=<ADFlyoverEditor_junctions.xml> bash regmissed.sh TAG
# Writes regmissed<TAG>.txt: one line per part, setting and piece, then the totals. Where no join runs
# over a kept piece, the line says what the check said of it instead (missed.lua): a leftover or spur
# line, or a teal dot on it or beside it ("said as dot:<reason>"). A join over a kept
# piece read as "part=jNNx" (or "twin=jNNx" / "twinwait=jNNx" / "twinstuck=jNNx", another part's turn left by the clear)
# is a missed turn the check passed as another part's - unless the kept piece
# is not the turn the join turns on (a join that only touches the piece's end, or a kept piece that is
# really a stretch of main road the clear counts as wiring); read such a line before calling it a fault.
export RIG_TRAILER="${RIG_TRAILER:-11}"
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
TAG=$1
REG="${REG:-$HOME/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6/ADFlyoverEditor_junctions.xml}"
OUT="${OUT:-regmissed_out}"
mkdir -p "$OUT"
rm -f "$OUT"/*.xml 2>/dev/null
"$L" split_registry.lua "$REG" split_decisions.txt "$OUT/ADFlyoverEditor_junctions.xml" >/dev/null ||
  { echo "split_registry.lua failed"; exit 1; }
export REGDIR="$OUT"
out=regmissed${TAG}.txt
: > "$out"
sed 's/#.*//' split_decisions.txt | awk 'NF >= 3 && $1 ~ /^[0-9]+[a-z]*$/ { print $1, $(NF-1), $NF }' |
while read -r part x z; do
  for mode in 1 0; do
    k=1
    while :; do
      o=$(LEAVE=$mode K=$k "$L" missed.lua "$x" "$z" </dev/null 2>&1)
      if echo "$o" | grep -q "^NONE\|^REFUSED"; then break; fi
      er=$(echo "$o" | grep -ciE "attempt to|stack traceback|CLEAR STOPPED")
      printf "%s LEAVE=%s %s | err=%s\n" "$part" "$mode" "$(echo "$o" | grep '^PIECE' | head -1)" "$er" >> "$out"
      k=$((k + 1))
    done
  done
done
awk '/^[0-9]+[a-z]* LEAVE=/ {
  n++
  if ($0 ~ /no join over it/) {
    none++
    # A dot read as another part'"'"'s (dot:part), or as another part'"'"'s turn left by the clear
    # (dot:twin, dot:twinwait, dot:twinstuck), is not a report of a miss: counted apart.
    s = $0; gsub(/said as dot:(part|twin|twinwait|twinstuck) at \([^)]*\)/, "", s)
    if (s ~ /said as/) said++; else if ($0 ~ /said as dot:(part|twin|twinwait|twinstuck)/) partdot++
  }
  m = gsub(/ missed/, "&"); p = gsub(/ (part|twin|twinwait|twinstuck)=/, "&"); missed += m; part += p
  if ($0 !~ /err=0/) errs++
}
END { printf "\n== totals ==\n%d pieces kept, %d with no join over them (%d of those said as a leftover, a spur or a teal dot; %d only by a dot read as another part'"'"'s, or its turn) | joins over them: %d missed, %d another part'"'"'s (its wiring or its turn) | %d Lua errors\n", n, none + 0, said + 0, partdot + 0, missed + 0, part + 0, errs + 0 }' "$out" >> "$out"
tail -2 "$out"
