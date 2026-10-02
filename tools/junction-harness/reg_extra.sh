# The extra, unnumbered junctions in extra_sites.txt, cleared from the lock point the game used, in the
# mode the user ran and the other one. Writes reg_extraTAG.txt: one line per site and mode with the
# clear's totals and the check's card lines.
#   GRAPH=<network .lua> bash reg_extra.sh TAG
export RIG_TRAILER=11
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
TAG=$1
OUT=reg_extra${TAG}.txt
: > "$OUT"
grep -v '^#' extra_sites.txt | grep -v '^[[:space:]]*$' | while read -r label x z mode; do
  for m in "$mode" $((1 - mode)); do
    o=$(ALL=1 LEAVE=$m "$L" dbgcheck.lua "$x" "$z" </dev/null 2>&1)
    tk=$(echo "$o" | grep -o "took [0-9]* point(s) in all, the farthest [0-9]* m" | head -1)
    card=$(echo "$o" | grep "^CARD" | sed 's/^CARD //' | paste -sd'|' -)
    er=$(echo "$o" | grep -ciE "attempt to|stack traceback")
    printf "%s LEAVE=%s | %s | %s | err=%s\n" "$label" "$m" "${tk:-REFUSED}" "${card:-NO CHECK}" "$er" >> "$OUT"
  done
done
cat "$OUT"
