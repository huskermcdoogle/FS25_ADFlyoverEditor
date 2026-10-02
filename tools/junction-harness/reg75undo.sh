# Undo after a clear, over EVERY registry junction, both through modes (see dbgundo.lua).
#   GRAPH=<network .lua> REG=<ADFlyoverEditor_junctions.xml> bash reg75undo.sh TAG
# Writes reg75undoTAG_1.txt / _0.txt: one line per junction, "jN | UNDO ok|FAIL ... | err=N", and
# under a failing one where the networks part. The after= checksums let two builds' clears be
# compared junction by junction: same checksum, same network after the clear.
export RIG_TRAILER=11
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
TAG=$1
REG="${REG:-$HOME/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6/ADFlyoverEditor_junctions.xml}"
for mode in 1 0; do
  : > reg75undo${TAG}_$mode.txt
  grep -oE 'n="[0-9]+" x="-?[0-9.]+" z="-?[0-9.]+"' "$REG" | sed -E 's/n="([0-9]+)" x="([^"]+)" z="([^"]+)"/\1 \2 \3/' |
  while read -r n x z; do
    o=$(LEAVE=$mode "$L" dbgundo.lua "$x" "$z" </dev/null 2>&1)
    line=$(echo "$o" | grep "^UNDO" | tail -1)
    er=$(echo "$o" | grep -v "^UNDO" | grep -ciE "attempt to|stack traceback")
    printf "j%s | %s | err=%s\n" "$n" "${line:-NO RESULT}" "$er" >> reg75undo${TAG}_$mode.txt
    echo "$o" | grep "^  " >> reg75undo${TAG}_$mode.txt
  done
  if [ $mode = 1 ]; then printf "thru ON : "; else printf "thru OFF: "; fi
  awk '/^j[0-9]/ {n++; if ($0 ~ /UNDO ok/) ok++; if ($0 ~ /pushed=1/) p++; if ($0 ~ /changed=yes/) c++; if ($0 !~ / err=0 after=/ || $0 !~ /\| err=0$/) e++}
       END {printf "%d junctions | %d ok | %d FAIL | %d undo steps | %d changed | %d with Lua errors\n", n, ok+0, n-ok, p+0, c+0, e+0}' reg75undo${TAG}_$mode.txt
done
