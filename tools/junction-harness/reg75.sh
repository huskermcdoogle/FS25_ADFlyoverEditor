# Regression over EVERY registry junction (the game's own numbers), both through modes.
#   GRAPH=<network .lua> REG=<ADFlyoverEditor_junctions.xml> bash reg75.sh TAG
# Writes reg75TAG_1.txt / _0.txt: one line per junction, "jN | took ... | err=N". A cleared junction
# (the clear refuses it) shows as REFUSED. Run it twice and diff - see the README on pairs().
export RIG_TRAILER=11
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
TAG=$1
REG="${REG:-$HOME/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6/ADFlyoverEditor_junctions.xml}"
for mode in 1 0; do
  : > reg75${TAG}_$mode.txt
  grep -oE 'n="[0-9]+" x="-?[0-9.]+" z="-?[0-9.]+"' "$REG" | sed -E 's/n="([0-9]+)" x="([^"]+)" z="([^"]+)"/\1 \2 \3/' |
  while read -r n x z; do
    o=$(LEAVE=$mode "$L" dbgstages.lua "$x" "$z" </dev/null 2>&1)
    tk=$(echo "$o" | grep -o "took [0-9]* point(s) in all, the farthest [0-9]* m" | head -1)
    er=$(echo "$o" | grep -ciE "attempt to|stack traceback")
    printf "j%s | %s | err=%s\n" "$n" "${tk:-REFUSED}" "$er" >> reg75${TAG}_$mode.txt
  done
  if [ $mode = 1 ]; then printf "thru ON : "; else printf "thru OFF: "; fi
  awk -F'|' '{match($2,/took ([0-9]+)/,A); match($2,/farthest ([0-9]+)/,B); T+=A[1]; if(B[1]+0>M)M=B[1]; if($2 ~ /REFUSED/) r++; if($3 !~ /err=0/) e++} END {printf "%d taken | worst %d m | %d refused | %d Lua errors\n", T, M, r+0, e+0}' reg75${TAG}_$mode.txt
done
