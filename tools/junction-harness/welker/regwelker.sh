# Welker Farms (savegame3) junctions: clear + build each registry site on the save's own network, and say
# whether the mod's pattern went in and what the route check found (like regcourse.sh).
#   bash welker/regwelker.sh [both|build]   (run from tools/junction-harness)
# Make the fixture first (it is the user's save, so it stays out of git):
#   python export_graph.py "<FS25 profile>/savegame3/AutoDrive_config.xml" welker/welker_net.lua
#   cp "<FS25 profile>/savegame3/ADFlyoverEditor_junctions.xml" welker/
# 2026-11-03: j5-j8 are T's where a two-way farm road meets the two-lane main road (TWO_WAY=1 needed until
# the switch is on by default); j3 X and j9 T get the pattern either way; j1, j2 and j4 are not junctions.
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
ACT="${1:-both}"
grep -o 'n="[0-9a-z]*" x="[-0-9.]*" z="[-0-9.]*"' welker/ADFlyoverEditor_junctions.xml | sed -E 's/n="([^"]*)" x="([^"]*)" z="([^"]*)"/\1 \2 \3/' | while read n x z; do
  o=$(GRAPH=welker/welker_net.lua REGDIR=welker CLICK=1 TERRAIN=${TERRAIN:-0} "$L" dbgcard.lua "$x" "$z" "$ACT" </dev/null 2>&1)
  laid=$(echo "$o" | grep -oE "the mod's [a-z]+ [TX] fits" | head -1 | sed -E "s/the mod's ([a-z]+) ([TX]) fits/\1 \2/")
  why=$(echo "$o" | grep -oE "pattern did not fit: .*" | head -1 | sed 's/pattern did not fit: //')
  rc=$(echo "$o" | grep -oE "Route check: .*" | tail -1 | sed 's/Route check: //')
  er=$(echo "$o" | grep -ciE "attempt to|stack traceback")
  printf "j%-3s | pattern: %-10s | %s | err=%s%s\n" "$n" "${laid:-no}" "${rc:-no route check}" "$er" "${why:+ | $why}"
done
