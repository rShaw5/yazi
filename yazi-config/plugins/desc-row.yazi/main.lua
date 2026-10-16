-- desc-row: m-r re-summarizes just the hovered row. A separate plugin
-- until desc-bulk learns a keymap-arg-free way to switch modes: touching
-- rt.args (sync or async) panics the scheduler on this yazi build, so this
-- plugin hardcodes the row path from desc-bulk's proven machinery.
local ROOT = "/Users/robinshaw/Code/planning-system"
local REWRITE = "/Users/robinshaw/Code/yazi/spike-descriptions/rewrite.mjs"
local CACHE = "/Users/robinshaw/Code/yazi/spike-descriptions/desc-cache.tsv"
local OVR = "/Users/robinshaw/Code/yazi/spike-descriptions/overrides.tsv"
local SKIP = { [".git"] = true, ["node_modules"] = true }

-- Step log: tail -f ~/Code/yazi/spike-descriptions/desc-row.log
local LOGF = "/Users/robinshaw/Code/yazi/spike-descriptions/desc-row.log"
local function step(msg)
	local lg = io.open(LOGF, "a")
	if lg then
		lg:write(os.date("%H:%M:%S ") .. msg .. "\n")
		lg:close()
	end
end

-- Hovered row; nil when nothing is under the cursor.
local get_hovered = ya.sync(function()
	local h = cx.active.current.hovered
	if not h then
		return nil
	end
	local ok, s = pcall(tostring, h.url)
	return ok and s or nil
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
	-- Planning-system rows keep their tree-relative rel (same keys the
	-- probe and the e-menu already use). Any other row runs from its own
	-- parent dir with its basename, so the rewrite works anywhere on disk.
	if type(apath) ~= "string" then
		return nil
	end
	local parent, base = apath:match("^(.*/)([^/]+)$")
	if apath:sub(1, #ROOT + 1) == ROOT .. "/" then
		return { rel = apath:sub(#ROOT + 2), root = ROOT, key = apath:sub(#ROOT + 2), name = base }
	end
	if not parent or parent == "" or apath:sub(-1) == "/" then
		return nil
	end
	return { rel = apath, root = parent, key = apath, name = base }
end

-- Current pin for the row: kind ("verbatim"/"hint") and its stored text.
local function load_pin(rel)
	local f = io.open(OVR, "r")
	if not f then
		return nil, nil
	end
	for line in f:lines() do
		if line:sub(1, #rel + 1) == rel .. "\t" then
			f:close()
			return line:sub(#rel + 2):match("^([^\t]*)\t?(.*)$")
		end
	end
	f:close()
	return nil, nil
end

-- Reload the linemode immediately after any plugin rewrites the cache.
local pub_changed = ya.sync(function()
	ps.pub("desc-cache-changed", {})
end)

return {
	entry = function()
		-- pcall net: any error the toast cannot outlive becomes a log line.
		local ok, err = pcall(function()
			step("entry")
			local hu = get_hovered()
			step("hovered: got=" .. tostring(hu))
			local loc = hu and rel_of(hu) or nil
			if not loc then
				ya.notify({
					title = "Re-summarize row",
					content = hu and "This path has no parent directory it can be read from" or "No row is hovered",
					timeout = 5,
				})
				return
			end
			local name = loc.name
			local kind, hint = load_pin(loc.key)
			if SKIP[name] then
				ya.notify({ title = "Re-summarize row", content = name .. " is skipped", timeout = 5 })
				return
			end
			if kind == "verbatim" then
				ya.notify({ title = "Re-summarize row", content = name .. " is frozen (lock) — e 'My hint' can rewrite it", timeout = 6 })
				return
			end
			local pok, answer = pcall(ya.confirm, {
				title = "Re-summarize row",
				body = "Ask the agent to re-summarize " .. name .. "?",
				pos = { "center", w = 70, h = 9 },
			})
			step("confirm: shown=" .. tostring(pok) .. " yes=" .. tostring(answer))
			if not (pok and answer) then
				return
			end
			step("spawning " .. loc.rel)
			-- Row-level WIP signal: rewrite.mjs writes the marker row before
			-- spawning the agent, so one forced render shows it immediately.
			ya.notify({ title = "Re-summarize row", content = "Rewriting " .. name .. "…", timeout = 6 })
			local child = Command("node"):arg({
				REWRITE,
				"--root",
				loc.root,
				"--cache",
				CACHE,
				"--overrides",
				OVR,
				"--rel",
				loc.rel,
				"--hint",
				kind == "hint" and hint or "",
			}):spawn()
			refresh()
			local succeeded = false
			if child then
				-- Poll instead of wait: each tick re-renders the UI so the
				-- row's rewriting marker pulses. Cap ~2min (agent timeout).
				local status = nil
				for _ = 1, 400 do
					ya.sleep(0.3)
					local okw, st = pcall(function()
						return child:try_wait()
					end)
					status = okw and st or nil
					refresh()
					if status then
						break
					end
				end
				succeeded = status and status.success or false
			end
			step("done=" .. tostring(succeeded))
			pub_changed()
			refresh()
			if succeeded then
				ya.notify({ title = "Re-summarize row", content = name .. " rewritten", timeout = 6 })
			else
				ya.notify({ title = "Re-summarize row", content = name .. " failed — kept old text", timeout = 8 })
			end
			step("exit")
		end)
		if not ok then
			step("died: " .. tostring(err))
		end
	end,
}
