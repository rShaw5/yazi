-- desc-popup: T key shows the hovered file's full cached description as a toast.
local CACHE = "/Users/robinshaw/Code/yazi/spike-descriptions/desc-cache.tsv"
local OVR = "/Users/robinshaw/Code/yazi/spike-descriptions/overrides.tsv"
local ROOT = "/Users/robinshaw/Code/planning-system"

-- cx lives in the sync context; pull plain sendable values out of it here.
local get_target = ya.sync(function()
	local h = cx.active.current.hovered
	if not h then
		return nil
	end
	local ok, apath = pcall(tostring, h.url)
	local mtime = 0
	if h.cha and h.cha.mtime then
		mtime = h.cha.mtime
	end
	return { name = h.name, path = (ok and apath or nil), mtime = mtime }
end)

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

return {
	entry = function()
		local tgt = get_target()
		if not tgt then
			return
		end
		local text = "(no cached description)"
		if type(tgt.path) == "string" then
			-- Planning-system rows key by tree-relative rel; outside rows
			-- (desc-row) key by absolute path.
			local key = nil
			if tgt.path:sub(1, #ROOT + 1) == ROOT .. "/" then
				key = tgt.path:sub(#ROOT + 2)
			elseif tgt.path ~= "" then
				key = tgt.path
			end
			if key then
				local ent = load_cache()[key]
				if ent then
					local own = ent.mtime:match("^[^|]+")
					if tostring(math.floor(tgt.mtime)) == own and ent.hyper ~= "" then
						-- The full view shows the one-sentence detail (v2),
						-- falling back to the hyper phrase for legacy rows.
						text = ent.long ~= "" and ent.long or ent.hyper
					end
				end
			end
		end
		local rel = nil
		if type(tgt.path) == "string" and tgt.path ~= "" then
			rel = tgt.path:sub(1, #ROOT + 1) == ROOT .. "/" and tgt.path:sub(#ROOT + 2) or tgt.path
		end
		if rel then
			local f = io.open(OVR, "r")
			if f then
				for line in f:lines() do
					if line:sub(1, #rel + 1) == rel .. "	" then
						local kind, rest = line:sub(#rel + 2):match("^([^\t]*)\t?(.*)$")
						if kind == "verbatim" then
							text = text .. "\n— your exact words (frozen)"
						elseif kind == "hint" then
							text = text .. "\n— guided by hint: " .. rest
						end
						break
					end
				end
				f:close()
			end
		end
		ya.notify({ title = tgt.name, content = text, timeout = 10 })
	end,
}
