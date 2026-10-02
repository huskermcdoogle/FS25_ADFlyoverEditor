# THE CLICK REGRESSION: does a clear come out the same from any click inside the junction?
# Every registry junction, both through modes, cleared from six clicks: the registry point, 4 m
# east, west, south and north of it (OFF= sets the 4), and the crossing the clear from the registry
# point works on ("clearing the one at", or the site's middle where no crossing is named).
#   GRAPH=<network .lua> REG=<ADFlyoverEditor_junctions.xml> bash reg75click.sh TAG
# Writes click<TAG>/ (dbgseq.lua output per junction, mode and click, with SITE=1: the site the
# selection locked and the crossing cleared, then TOOK, ROUTEs, COUNTS and every EDIT by position)
# and reg75click<TAG>_1.txt / _0.txt: one line per junction,
#   jN | same                                      every click gave the identical clear
#   jN | refused                                   every click was refused (e.g. already clear):
#                                                  nothing was cleared, so nothing was compared
#   jN | DIFFERS at e,w | site: ... | took: ... | counts: ...
# naming the clicks whose result is not the registry click's, and for each of those whether the
# site moved (the click picked another junction - a neighbour within a few metres, or another part
# of a split junction), what the clear took, and the check's counts. A difference with the same site
# is the clear depending on the click; one with another site is the selection's choice of junction.
# Then the totals. Skips 67 and 68 (test junk; SKIP= to change). Run it twice: identical.
export RIG_TRAILER=11
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
TAG=$1
REG="${REG:-$HOME/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6/ADFlyoverEditor_junctions.xml}"
SKIP="${SKIP:-67 68}"
OFF="${OFF:-4}"
JOBS="${JOBS:-16}"
D=click$TAG
mkdir -p "$D"
grep -oE 'n="[0-9]+" x="-?[0-9.]+" z="-?[0-9.]+"' "$REG" | sed -E 's/n="([0-9]+)" x="([^"]+)" z="([^"]+)"/\1 \2 \3/' |
  awk -v skip="$SKIP" 'BEGIN { n = split(skip, s, " "); for (i = 1; i <= n; i++) bad[s[i]] = 1 } !($1 in bad)' > "$D/sites.txt"
run() {  # run N LABEL X Z MODE
  SITE=1 LEAVE=$5 "$L" dbgseq.lua "$3" "$4" </dev/null > "$D/$1_$5_$2.txt" 2>&1
}
export -f run; export L D
# Pass 1: the registry point, and the four around it.
{
  for mode in 1 0; do
    awk -v m=$mode -v o="$OFF" '{
      printf "%s reg %s %s %s\n", $1, $2, $3, m
      printf "%s e %.3f %s %s\n", $1, $2 + o, $3, m
      printf "%s w %.3f %s %s\n", $1, $2 - o, $3, m
      printf "%s s %s %.3f %s\n", $1, $2, $3 + o, m
      printf "%s n %s %.3f %s\n", $1, $2, $3 - o, m }' "$D/sites.txt"
  done
} > "$D/jobs1.txt"
xargs -P "$JOBS" -L 1 bash -c 'run "$@"' _ < "$D/jobs1.txt"
# Pass 2: the crossing the registry click's clear worked on (FS25 z grows southward: s is +z).
{
  for mode in 1 0; do
    while read -r n x z; do
      f="$D/${n}_${mode}_reg.txt"
      c=$(grep -m1 "^CROSSING " "$f" | cut -d' ' -f2-)
      [ -z "$c" ] && c=$(grep -m1 "^SITE -\?[0-9]" "$f" | cut -d' ' -f2-)
      [ -n "$c" ] && echo "$n x $c $mode"
    done < "$D/sites.txt"
  done
} > "$D/jobs2.txt"
xargs -P "$JOBS" -L 1 bash -c 'run "$@"' _ < "$D/jobs2.txt"
for mode in 1 0; do
  out=reg75click${TAG}_$mode.txt
  : > "$out"
  while read -r n x z; do
    ref="$D/${n}_${mode}_reg.txt"
    bad=""; sites=""; tooks=""; counts=""
    for c in e w s n x; do
      f="$D/${n}_${mode}_$c.txt"
      [ -f "$f" ] || continue
      if ! cmp -s "$ref" "$f"; then
        bad="$bad${bad:+,}$c"
        s0=$(grep -m1 "^SITE" "$ref" | cut -d' ' -f2-); s1=$(grep -m1 "^SITE" "$f" | cut -d' ' -f2-)
        if [ "$s0" = "$s1" ]; then sites="$sites $c:same"; else sites="$sites $c:($s1)"; fi
        tooks="$tooks $c:$(grep -m1 '^TOOK' "$f" | grep -oE '[0-9]+' | head -1)"
        counts="$counts $c:[$(grep -m1 '^COUNTS' "$f" | sed 's/^COUNTS //')]"
      fi
    done
    refused=1
    for c in reg e w s n x; do
      f="$D/${n}_${mode}_$c.txt"
      [ -f "$f" ] && ! grep -q "^REFUSED" "$f" && refused=0
    done
    if [ -z "$bad" ] && [ $refused = 1 ]; then
      printf "j%s | refused\n" "$n" >> "$out"
    elif [ -z "$bad" ]; then
      printf "j%s | same\n" "$n" >> "$out"
    else
      printf "j%s | DIFFERS at %s | registry site (%s) took %s [%s] | site:%s | took:%s | counts:%s\n" "$n" "$bad" \
        "$(grep -m1 '^SITE' "$ref" | cut -d' ' -f2-)" "$(grep -m1 '^TOOK' "$ref" | grep -oE '[0-9]+' | head -1)" \
        "$(grep -m1 '^COUNTS' "$ref" | sed 's/^COUNTS //')" "$sites" "$tooks" "$counts" >> "$out"
    fi
  done < "$D/sites.txt"
  if [ $mode = 1 ]; then printf "thru ON : "; else printf "thru OFF: "; fi
  awk '{ t++ } /\| refused/ { r++ } /DIFFERS/ { d++; if ($0 ~ /:same/) s++ } END { printf "%d junctions (%d refused from every click, not compared), %d differ by click point (%d of them with the same site for some differing click)\n", t, r + 0, d + 0, s + 0 }' "$out"
done
