# One junction for reg75.sh: n x z mode -> "jN | took ... | err=N"
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
o=$(LEAVE=$4 "$L" dbgstages.lua "$2" "$3" </dev/null 2>&1)
tk=$(echo "$o" | grep -o "took [0-9]* point(s) in all, the farthest [0-9]* m" | head -1)
er=$(echo "$o" | grep -ciE "attempt to|stack traceback")
printf "j%s | %s | err=%s\n" "$1" "${tk:-REFUSED}" "$er"
