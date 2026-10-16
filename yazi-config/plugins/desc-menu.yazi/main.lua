-- desc-menu: E key menu for per-row descriptions — "my words" (exact text)
-- or "my hint" (agent rewrite, saved for future rescans). Acts on
-- Space-selected rows, or the hovered row when nothing is selected.
local ROOT = "/Users/robinshaw/Code/planning-system"
local PROBE = "/Users/robinshaw/Code/yazi/spike-descriptions/probe.mjs"
local REWRITE = "/Users/robinshaw/Code/yazi/spike-descriptions/rewrite.mjs"
local CACHE = "/Users/robinshaw/Code/yazi/spike-descriptions/desc-cache.tsv"
local OVR = "/Users/robinshaw/Code/yazi/spike-descriptions/overrides.tsv"

-- Reload the linemode immediately after any cache rewrite lands.
local pub_changed = ya.sync(function()
	ps.pub("desc-cache-changed", {})
end)

-- cx lives in the sync context; pull plain sendable values out of it here.
-- Note: cx.active.selected is an iterator-ish userdata in yazi 26.9.1 —
-- enumerate it with pairs() (yields index, File); File.url stringifies.
local get_targets = ya.sync(function()
	local out = {}
	local sel = cx.active.selected
	local nok, n = pcall(function()
		return #sel
	end)
	if nok and n > 0 then
		local pok = pcall(function()
			for _, f in pairs(sel) do
				local ou, u = pcall(function()
					return f.url
				end)
				if ou and u ~= nil then
					local os, s = pcall(tostring, u)
					if os and type(s) == "string" then
						out[#out + 1] = s
					end
				end
			end
		end)
		if pok and #out > 0 then
			return out
		end
	end
	local h = cx.active.current.hovered
	if h then
		local ok, s = pcall(tostring, h.url)
		if ok and type(s) == "string" then
			out[#out + 1] = s
		end
	end
	return out
end)

-- ui.render() is sync-context only; wrap it once so entry can call it.
local render_now = ya.sync(function()
	ui.render()
end)

local function refresh()
	pcall(ya.emit, "refresh", {})
	render_now()
end

local function rel_of(apath)
	if type(apath) == "string" and apath:sub(1, #ROOT + 1) == ROOT .. "/" then
		return apath:sub(#ROOT + 2)
	end
	return nil
end

-- Current pin for a row: kind ("verbatim"/"hint") and its stored text.
local function load_override(rel)
	local f = io.open(OVR, "r")
	if not f then
		return nil, nil
	end
	for line in f:lines() do
		if line:sub(1, #rel + 1) == rel .. "	" then
			local kind, text = line:sub(#rel + 2):match("^([^\t]*)\t?(.*)$")
			f:close()
			return kind, text
		end
	end
	f:close()
	return nil, nil
end

-- Current displayed description from the cache (for prefilling the words
-- box on unpinned rows). Freshness is the linemode's job; here any text
-- beats a blank box.
local function cache_desc(rel)
	local f = io.open(CACHE, "r")
	if not f then
		return nil
	end
	for line in f:lines() do
		if line:sub(1, #rel + 1) == rel .. "	" then
			local parts = {}
			for p in line:gmatch("[^\t]+") do
				parts[#parts + 1] = p
			end
			f:close()
			-- v2: rel, mtime, hyper, long. "My words" replaces the inline
			-- hyper, so prefill with it.
			if #parts >= 3 then
				return parts[3]
			end
			return nil
		end
	end
	f:close()
	return nil
end

local function save_row(rel, kind, text)
	text = text:gsub("[\t\r\n]+", " "):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
	local rows = {}
	local f = io.open(OVR, "r")
	if f then
		for line in f:lines() do
			if line ~= "" and line:sub(1, #rel + 1) ~= rel .. "\t" then
				rows[#rows + 1] = line
			end
		end
		f:close()
	end
	rows[#rows + 1] = rel .. "\t" .. kind .. "\t" .. text
	table.sort(rows)
	local w = io.open(OVR, "w")
	if w then
		w:write(table.concat(rows, "\n") .. "\n")
		w:close()
	end
end

local function do_words(targets)
	local dirty = false
	for _, apath in ipairs(targets) do
		local rel = rel_of(apath)
		if rel then
			local name = rel:match("([^/]+)$") or rel
			local kind, cur = load_override(rel)
			-- Prefill with the frozen text, else the displayed text, so the
			-- box shows what a save would replace.
			local pre = ""
			if kind == "verbatim" then
				pre = cur or ""
			else
				pre = cache_desc(rel) or ""
			end
			-- ya.input throws on cancel; a cancelled row is skipped but
			-- must not abort the remaining rows.
			local ok, value, event = pcall(
				ya.input,
				{ title = "My words: " .. name, pos = { "top-center", y = 3, w = 60 }, value = pre }
			)
			if ok and event == 1 and value and value ~= "" then
				save_row(rel, "verbatim", value)
				dirty = true
			end
		end
	end
	if dirty then
		local child = Command("node"):arg(PROBE):spawn()
		if child then
			child:wait()
		end
		pub_changed()
		refresh()
	end
end

local function do_hint(targets)
	for _, apath in ipairs(targets) do
		local rel = rel_of(apath)
		if rel then
			local name = rel:match("([^/]+)$") or rel
			-- Prefill with whatever is stored (hint or frozen text) so the
			-- box shows what a save would replace.
			local _, pre = load_override(rel)
			local ok, hint, event = pcall(
				ya.input,
				{ title = "Hint for agent: " .. name, pos = { "top-center", y = 3, w = 60 }, value = pre or "" }
			)
			if ok and event == 1 and hint and hint ~= "" then
				save_row(rel, "hint", hint)
				-- rewrite.mjs writes the pending marker, runs the agent,
				-- and stores the new text (or restores the old on failure).
				local child = Command("node"):arg({
					REWRITE,
					"--root",
					ROOT,
					"--cache",
					CACHE,
					"--overrides",
					OVR,
					"--rel",
					rel,
					"--hint",
					hint,
				}):spawn()
				local succeeded = false
				if child then
					local status = child:wait()
					succeeded = status and status.success
				end
				if not succeeded then
					ya.notify({
						title = "Describe",
						content = "Agent rewrite failed for " .. name .. " — kept old text",
						timeout = 6,
						level = "warn",
					})
				end
				pub_changed()
				refresh()
			end
		end
	end
end

return {
	entry = function()
		local targets = get_targets()
		if #targets == 0 then
			return
		end
		local idx = ya.which({
			cands = {
				{ on = "1", desc = "My words — save exact text" },
				{ on = "2", desc = "My hint — agent rewrites now, hint saved" },
			},
		})
		if idx == 1 then
			do_words(targets)
		elseif idx == 2 then
			-- Visible handoff: if the hint input fails to open, this toast
			-- tells us the menu choice itself registered.
			ya.notify({ title = "Describe", content = "Hint mode — type the agent instruction", timeout = 3 })
			do_hint(targets)
		end
	end,
}
