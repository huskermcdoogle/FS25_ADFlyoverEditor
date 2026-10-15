# Undo after a clear, over EVERY registry junction, both through modes (see dbgundo.lua).
#   GRAPH=<network .lua> REG=<ADFlyoverEditor_junctions.xml> bash reg75undo.sh TAG
# Writes reg75undoTAG_1.txt / _0.txt: one line per junction, "jN | UNDO ok|FAIL ... | err=N", and
# under a failing one where the networks part. The after= checksums let two builds' clears be
# compared junction by junction: same checksum, same network after the clear.
export RIG_TRAILER=11
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
TAG=$1
REG="${REG:-$HOME/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6/ADFlyoverEditor_junctions.xml}"
export REG GRAPH FE_SRC REGDIR TERRAIN SHUFFLE LUA RIG_TRAILER
. ./par_sites.sh
for mode in 1 0; do
  # one junction a worker (reg75undo_one.sh), PAR at a time, written in registry order (par_sites.sh)
  par_sites $mode reg75undo_one.sh reg75undo${TAG}_$mode.txt
  if [ $mode = 1 ]; then printf "thru ON : "; else printf "thru OFF: "; fi
  awk '/^j[0-9]/ {n++; if ($0 ~ /UNDO ok/) ok++; if ($0 ~ /pushed=1/) p++; if ($0 ~ /changed=yes/) c++; if ($0 !~ / err=0 after=/ || $0 !~ /\| err=0$/) e++}
       END {printf "%d junctions | %d ok | %d FAIL | %d undo steps | %d changed | %d with Lua errors\n", n, ok+0, n-ok, p+0, c+0, e+0}' reg75undo${TAG}_$mode.txt
done
