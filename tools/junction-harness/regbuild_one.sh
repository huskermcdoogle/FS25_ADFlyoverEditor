# One junction for regbuild.sh: n x z mode -> "jN | moves ... | err=N" (mode unused)
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
o=$("$L" dbgbuild.lua "$2" "$3" </dev/null 2>&1)
c=$(echo "$o" | grep "^COUNTS" | head -1 | cut -d' ' -f4-)
er=$(echo "$o" | grep -ciE "attempt to|stack traceback")
printf "j%s | %s | err=%s\n" "$1" "${c:-REFUSED}" "$er"
