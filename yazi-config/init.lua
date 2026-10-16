-- Phase 3 MVP: per-file cached descriptions from desc-cache.tsv (probe.mjs).
-- Format per line: relpath \t mtime(sec) \t description. No dependencies, plain Lua.
-- Rows show a clamped few-words teaser; the status bar shows the full text of
-- the hovered file; the T key pops the full text as a notification.
local ROOT = "/Users/robinshaw/Code/planning-system"
local CACHE = "/Users/robinshaw/Code/yazi/spike-descriptions/desc-cache.tsv"
local OVR = "/Users/robinshaw/Code/yazi/spike-descriptions/overrides.tsv"
local ROW_WORDS = 5
-- Nerd Font icons as decimal UTF-8 escapes (valid in every Lua version).
local ICON_LOCK = "\239\128\163"
local ICON_HINT = "\239\129\128"
-- Matches rewrite.mjs/probe.mjs; planning rows show it verbatim, and while
-- present desc-row's poll loop re-renders every 0.3s so the pulse animates.
local MARKER = "… rewriting description …"
local SPINNER = { "○", "◔", "◕", "●", "◕", "◔" }

local _cache = nil
local _cache_stamp = nil
local _kinds = nil
local _stamp_checked = 0
local _cols = nil
local _cols_checked = 0

-- Clock without assuming sandbox APIs: ya.time() preferred, os.time fallback.
local function now_s()
	local ok, t = pcall(function()
		return ya.time()
	end)
	if ok and type(t) == "number" then
		return t
	end
	local ok2, t2 = pcall(function()
		return os.time()
	end)
	if ok2 and type(t2) == "number" then
		return t2
	end
	return 0
end

-- Window width, re-measured on a fast 0.2s throttle so a resize reflows.
-- tput/stty against /dev/tty (a yazi child has no tty on plain pipes);
-- fallbacks: tput cols, $COLUMNS, then 100.
local function term_cols()
	local now = now_s()
	if _cols == nil or now - _cols_checked >= 0.2 then
		_cols_checked = now
		local n
		local p = io.popen("stty size < /dev/tty 2>/dev/null")
		if p then
			local rowcol = p:read("*l")
			p:close()
			n = rowcol and tonumber(rowcol:match("(%d+)$"))
		end
		if not n then
			p = io.popen("tput cols 2>/dev/null")
			if p then
				n = tonumber(p:read("*l") or "")
				p:close()
			end
		end
		_cols = n or tonumber(os.getenv("COLUMNS") or "") or _cols or 100
	end
	return _cols
end

-- Row kinds (verbatim = frozen exact words, hint = agent guided by a saved
-- hint) come from overrides.tsv and drive the lock/pencil row marks.
-- Reloaded with the cache; a missing file means no marks, never an error.
local function load_kinds()
	local t = {}
	local f = io.open(OVR, "r")
	if not f then
		return t
	end
	for line in f:lines() do
		if line ~= "" then
			local tab1 = line:find("	", 1, true)
			if tab1 then
				local tab2 = line:find("	", tab1 + 1, true)
				if tab2 then
					t[line:sub(1, tab1 - 1)] = line:sub(tab1 + 1, tab2 - 1)
				else
					t[line:sub(1, tab1 - 1)] = "verbatim"
				end
			end
		end
	end
	f:close()
	return t
end

-- The probe, the E-key plugin, and the agent all rewrite the cache file
-- under a running yazi; reload whenever its mtime moves so rows refresh.
local function cache_stamp()
	local p = io.popen('stat -f %m "' .. CACHE .. '" 2>/dev/null')
	if not p then
		return nil
	end
	local s = p:read("*l")
	p:close()
	return s
end

local function load_cache()
	local t = {}
	local f = io.open(CACHE, "r")
	if not f then
		return t
	end
	for line in f:lines() do
		local tab1 = line:find("\t", 1, true)
		if tab1 then
			local tab2 = line:find("\t", tab1 + 1, true)
			if tab2 then
				local tab3 = line:find("\t", tab2 + 1, true)
				local rel = line:sub(1, tab1 - 1)
				local mtime = line:sub(tab1 + 1, tab2 - 1)
				-- v2: rel, mtime, hyper, long; v1 rows fall back to one desc.
				local hyper = line:sub(tab2 + 1, tab3 and tab3 - 1 or -1)
				local long = tab3 and line:sub(tab3 + 1) or hyper
				t[rel] = { mtime = mtime, hyper = hyper, long = long }
			end
		end
	end
	f:close()
	return t
end

local function rel_of(file)
	local apath = ""
	if file.url then
		local ok, s = pcall(tostring, file.url)
		if ok and type(s) == "string" then
			apath = s
		end
	end
	if apath:sub(1, #ROOT + 1) == ROOT .. "/" then
		return apath:sub(#ROOT + 2)
	elseif apath == ROOT then
		return "."
	end
	return nil
end

-- Row kind for display: tree-relative inside planning-system (probe/e-menu
-- keys), absolute path elsewhere (desc-row writes outside rows there).
local function display_rel(file)
	local rel = rel_of(file)
	if rel then
		return rel
	end
	if file.url then
		local ok, s = pcall(tostring, file.url)
		if ok and s ~= "" then
			return s
		end
	end
	return nil
end

local function full_desc(file)
	-- The stamp check spawns a process; throttle it to once a second shared
	-- across all rows instead of once per row per redraw.
	if _cache == nil then
		_cache = load_cache()
		_cache_stamp = cache_stamp()
		_kinds = load_kinds()
		_stamp_checked = now_s()
	else
		local now = now_s()
		if now - _stamp_checked >= 1 then
			_stamp_checked = now
			local stamp = cache_stamp()
			if stamp ~= nil and stamp ~= _cache_stamp then
				_cache = load_cache()
				_cache_stamp = stamp
				_kinds = load_kinds()
			end
		end
	end
	local rel = display_rel(file)
	if not rel then
		return nil
	end
	local ent = _cache[rel]
	if not ent or ent.hyper == "" then
		return nil
	end
	local mtime = 0
	if file.cha and file.cha.mtime then
		mtime = math.floor(file.cha.mtime)
	end
	-- Dir keys carry a child fingerprint after "|"; the own-mtime prefix
	-- is what the display checks (the probe run itself catches child moves).
	local own = ent.mtime:match("^[^|]+")
	if tostring(mtime) ~= own then
		return nil
	end
	-- The inline navigator shows the hyper summary only; the one-sentence
	-- detail lives in the desc-bar preview top (and the T popup).
	return ent.hyper
end

local function clamp_words(s, n)
	local words = {}
	for w in s:gmatch("%S+") do
		words[#words + 1] = w
	end
	if #words <= n then
		return s
	end
	local out = {}
	for i = 1, n do
		out[#out + 1] = words[i]
	end
	return table.concat(out, " ") .. " …"
end

-- desc-row/desc-bulk/desc-menu publish this right after rewriting the cache;
-- the linemode reloads immediately, so rows update in place with no cursor
-- move (the 1s stamp-throttle alone would otherwise skip the final render).
ps.sub("desc-cache-changed", function()
	_cache = load_cache()
	_kinds = load_kinds()
	_cache_stamp = cache_stamp()
	_stamp_checked = now_s()
end)

function Linemode:desc()
	local d = full_desc(self._file)
	if not d then
		return ui.Line({ ui.Span(" [nodesc]"):fg("white") })
	end
	if d:sub(1, #MARKER) == MARKER then
		local i = math.floor(now_s() * 3) % #SPINNER + 1
		return ui.Line({ ui.Span(" " .. SPINNER[i] .. " rewriting…"):fg("cyan") })
	end
	local mark = ""
	if _kinds then
		local kind = _kinds[display_rel(self._file) or ""]
		if kind == "verbatim" then
			mark = ICON_LOCK .. " "
		elseif kind == "hint" then
			mark = ICON_HINT .. " "
		end
	end
	-- One line, window-width limited: the full name deserves its column, so
	-- the desc gets whatever is left of the central list width (≈4/9 of the
	-- terminal under the default mgr.ratio, minus icon/name/gap room).
	local ok, nm = pcall(function()
		return self._file.name
	end)
	nm = ok and nm or ""
	local max = math.max(math.floor(term_cols() * 4 / 9) - #nm - 7, 10)
	local marks = #mark + 1
	if #d > max - marks then
		d = d:sub(1, math.max(max - marks - 1, 3)) .. "…"
	end
	return ui.Line({ ui.Span(" " .. mark .. d):fg("white") })
end

-- Full text lives only in the T-key popup (desc-popup.yazi); the status
-- bar stays stock.
