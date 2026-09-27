export RIG_TRAILER=11
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
TAG=$1
for mode in 1 0; do
  : > reg${TAG}_$mode.txt
  while read -r x z rest; do
    o=$(LEAVE=$mode "$L" dbgstages.lua "$x" "$z" </dev/null 2>&1)
    tk=$(echo "$o" | grep -o "took [0-9]* point(s) in all, the farthest [0-9]* m" | head -1)
    er=$(echo "$o" | grep -ciE "attempt to|stack traceback")
    printf "%s | err=%s\n" "${tk:-NONE}" "$er" >> reg${TAG}_$mode.txt
  done < sweep_all/junctions.txt
  if [ $mode = 1 ]; then printf "thru ON : "; else printf "thru OFF: "; fi
  awk -F'|' '{match($1,/took ([0-9]+)/,A); match($1,/farthest ([0-9]+)/,B); T+=A[1]; if(B[1]+0>M)M=B[1]; if($1 ~ /NONE/) bad++; if($2 !~ /err=0/) e++} END {printf "%d taken | worst %d m | %d no result | %d Lua errors\n", T, M, bad+0, e+0}' reg${TAG}_$mode.txt
done
