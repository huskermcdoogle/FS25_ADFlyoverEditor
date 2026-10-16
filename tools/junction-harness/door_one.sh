# One junction for the door check: n x z mode -> "jN | door ok/FAIL | ... | err=N"
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
o=$(LEAVE=$4 "$L" dbgdoor.lua "$2" "$3" </dev/null 2>&1)
d=$(echo "$o" | grep -o "door .*" | tail -1)
er=$(echo "$o" | grep -ciE "attempt to|stack traceback")
printf "j%s | %s | err=%s\n" "$1" "${d:-door NO RESULT}" "$er"
