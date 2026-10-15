# EVERY ORDERED PAIR OF PARTS OF EVERY SPLIT JUNCTION: clear one part, then the other, both through-road
# settings, and say what the first clear left of the second part's turns (dbgtwin.lua). The parts are
# the user's, from split_decisions.txt; the editor reads them as the game does (REGDIR, a folder made
# with split_registry.lua - see the README). One Lua process per pair and setting.
#   REGDIR=<folder> GRAPH=<network .lua> bash regtwin.sh TAG
# Writes regtwin<TAG>.txt: one line per pair and setting -
#   A then B | L1|L0 | after A: drives N fromcut N tocut N broken N nowayin N nowayout N | mismatch N unsaid N | B refused? | err=N
# then, indented, every turn of B's that does not drive after A's clear, every turn A's check says
# wrongly (dbgtwin.lua's MISMATCH: a turn that drives said as a fault, or one that does not drive
# called "left working") and every one it says nothing of (UNSAID: one that does not drive, outside
# what the check follows), A's card and B's card; then the totals. A pair whose second part is
# already cleared (72, 73) shows as "B refused".
export RIG_TRAILER="${RIG_TRAILER:-11}"
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
TAG=$1
OUT=regtwin${TAG}.txt
if [ -z "$REGDIR" ]; then echo "REGDIR is not set: the parts would not be split (see the README)"; exit 1; fi
tmp=$(mktemp -d)
# the parts, by junction number: name x z
grep -v '^#' split_decisions.txt | grep -v '^whole' | grep -v '^[[:space:]]*$' | sed 's/#.*//' |
  awk '{ n = $1; sub(/[a-z]+$/, "", n); print n, $1, $(NF-1), $NF }' > "$tmp/parts"
: > "$tmp/jobs"
for n in $(awk '{print $1}' "$tmp/parts" | sort -un); do
  awk -v n="$n" '$1 == n {print $2, $3, $4}' "$tmp/parts" > "$tmp/p$n"
  while read -r a ax az; do
    while read -r b bx bz; do
      if [ "$a" != "$b" ]; then
        for m in 1 0; do echo "$a $ax,$az $b $bx,$bz $m" >> "$tmp/jobs"; done
      fi
    done < "$tmp/p$n"
  done < "$tmp/p$n"
done
i=0
while read -r a A b B m; do
  i=$((i + 1))
  echo "$(printf %04d $i) $a $A $b $B $m"
done < "$tmp/jobs" > "$tmp/list"
TMP="$tmp" LUA="$L" xargs -P "${PAR:-16}" -L 1 bash -c '
  idx=$1; a=$2; A=$3; b=$4; B=$5; m=$6
  mkdir -p "$TMP/reg$idx"; cp -r "$REGDIR"/. "$TMP/reg$idx/"
  REGDIR="$TMP/reg$idx" LEAVE=$m A=$A B=$B "$LUA" dbgtwin.lua > "$TMP/raw$idx" 2>&1 < /dev/null
  r="$TMP/raw$idx"
  c() { grep -c "^AFTER_A TURN [0-9]* $1 " "$r"; }
  ref=""; if grep -q "^B2 REFUSED\|^B REFUSED\|^A REFUSED" "$r"; then ref=" | refused: $(grep -o "REFUSED.*" "$r" | head -1 | cut -c9-90)"; fi
  err=$(grep -h "ERRORS [0-9]*" "$r" | awk "{s+=\$NF} END {print s+0}")
  if grep -q "STOPPED\|lua.exe:" "$r"; then err=$((err + 1)); fi
  mm=$(grep -c "^AFTER_A SAID .* MISMATCH " "$r")
  un=$(grep -c "^AFTER_A SAID .* UNSAID " "$r")
  {
    echo "$a then $b | L$m | after A: drives $(c drives) fromcut $(c fromcut) tocut $(c tocut) broken $(c broken) nowayin $(c nowayin) nowayout $(c nowayout) | mismatch $mm unsaid $un$ref | err=$err"
    grep "^AFTER_A TURN [0-9]* \(broken\|nowayin\|nowayout\) " "$r" | sed "s/^/    /"
    grep "^AFTER_A SAID .* \(MISMATCH\|UNSAID\) " "$r" | sed "s/^/    /"
    grep "^A CARD" "$r" | sed "s/^A CARD/    A card:/"
    grep "^B CARD" "$r" | sed "s/^B CARD/    B card:/"
  } > "$TMP/out$idx"
' _ < "$tmp/list"
: > "$OUT"
for f in $(ls "$tmp" | grep "^out" | sort); do cat "$tmp/$f" >> "$OUT"; done
awk -F" [|] " '/^[0-9a-z]+ then / {
    n++; split($3, a, " ");
    for (i = 3; i < length(a); i += 2) t[a[i]] += a[i + 1]
    split($4, b, " "); mm += b[2]; un += b[4]
    if ($0 ~ /refused/) r++
    if ($NF !~ /err=0/) e++
  } END {
    printf "\n== totals ==\n%d runs, %d with the second part refused, %d with Lua errors\nafter the first clear:", n, r + 0, e + 0
    printf " drives %d fromcut %d tocut %d broken %d nowayin %d nowayout %d\n", t["drives"], t["fromcut"], t["tocut"], t["broken"], t["nowayin"], t["nowayout"]
    printf "said wrongly by the first clear'"'"'s check (MISMATCH): %d; not drivable and not said (UNSAID): %d\n", mm, un
  }' "$OUT" >> "$OUT"
tail -4 "$OUT"
rm -rf "$tmp"
