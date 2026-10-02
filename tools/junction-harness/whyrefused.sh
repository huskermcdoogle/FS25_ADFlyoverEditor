# Why did regbuild refuse a junction? For each junction number given (default: every REFUSED line in
# regbuildTAG.txt), say whether the clear or the build refused it, and the tool's own reason.
#   GRAPH=<network .lua> REG=<ADFlyoverEditor_junctions.xml> bash whyrefused.sh TAG [n ...]
export RIG_TRAILER=11 CLEARFIRST=1
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
TAG=$1; shift
REG="${REG:-$HOME/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6/ADFlyoverEditor_junctions.xml}"
NUMS="$*"
[ -z "$NUMS" ] && NUMS=$(grep REFUSED "regbuild${TAG}.txt" | cut -d' ' -f1 | tr -d j)
for n in $NUMS; do
  xz=$(grep -oE "n=\"$n\" x=\"-?[0-9.]+\" z=\"-?[0-9.]+\"" "$REG" | sed -E 's/.*x="([^"]+)" z="([^"]+)"/\1 \2/')
  o=$("$L" dbgbuild.lua $xz </dev/null 2>&1)
  why=$(echo "$o" | grep -E "REFUSED" | head -1)
  printf "j%-3s (%s) | %s\n" "$n" "$xz" "${why:-not refused this time}"
done
