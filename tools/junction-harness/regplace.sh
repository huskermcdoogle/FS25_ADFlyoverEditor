# PLACE regression over every registry junction (doc 08): clear it (through roads kept), then place.
#   GRAPH=<network .lua> REG=<ADFlyoverEditor_junctions.xml> PATTERN=exact|smooth bash regplace.sh TAG
# Writes regplaceTAG.txt, one PLACE line per junction, and sums: fitted, plain, refused (with why), loose
# ends, Lua errors. Run it twice and diff.
export RIG_TRAILER=11 CLEARFIRST=1
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
TAG=$1
REG="${REG:-$HOME/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6/ADFlyoverEditor_junctions.xml}"
OUT=regplace${TAG}.txt
: > "$OUT"
grep -oE 'n="[0-9]+" x="-?[0-9.]+" z="-?[0-9.]+"' "$REG" | sed -E 's/n="([0-9]+)" x="([^"]+)" z="([^"]+)"/\1 \2 \3/' |
while read -r n x z; do
  o=$("$L" dbgplace.lua "$x" "$z" </dev/null 2>&1)
  c=$(echo "$o" | grep "^PLACE" | head -1 | cut -d' ' -f4-)
  er=$(echo "$o" | grep -ciE "attempt to|stack traceback| failed:")
  printf "j%s | %s | err=%s\n" "$n" "${c:-NONE}" "$er" >> "$OUT"
done
awk -F'|' '
  { s = $2
    if (s ~ /ok=1/) { if (s ~ /shape=plain/) pl++; else fi++ } else rf++
    match(s, /loose=([0-9]+)/, A); lo += A[1]; if (A[1] + 0 > 0) lj++
    match(s, /extra=([0-9]+)/, X); ex += X[1]; if (X[1] + 0 > 0) xj++
    match(s, /missing=([0-9]+)/, M); mi += M[1]; if (M[1] + 0 > 0) mj++
    match(s, /unjoined=([0-9]+)/, U); un += U[1]; if (U[1] + 0 > 0) uj++
    if ($3 !~ /err=0/ || s ~ /it_failed/) e++ }
  END { printf "%d fitted, %d plain, %d refused, %d Lua errors | loose ends %d at %d junctions\n", fi + 0, pl + 0, rf + 0, e + 0, lo + 0, lj + 0
        printf "route check: %d route(s) we did not lay at %d junctions | %d turn(s) that cannot be driven at %d | %d road(s) not joined at %d\n", ex + 0, xj + 0, mi + 0, mj + 0, un + 0, uj + 0 }' "$OUT"
grep -o "why=[^ |]*" "$OUT" | grep -v "why=-" | sort | uniq -c | sort -rn
