# One junction for reg75undo.sh: n x z mode -> "jN | UNDO ... | err=N", then where a failing one's
# networks part (the lines dbgundo.lua indents)
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
o=$(LEAVE=$4 "$L" dbgundo.lua "$2" "$3" </dev/null 2>&1)
line=$(echo "$o" | grep "^UNDO" | tail -1)
er=$(echo "$o" | grep -v "^UNDO" | grep -ciE "attempt to|stack traceback")
printf "j%s | %s | err=%s\n" "$1" "${line:-NO RESULT}" "$er"
echo "$o" | grep "^  "
