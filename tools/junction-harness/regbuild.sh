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
# one junction a worker (regbuild_one.sh), PAR at a time, written in registry order (par_sites.sh)
export REG GRAPH FE_SRC REGDIR TERRAIN SHUFFLE LUA CLEARFIRST RIG_TRAILER
. ./par_sites.sh
par_sites 1 regbuild_one.sh "$OUT"
awk -F'|' '
  { s = $2
    if (s ~ /REFUSED/) { r++; next }
    n++
    match(s, /new=([0-9]+)/, A); nw += A[1]
    match(s, /refused=([0-9]+)/, B); rf += B[1]
    match(s, /dual=(-?[0-9]+)/, C); if (C[1] + 0 > 0) { du += C[1]; dj++ }
    match(s, /cross=([0-9]+)/, D); if (D[1] + 0 > 0) { cr += D[1]; cj++ }
    match(s, /extra=(-?[0-9]+)/, E); if (E[1] + 0 > 0) { ut += E[1]; uj++ }; if (E[1] + 0 < 0) nc++
    match(s, /routes=([0-9]+)/, F); rt += F[1]
    match(s, /kink30=([0-9]+)/, G); k3 += G[1]; match(s, /kink50=([0-9]+)/, K); k5 += K[1]
    match(s, /short=([0-9]+)/, Q); sl += Q[1]
    if (s ~ /pattern=(exact|smooth)/) pt++
    match(s, /missing=([0-9]+)/, MS); if (MS[1] + 0 > 0) { ms += MS[1]; mj++ }
    match(s, /opposed=([0-9]+)/, OP); if (OP[1] + 0 > 0) { op += OP[1]; oj++ }
    if ($3 !~ /err=0/) e++ }
  END {
    printf "%d built, %d refused, %d Lua errors | %d turns laid, %d refused\n", n, r + 0, e + 0, nw, rf
    printf "rules: two-way turn links %d at %d junctions | crossings without a shared point %d at %d | extra routes %d at %d (of %d routes; %d junctions with no route check)\n", du + 0, dj + 0, cr + 0, cj + 0, ut + 0, uj + 0, rt + 0, nc + 0
    printf "speed: sharp bends on our turns: %d at 30-50 deg (12 km/h), %d at 50+ (3 km/h) | links under 0.3 m: %d\n", k3 + 0, k5 + 0, sl + 0
    printf "pattern placed at %d junctions (the rest laid turn by turn) | turns laid but not drivable: %d at %d\n", pt + 0, ms + 0, mj + 0
    printf "lines on top of a line the other way: %d at %d junctions (must be 0)\n", op + 0, oj + 0
  }' "$OUT"
