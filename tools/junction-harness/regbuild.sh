# BUILD regression over every registry junction: clear it (through roads kept), then build it with the
# real applyJunction, and check the result against doc 06's rules.
#   GRAPH=<network .lua> REG=<ADFlyoverEditor_junctions.xml> bash regbuild.sh TAG
# Writes regbuildTAG.txt, one line per junction:
#   jN | moves new refused points links dual teal cross uturn | err=N
# where dual = new two-way links, cross = crossings without a shared point, uturn = U-turn routes
# through new links (all three should be 0 for a build that follows doc 06). A junction the clear or
# the build refuses shows as REFUSED. Run it twice and diff, as for reg75.sh.
export RIG_TRAILER=11 CLEARFIRST=1
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
TAG=$1
REG="${REG:-$HOME/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6/ADFlyoverEditor_junctions.xml}"
OUT=regbuild${TAG}.txt
: > "$OUT"
grep -oE 'n="[0-9]+" x="-?[0-9.]+" z="-?[0-9.]+"' "$REG" | sed -E 's/n="([0-9]+)" x="([^"]+)" z="([^"]+)"/\1 \2 \3/' |
while read -r n x z; do
  o=$("$L" dbgbuild.lua "$x" "$z" </dev/null 2>&1)
  c=$(echo "$o" | grep "^COUNTS" | head -1 | cut -d' ' -f4-)
  er=$(echo "$o" | grep -ciE "attempt to|stack traceback")
  printf "j%s | %s | err=%s\n" "$n" "${c:-REFUSED}" "$er" >> "$OUT"
done
awk -F'|' '
  { s = $2
    if (s ~ /REFUSED/) { r++; next }
    n++
    match(s, /new=([0-9]+)/, A); nw += A[1]
    match(s, /refused=([0-9]+)/, B); rf += B[1]
    match(s, /dual=(-?[0-9]+)/, C); if (C[1] + 0 > 0) { du += C[1]; dj++ }
    match(s, /cross=([0-9]+)/, D); if (D[1] + 0 > 0) { cr += D[1]; cj++ }
    match(s, /uturn=([0-9]+)/, E); if (E[1] + 0 > 0) { ut += E[1]; uj++ }
    if ($3 !~ /err=0/) e++ }
  END {
    printf "%d built, %d refused, %d Lua errors | %d turns laid, %d refused\n", n, r + 0, e + 0, nw, rf
    printf "rules: two-way turn links %d at %d junctions | crossings without a shared point %d at %d | U-turn routes %d at %d\n", du + 0, dj + 0, cr + 0, cj + 0, ut + 0, uj + 0
  }' "$OUT"
