# One junction for regplace.sh: n x z mode -> "jN | ok=... | err=N" (mode unused; PATTERN passes through)
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
o=$("$L" dbgplace.lua "$2" "$3" </dev/null 2>&1)
c=$(echo "$o" | grep "^PLACE" | head -1 | cut -d' ' -f4-)
er=$(echo "$o" | grep -ciE "attempt to|stack traceback| failed:")
printf "j%s | %s | err=%s\n" "$1" "${c:-NONE}" "$er"
