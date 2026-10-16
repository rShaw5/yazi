-- desc-bar: preview overlay — the previewed file's full cached description
-- as an autosized bar across the top of the preview area, a separator line,
-- then the file content below it. All drawn as ONE ui.Text over job.area,
-- using the exact ya.preview_widget(job, {..}) shape the preset previewers
-- (archive.lua) already rely on — this build rejects opts-table signatures.
local CACHE = "/Users/robinshaw/Code/yazi/spike-descriptions/desc-cache.tsv"
local ROOT = "/Users/robinshaw/Code/planning-system"
local MAX_BAR_LINES = 4
-- Injected-description styling: a lavandere accent + italic so the bar
-- clearly reads as injected summary, not file content.
local BAR_FG = "#b4befe"

local _cache, _cache_stamp = nil, nil
local _stamp_checked = 0

local LOGF = "/Users/robinshaw/Code/yazi/spike-descriptions/desc-bar.log"
local function trace(msg)
	local lg = io.open(LOGF, "a")
	if lg then
		lg:write(os.date("%H:%M:%S ") .. msg .. "\n")
		lg:close()
	end
end

local function now_s()
	local ok, t = pcall(function()
		return ya.time()
	end)
	if ok and type(t) == "number" then
		return t
	end
	return os.time()
end

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

-- Reload on cache-change publications: desc-row/desc-bulk/desc-menu emit
-- this after rewrites. Without it the bar keeps its old snapshot and says
-- "No summary" for rows that clearly have one. Registered once, from the
-- sync context; pcall'd because module load may run in an async context.
local _subscribed = false
pcall(function()
	ya.sync(function()
		if _subscribed then
			return
		end
		_subscribed = true
		ps.sub("desc-cache-changed", function()
			_cache = nil
		end)
	end)()
end)

local function fresh_desc(path, mtime)
	-- Peeks fire once per hover, so re-stamp every time (no throttle): the
	-- bar must never lag a rewrite by even a second.
	local stamp = cache_stamp()
	if _cache == nil or stamp == nil or stamp ~= _cache_stamp then
		_cache = load_cache()
		_cache_stamp = stamp
	end
	local key = nil
	if type(path) == "string" and path ~= "" then
		-- Tree-relative inside planning-system (probe/e-menu keys), absolute
		-- path elsewhere (desc-row writes outside rows there).
		key = path:sub(1, #ROOT + 1) == ROOT .. "/" and path:sub(#ROOT + 2) or path
	end
	local ent = key and _cache[key] or nil
	local nents = 0
	for _ in pairs(_cache) do
		nents = nents + 1
	end
	trace("fresh: stamp=" .. tostring(stamp) .. " ents=" .. nents .. " keylen=" .. tostring(key and #key) .. " hit=" .. tostring(ent ~= nil) .. " hyperlen=" .. tostring(ent and #ent.hyper) .. " own=" .. tostring(ent and ent.mtime))
	if not ent or ent.hyper == "" then
		return nil
	end
	local own = tonumber(ent.mtime:match("^[^|]+"))
	if not mtime or not own or math.floor(mtime) ~= own then
		return nil
	end
	-- The preview top shows the one-sentence detail (v2), falling back to
	-- the hyper phrase for legacy rows.
	return ent.long ~= "" and ent.long or ent.hyper
end

-- Wrap into lines of `width` cells, at most `max_lines` with an ellipsis.
local function wrap(desc, width, max_lines)
	local out, line = {}, ""
	for w in desc:gmatch("%S+") do
		local cand = line == "" and w or (line .. " " .. w)
		if #cand <= width then
			line = cand
		else
			if line ~= "" then
				out[#out + 1] = line
			end
			line = w
			while #line > width do
				out[#out + 1] = line:sub(1, width)
				line = line:sub(width + 1)
			end
		end
	end
	if line ~= "" then
		out[#out + 1] = line
	end
	if #out > max_lines then
		out[max_lines] = out[max_lines]:sub(1, math.max(#out[max_lines] - 1, 3)) .. "…"
		for i = max_lines + 1, #out do
			out[i] = nil
		end
	end
	return out
end

local function render(...)
	-- yazi calls previewers method-style (self, job); normalize.
	local job = select("#", ...) >= 2 and select(2, ...) or select(1, ...)
	local area, file
	pcall(function()
		area = job.area
		file = job.file
	end)
	if not area or not file then
		trace("peek: unusable job")
		return
	end
	local mtime = 0
	pcall(function()
		if file.cha and file.cha.mtime then
			mtime = file.cha.mtime
		end
	end)
	local path = tostring(file.url)
	if path:sub(1, 1) ~= "/" then
		-- Peek-job URLs can be cwd-relative; the cache keys absolute paths.
		local okcwd, cwdurl = pcall(fs.cwd)
		if okcwd and cwdurl then
			path = (tostring(cwdurl):gsub("/$", "")) .. "/" .. path
		end
	end
	-- Folder rule (yazi.toml "folder/*") reroutes directory previews here;
	-- below-bar content becomes the child listing instead of file text.
	local is_dir = false
	pcall(function()
		is_dir = file.cha and file.cha.is_dir == true
	end)
	if not is_dir then
		local p = io.popen('test -d "' .. (path:gsub('"', '\\"')) .. '" 2>/dev/null && echo d')
		if p then
			is_dir = p:read("*a") == "d"
			p:close()
		end
	end
	local desc = fresh_desc(path, mtime)
	trace("peek: path=" .. path .. " mtime=" .. tostring(math.floor(mtime)) .. " dir=" .. tostring(is_dir))

	local lines = {}
	local barrows = 0
	local function push_bar(txt)
		local okL, ln = pcall(function()
			return ui.Line(txt):style(ui.Style():fg(BAR_FG):italic())
		end)
		lines[#lines + 1] = okL and ln or txt
	end
	if desc then
		for _, l in ipairs(wrap(desc, math.max(area.w - 4, 10), MAX_BAR_LINES)) do
			push_bar(l)
		end
		barrows = #lines
		if barrows > 0 then
			-- Horizontal frame: separator breaks the preview into two.
			lines[#lines + 1] = string.rep("─", math.max(area.w, 3))
			barrows = barrows + 1
		end
	else
		-- Always a bar: "no summary generated yet" in the injected style
		-- when nothing is cached for this row.
		push_bar("no summary generated yet")
		lines[#lines + 1] = string.rep("─", math.max(area.w, 3))
		barrows = 2
	end

	-- Content below the bar; skip = scrolled lines (J/K).
	local maxc = area.h - barrows
	local skip = job.skip or 0
	-- NOTE: image previews deliberately do NOT route through the bar. The
	-- ya.image_show call hung in pty tests (2026-10-15, resolved only at
	-- quit) and was the freeze suspect; investigate precache first
	-- (agent inbox) before re-wiring images here.
	if maxc > 0 and skip >= 0 then
		if is_dir then
			local q = (path:gsub('"', '\\"'))
			local p = io.popen('ls -1 "' .. q .. '" 2>/dev/null')
			if p then
				local names = {}
				for nm in p:lines() do
					names[#names + 1] = nm
				end
				p:close()
				for i = skip + 1, math.min(#names, skip + maxc) do
					lines[#lines + 1] = names[i]:sub(1, area.w)
				end
			end
		else
			pcall(function()
				local f = io.open(path, "r")
				if f then
					local seen = 0
					for line in f:lines() do
						seen = seen + 1
						if seen > skip then
							lines[#lines + 1] = (line:gsub("\t", "  ")):sub(1, area.w)
							if #lines - barrows >= maxc then
								break
							end
						end
					end
					f:close()
				end
			end)
		end
	end

	local ok, err = pcall(function()
		ya.preview_widget(job, { ui.Text(lines):area(area) })
	end)
	trace("peek: area=" .. tostring(area.w) .. "x" .. tostring(area.h) .. " desc=" .. tostring(desc ~= nil) .. " lines=" .. #lines .. (ok and " drawn" or (" err=" .. tostring(err))))
end

-- J/K scrolling, exactly like the preset code previewer's seek.
local function seek(...)
	local job = select("#", ...) >= 2 and select(2, ...) or select(1, ...)
	local okh, h = pcall(function()
		return cx.active.current.hovered
	end)
	if not (okh and h and job and job.file) then
		return
	end
	local oku, same = pcall(function()
		return h.url == job.file.url
	end)
	if not (oku and same) then
		return
	end
	local step = math.floor((job.units or 1) * (job.area.h or 10) / 10)
	step = step == 0 and 1 or step
	pcall(function()
		ya.emit("peek", { math.max(0, (cx.active.preview.skip or 0) + step), only_if = job.file.url })
	end)
end

	return {
	peek = render,
	seek = seek,
	preload = function(job)
		-- Mirror the stock image previewer: precache so ya.image_show gets
		-- a prepared copy instead of hanging on the raw path.
		local okc, cached = pcall(function()
			return ya.file_cache(job)
		end)
		if okc and cached then
			local okf, st = pcall(function()
				return fs.stat(cached)
			end)
			if okf and not st then
				pcall(function()
					ya.image_precache(Url(tostring(job.file.path)), cached)
				end)
			end
		end
		return true
	end,
}
