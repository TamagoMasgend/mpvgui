-- mpv scripting Lua is 5.2 (see flake.nix). `mp` is injected by the mpv
-- runtime, never required; declare it so luacheck does not flag every call.
std = "lua52"
read_globals = {
	"mp",
}
