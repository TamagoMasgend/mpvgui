-- Shader chains: presets from shaders.conf, discovered files, import,
-- persistence and failure detection.
--
-- Everything here runs on user actions (panel click / script message), never on
-- the render path.  Applying a chain is a single property set on
-- `glsl-shaders` (a string list); mpv recompiles on the next frame.

local msg = require("mp.msg")
local utils = require("mp.utils")

local M = {}

-- Directory layout, all under mpv's config dir except the packaged one:
--   <config>/mpv/shaders.conf?  -> no: presets live in <config>/mpv/mpvgui/shaders.conf
--   <config>/mpv/shaders/*.glsl|*.hook|*.vpy   (user-wide shader dir)
--   <config>/mpv/mpvgui/shaders/...            (shaders imported/kept by this GUI)
--   <script dir>/../shaders/...                (shaders shipped with the package)
local BASE = "~~/mpvgui"

local toast = function() end -- replaced by main.lua
local on_change = function() end

function M.set_callbacks(opts)
	toast = opts.toast or toast
	on_change = opts.on_change or on_change
end

-- `~~/` is mpv's config dir.  With --no-config mpv clears it and
-- expand-path("~~/x") prints a *relative* path ("x"), which would silently
-- resolve against the CWD; fall back to the --config-dir option / XDG default.
local function config_dir()
	local ok, res = pcall(mp.command_native, { "expand-path", "~~/" })
	if ok and type(res) == "string" and res:sub(1, 1) == "/" then
		return res
	end
	local opt = mp.get_property_native("options/config-dir")
	if type(opt) == "string" and opt:sub(1, 1) == "/" then
		return opt
	end
	local env = utils.get_env_list()
	local xdg = env and env.XDG_CONFIG_HOME
	if type(xdg) == "string" and xdg:sub(1, 1) == "/" then
		return utils.join_path(xdg, "mpv")
	end
	local home = env and env.HOME
	if type(home) == "string" and home:sub(1, 1) == "/" then
		return utils.join_path(utils.join_path(home, ".config"), "mpv")
	end
	return "."
end

local function expand(path)
	if type(path) ~= "string" then
		return path
	end
	if path:sub(1, 2) == "~~" then
		path = config_dir() .. path:sub(3)
	end
	local ok, res = pcall(mp.command_native, { "expand-path", path })
	if ok and type(res) == "string" and res ~= "" then
		return res
	end
	return path
end

local function dirname(path)
	local dir = utils.split_path(path)
	return dir or ""
end

local function basename(path)
	local _, name = utils.split_path(path)
	return name or path
end

function M.shipped_dir()
	local dir = mp.get_script_directory and mp.get_script_directory() or nil
	if not dir then
		return nil
	end
	return expand(dir .. "/../shaders")
end

function M.state_dir()
	return expand(BASE)
end

function M.conf_path()
	return expand(BASE .. "/shaders.conf")
end

function M.state_path()
	return expand(BASE .. "/state.json")
end

function M.import_dir()
	return expand(BASE .. "/shaders")
end

-- Candidate directories for {@link M.discover}.
function M.shader_dirs()
	local dirs = {}
	local seen = {}
	local function add(dir)
		if dir and dir ~= "" and not seen[dir] then
			seen[dir] = true
			dirs[#dirs + 1] = dir
		end
	end
	add(expand("~~/shaders"))
	add(M.import_dir())
	local shipped = M.shipped_dir()
	if shipped then
		add(shipped)
	end
	return dirs
end

local SHADER_EXT = { glsl = true, hook = true, vpy = true }

local function extension(path)
	local ext = path:match("%.([%w]+)$")
	return ext and ext:lower() or nil
end

local function is_shader_file(path)
	return SHADER_EXT[extension(path) or ""] == true
end

local function file_exists(path)
	local info = utils.file_info(path)
	return info ~= nil and info.is_dir == false
end

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	return data
end

local function write_file(path, data)
	local f = io.open(path, "wb")
	if not f then
		return false
	end
	f:write(data)
	f:close()
	return true
end

-- Asynchronous "mkdir -p": mpv has no mkdir in mp.utils and a synchronous
-- subprocess would stall the player, so this is fire-and-forget.  Callers
-- retry their write a few times instead of assuming the directory exists.
local function ensure_dir(path)
	pcall(utils.subprocess_detached, { args = { "mkdir", "-p", path } })
end

local function write_with_retry(path, data, cb)
	local attempts = 0
	local function try()
		attempts = attempts + 1
		if write_file(path, data) then
			cb(true)
			return
		end
		if attempts >= 5 then
			cb(false, "cannot write " .. path)
			return
		end
		ensure_dir(dirname(path))
		mp.add_timeout(0.1 * attempts, try)
	end
	try()
end

-- Presets ------------------------------------------------------------------

local function parse_chain(text)
	local files = {}
	for item in text:gmatch("[^,]+") do
		item = item:match("^%s*(.-)%s*$")
		if item ~= "" then
			files[#files + 1] = item
		end
	end
	return files
end

local function resolve_file(item, dirs)
	local candidates = { item, expand(BASE .. "/" .. item), expand("~~/" .. item) }
	for _, dir in ipairs(dirs) do
		candidates[#candidates + 1] = utils.join_path(dir, item)
	end
	for _, path in ipairs(candidates) do
		if is_shader_file(path) and file_exists(path) then
			return path
		end
	end
	return nil
end

-- name = a.glsl, b.hook  (relative paths resolve against the config dirs)
function M.load_presets()
	local presets = {}
	local data = read_file(M.conf_path())
	if not data then
		return presets -- missing file is not an error
	end
	local dirs = M.shader_dirs()
	for line in data:gmatch("[^\r\n]+") do
		local stripped = line:match("^%s*(.-)%s*$")
		if stripped ~= "" and stripped:sub(1, 1) ~= "#" then
			local name, chain = stripped:match("^([^=]+)=(.*)$")
			if name and chain then
				name = name:match("^%s*(.-)%s*$")
				local files = {}
				for _, item in ipairs(parse_chain(chain)) do
					local resolved = resolve_file(item, dirs)
					files[#files + 1] = resolved or expand(item)
				end
				if name ~= "" and #files > 0 then
					presets[#presets + 1] = { name = name, kind = "preset", files = files }
				end
			end
		end
	end
	return presets
end

-- Discovered single-file shaders, sorted by file name.
function M.discover()
	local files = {}
	local seen = {}
	for _, dir in ipairs(M.shader_dirs()) do
		local items = utils.readdir(dir)
		if items then
			for _, name in ipairs(items) do
				local path = utils.join_path(dir, name)
				if is_shader_file(path) and file_exists(path) and not seen[path] then
					seen[path] = true
					files[#files + 1] = { name = basename(path), kind = "file", files = { path } }
				end
			end
		end
	end
	table.sort(files, function(a, b)
		return a.name < b.name
	end)
	return files
end

-- Full entry list: Off, presets, files, Import…
function M.entries()
	local list = { { name = "Off", kind = "off", files = {} } }
	for _, e in ipairs(M.load_presets()) do
		list[#list + 1] = e
	end
	for _, e in ipairs(M.discover()) do
		list[#list + 1] = e
	end
	list[#list + 1] = { name = "Import…", kind = "import", files = {} }
	return list
end

-- Applying -----------------------------------------------------------------

M.active = { name = "Off", kind = "off", files = {} }
M.active_chain = {}
M.pending = nil
local pending_timer = nil

local function set_chain(chain)
	mp.set_property_native("glsl-shaders", chain)
end

local function save_state()
	local data = utils.format_json({ kind = M.active.kind, name = M.active.name })
	ensure_dir(M.state_dir())
	write_with_retry(M.state_path(), data, function() end)
end

local function apply_entry(entry, quiet)
	local chain = entry.files or {}
	-- A preset may reference files that no longer exist: fail loudly instead of
	-- letting mpv silently drop the chain.
	for _, path in ipairs(chain) do
		if not file_exists(path) then
			toast("missing shader: " .. basename(path))
			return false
		end
	end
	local previous = M.active
	local previous_chain = M.active_chain
	M.active = { name = entry.name, kind = entry.kind, files = chain }
	M.active_chain = chain
	set_chain(chain)
	-- Watch for a compile failure for 5 s; mpv reports it after the next frame.
	M.pending = { name = entry.name, previous = previous, previous_chain = previous_chain }
	if pending_timer then
		pending_timer:kill()
	end
	pending_timer = mp.add_timeout(5, function()
		pending_timer = nil
		M.pending = nil
	end)
	if not quiet then
		save_state()
		on_change()
	end
	return true
end

function M.apply(entry, quiet)
	if not entry or entry.kind == "import" then
		return false
	end
	return apply_entry(entry, quiet)
end

function M.apply_index(index, quiet)
	local entries = M.entries()
	local entry = entries[(tonumber(index) or 0) + 1]
	if not entry then
		return false
	end
	return M.apply(entry, quiet)
end

function M.apply_name(name, quiet)
	if not name or name == "" then
		return false
	end
	if name:lower() == "off" then
		return M.apply({ name = "Off", kind = "off", files = {} }, quiet)
	end
	for _, entry in ipairs(M.entries()) do
		if entry.kind ~= "import" and entry.name:lower() == name:lower() then
			return M.apply(entry, quiet)
		end
	end
	return false
end

function M.is_active(entry)
	return entry.kind ~= "import" and entry.kind == M.active.kind and entry.name == M.active.name
end

-- Called from the log-message handler when mpv reports a shader compile error.
function M.compile_failed()
	local pending = M.pending
	M.pending = nil
	if pending_timer then
		pending_timer:kill()
		pending_timer = nil
	end
	if not pending then
		return false
	end
	M.active = pending.previous
	M.active_chain = pending.previous_chain
	set_chain(pending.previous_chain)
	toast("shader failed: " .. pending.name .. " (reverted)")
	on_change()
	return true
end

-- Persistence --------------------------------------------------------------

function M.load_state()
	local data = read_file(M.state_path())
	if not data then
		return
	end
	local ok, parsed = pcall(utils.parse_json, data)
	if not ok or type(parsed) ~= "table" then
		return
	end
	local kind, name = parsed.kind, parsed.name
	if type(name) ~= "string" or name == "" then
		return
	end
	if name == "Off" then
		M.apply({ name = "Off", kind = "off", files = {} }, true)
		return
	end
	for _, entry in ipairs(M.entries()) do
		if entry.kind == kind and entry.name == name then
			M.apply(entry, true)
			return
		end
	end
	msg.verbose("mpvgui: stored shader '" .. name .. "' is no longer available")
end

-- Import -------------------------------------------------------------------

local function copy_into_import_dir(src)
	local name = basename(src)
	local dest = utils.join_path(M.import_dir(), name)
	local data = read_file(src)
	if not data then
		toast("cannot read " .. src)
		return nil
	end
	ensure_dir(M.import_dir())
	local done = false
	write_with_retry(dest, data, function(ok, err)
		done = true
		if not ok then
			toast(err or "import failed")
			return
		end
		toast("imported " .. name)
		on_change()
	end)
	if not done then
		msg.verbose("mpvgui: import of " .. name .. " scheduled")
	end
	return dest
end

-- Returns true when the import was started (the copy may finish a moment later).
function M.import(path)
	if type(path) ~= "string" or path:match("^%s*$") then
		toast("import: empty path")
		return false
	end
	path = expand(path:match("^%s*(.-)%s*$"))
	local info = utils.file_info(path)
	if not info then
		toast("import: not found: " .. path)
		return false
	end
	if info.is_dir then
		toast("import: is a directory: " .. path)
		return false
	end
	local ext = extension(path)
	if not ext or not SHADER_EXT[ext] then
		toast("import: need .glsl/.hook/.vpy: " .. basename(path))
		return false
	end
	copy_into_import_dir(path)
	return true
end

return M
