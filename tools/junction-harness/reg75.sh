# Regression over EVERY registry junction (the game's own numbers), both through modes.
#   GRAPH=<network .lua> REG=<ADFlyoverEditor_junctions.xml> bash reg75.sh TAG
# Writes reg75TAG_1.txt / _0.txt: one line per junction, "jN | took ... | err=N". A cleared junction
# (the clear refuses it) shows as REFUSED. Run it twice and diff - see the README on pairs().
export RIG_TRAILER=11
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
TAG=$1
REG="${REG:-$HOME/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6/ADFlyoverEditor_junctions.xml}"
export REG GRAPH FE_SRC REGDIR TERRAIN SHUFFLE LUA
. ./par_sites.sh   # PAR=1 runs one at a time; the output is the same either way
for mode in 1 0; do
  par_sites $mode reg75_one.sh reg75${TAG}_$mode.txt
  if [ $mode = 1 ]; then printf "thru ON : "; else printf "thru OFF: "; fi
  awk -F'|' '{match($2,/took ([0-9]+)/,A); match($2,/farthest ([0-9]+)/,B); T+=A[1]; if(B[1]+0>M)M=B[1]; if($2 ~ /REFUSED/) r++; if($3 !~ /err=0/) e++} END {printf "%d taken | worst %d m | %d refused | %d Lua errors\n", T, M, r+0, e+0}' reg75${TAG}_$mode.txt
done
