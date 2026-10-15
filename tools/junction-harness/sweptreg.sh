# The swept-path prediction over EVERY registry junction (dbgswept.lua), for a SweptSim change.
#   GRAPH=<network .lua> REG=<ADFlyoverEditor_junctions.xml> [TERRAIN=1] [SWEPT_SRC=<SweptSim.lua>] bash sweptreg.sh TAG
# Writes sweptregTAG.txt: each junction's turns and summary. Run it twice and diff, as with reg75.sh.
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
TAG=$1
REG="${REG:-$HOME/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6/ADFlyoverEditor_junctions.xml}"
: > sweptreg${TAG}.txt
grep -oE 'n="[0-9]+" x="-?[0-9.]+" z="-?[0-9.]+"' "$REG" | sed -E 's/n="([0-9]+)" x="([^"]+)" z="([^"]+)"/\1 \2 \3/' |
while read -r n x z; do
  o=$("$L" dbgswept.lua "$x" "$z" </dev/null 2>&1)
  er=$(echo "$o" | grep -ciE "attempt to|stack traceback")
  { echo "j$n err=$er"; echo "$o" | grep -E "^  [0-9]|^SUMMARY"; } >> sweptreg${TAG}.txt
done
awk '/^SUMMARY/ { match($0, /turns ([0-9]+)/, a); t += a[1]; match($0, /trailerRoad ([0-9]+)/, b); r += b[1];
                  match($0, /swept wide ([0-9]+)/, c); w += c[1]; match($0, /out of time ([0-9]+)/, d); o += d[1];
                  match($0, /twin runs ([0-9]+)/, e); n += e[1] }
     /err=[1-9]/ { er++ }
     END { printf "%d turns | %d refused trailer-off-road | %d past corridor | %d twin runs, %d out of time | %d junctions with Lua errors\n", t, r, w, n, o, er + 0 }' sweptreg${TAG}.txt
