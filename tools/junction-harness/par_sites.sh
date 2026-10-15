# Runs one worker per registry junction, PAR at a time (default 16), and writes their output in the
# registry's order, so a parallel run is byte-identical to a one-at-a-time run. Each clear is its own Lua
# process and reads nothing another one writes; with REGDIR set, each worker gets a private copy of it,
# because a run can save the junction file there.
#   . par_sites.sh; par_sites <mode> <worker.sh> <outfile>
# The worker is called as: bash <worker.sh> <n> <x> <z> <mode>, and prints that junction's lines.
par_sites() {
  local mode=$1 worker=$2 out=$3
  local REGFILE="${REG:-$HOME/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6/ADFlyoverEditor_junctions.xml}"
  local tmp; tmp=$(mktemp -d)
  grep -oE 'n="[0-9]+" x="-?[0-9.]+" z="-?[0-9.]+"' "$REGFILE" | sed -E 's/n="([0-9]+)" x="([^"]+)" z="([^"]+)"/\1 \2 \3/' |
    awk '{printf "%04d %s %s %s\n", NR, $1, $2, $3}' > "$tmp/list"
  PARTMP="$tmp" PARWORKER="$worker" PARMODE="$mode" xargs -P "${PAR:-16}" -L 1 bash -c '
    idx=$1; n=$2; x=$3; z=$4
    if [ -n "$REGDIR" ]; then mkdir -p "$PARTMP/reg$idx"; cp -r "$REGDIR"/. "$PARTMP/reg$idx/"; export REGDIR="$PARTMP/reg$idx"; fi
    bash "$PARWORKER" "$n" "$x" "$z" "$PARMODE" > "$PARTMP/out$idx" 2>/dev/null
  ' _ < "$tmp/list"
  : > "$out"
  for f in $(ls "$tmp" | grep '^out' | sort); do cat "$tmp/$f" >> "$out"; done
  rm -rf "$tmp"
}
