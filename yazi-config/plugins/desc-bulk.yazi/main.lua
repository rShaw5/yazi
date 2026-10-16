-- desc-bulk: M-R re-summarizes the current folder (or Space-selected rows),
-- m-r re-summarizes just the hovered row ("hovered" arg; selection ignored).
-- Rows under planning-system keep tree-relative rels; rows anywhere else on
-- disk run from their own parent (desc-row's outside-tree convention).
-- Verbatim rows sit out; hint rows reuse their saved hints; unpinned rows get
-- a generic agent pass (which does not pin them). Sequential background loop
-- with per-row refresh and a closing summary.
local ROOT = "/Users/robinshaw/Code/planning-system"
local REWRITE = "/Users/robinshaw/Code/yazi/spike-descriptions/rewrite.mjs"
local CACHE = "/Users/robinshaw/Code/yazi/spike-descriptions/desc-cache.tsv"
local OVR = "/Users/robinshaw/Code/yazi/spike-descriptions/overrides.tsv"
local SKIP = { [".git"] = true, ["node_modules"] = true }
-- Matches rewrite.mjs/init.lua: while a row carries this marker the linemode
-- pulses it, so bulk pre-marks every queued row before the job loop starts.
local MARKER = "… rewriting description …"

-- cx lives in the sync context; pull plain sendable values out of it here.
-- Only the selection is read here (pairs() works on it); the folder listing
-- uses fs.read_dir() in entry instead — current.files is an opaque userdata
-- that pairs() cannot enumerate in yazi 26.9.1.
local get_selected = ya.sync(function()
	local out = {}
	local sel = cx.active.selected
	local nok, n = pcall(function()
		return #sel
	end)
	if nok and n > 0 then
		pcall(function()
			for _, f in pairs(sel) do
				local ou, u = pcall(function()
					return f.url
				end)
				if ou and u ~= nil then
					local os, s = pcall(tostring, u)
					if os and type(s) == "string" then
						local om, m = pcall(function()
							return f.cha.mtime
						end)
						out[#out + 1] = { path = s, mt = (om and type(m) == "number") and m or nil }
					end
				end
			end
		end)
	end
	local cwd = nil
	local oc, c = pcall(function()
		return cx.active.current.cwd
	end)
	if oc and c ~= nil then
		local os, s = pcall(tostring, c)
		if os and type(s) == "string" then
			cwd = s
		end
	end
	return { paths = out, cwd = cwd }
end)

-- Reload the linemode immediately after each row's cache rewrite lands.
local pub_changed = ya.sync(function()
	ps.pub("desc-cache-changed", {})
end)

-- ui.render() is sync-context only; wrap it once so entry can call it.
local render_now = ya.sync(function()
	ui.render()
end)

-- Hovered row for the "hovered" arg mode; nil when nothing is under the cursor.
local get_hovered = ya.sync(function()
	local h = cx.active.current.hovered
	if not h then
		return nil
	end
	local ok, s = pcall(tostring, h.url)
	return ok and s or nil
end)

local function refresh()
	pcall(ya.emit, "refresh", {})
	render_now()
end

-- Row reference: inside the pinned ROOT keep the tree-relative rel (the
-- same keys the probe and the descs use).
local function row_ref(apath)
	if type(apath) ~= "string" then
		return nil
	end
	if apath:sub(1, #ROOT + 1) == ROOT .. "/" then
		return { rel = apath:sub(#ROOT + 2), root = ROOT }
	end
	-- Outside the tree: absolute path as the row key, the row's own parent
	-- as runtime root — the same convention desc-row uses for hovering
	-- outside planning-system, so M-R works in any folder on disk.
	local parent = apath:match("^(.*/)[^/]+$")
	if parent then
		return { rel = apath, root = parent }
	end
	return nil
end

-- Step log: desc-bulk once hung before its first visible output, and
-- ya.err doesn't reach yazi.log on this build. Appends each phase to
-- desc-bulk.log instead: tail -f ~/Code/yazi/spike-descriptions/desc-bulk.log
local LOGF = "/Users/robinshaw/Code/yazi/spike-descriptions/desc-bulk.log"
local function step(msg)
	local lg = io.open(LOGF, "a")
	if lg then
		lg:write(os.date("%H:%M:%S ") .. msg .. "\n")
		lg:close()
	end
end

-- rel -> { kind, text } from overrides.tsv.
local function load_pins()
	local t = {}
	local f = io.open(OVR, "r")
	if not f then
		return t
	end
	for line in f:lines() do
		if line ~= "" then
			local tab = line:find("	", 1, true)
			if tab then
				local kind, text = line:sub(tab + 1):match("^([^\t]*)\t?(.*)$")
				t[line:sub(1, tab - 1)] = { kind = kind, text = text }
			end
		end
	end
	f:close()
	return t
end

-- cha.mtime is missing on fs.read_dir File objects here, and Command:output()
-- didn't deliver either; io.popen("stat -f %m") is the pattern init.lua
-- already proves works on this build. Returns floor seconds, or nil.
local function stat_secs(apath)
	local quoted = '"' .. apath:gsub('"', '\\"') .. '"'
	local p = io.popen('stat -f %m ' .. quoted .. ' 2>/dev/null')
	if not p then
		return nil
	end
	local s = p:read("*l")
	p:close()
	local n = tonumber(s)
	if n then
		return math.floor(n)
	end
	return nil
end

-- Absolute path of a job row (tree rows rel under ROOT; outside rows are abs).
local function job_abs(job)
	if job.rel:sub(1, 1) == "/" then
		return job.rel
	end
	return ROOT .. "/" .. job.rel
end

-- Pre-mark every queued row with the "… rewriting …" marker so ALL rows
-- pulse for the whole run, not just the one job in flight. Keys use the
-- file's own mtime in seconds — the only part init.lua checks to render a
-- desc — and each job keeps its original cache line so a failure restores
-- real text instead of leaving a pulsing ghost.
local function premark(jobs)
	local map = {}
	local mt_sample_logged = false
	local f = io.open(CACHE, "r")
	if f then
		for line in f:lines() do
			if line ~= "" then
				local t = line:find("\t", 1, true)
				if t then
					map[line:sub(1, t - 1)] = line
				end
			end
		end
		f:close()
	end
	for _, job in ipairs(jobs) do
		job.orig = map[job.rel]
		if not job.mt then
			job.mt = stat_secs(job_abs(job))
			if not mt_sample_logged then
				mt_sample_logged = true
				step("fallback mt: " .. job.rel .. " -> " .. tostring(job.mt))
			end
		end
		if job.mt then
			map[job.rel] = job.rel .. "\t" .. tostring(math.floor(job.mt)) .. "\t" .. MARKER .. "\t"
		end
	end
	local lines = {}
	for _, line in pairs(map) do
		lines[#lines + 1] = line
	end
	table.sort(lines)
	local wf = io.open(CACHE, "w")
	if wf then
		wf:write(table.concat(lines, "\n") .. "\n")
		wf:close()
	end
end

-- Put one job's pre-bulk line back (drop the row entirely when it had none).
local function restore_orig(job)
	local lines = {}
	local f = io.open(CACHE, "r")
	if f then
		for line in f:lines() do
			if line ~= "" then
				local t = line:find("\t", 1, true)
				local rel = t and line:sub(1, t - 1) or ""
				if rel ~= job.rel then
					lines[#lines + 1] = line
				end
			end
		end
		f:close()
	end
	if job.orig then
		lines[#lines + 1] = job.orig
	end
	table.sort(lines)
	local wf = io.open(CACHE, "w")
	if wf then
		wf:write(table.concat(lines, "\n") .. "\n")
		wf:close()
	end
end
-- Plugin args are a dead end on this build (rt.args panics the scheduler
	-- from sync and async contexts alike); row mode lives in desc-row.yazi.
return {
	entry = function()
		-- Every visible symptom this plugin ever produced disappeared before a
		-- toast could render; the pcall net converts any error into a log line.
		local ok, err = pcall(function()
			local tg
			step("entry")
			step("folder/selection: reading state")
			local got = get_selected()
			step("folder/selection: got paths=" .. #got.paths)
			if #got.paths > 0 then
				tg = { mode = "selected", paths = got.paths }
			elseif got.cwd then
				-- The options table is required on this build; omitting it
				-- died with "error converting Lua nil to table".
				local files, ferr = fs.read_dir(Url(got.cwd), {})
				if files then
					local out = {}
					for _, f in ipairs(files) do
						local ou, u = pcall(function()
							return f.url
						end)
						if ou and u ~= nil then
							local os, s = pcall(tostring, u)
							if os and type(s) == "string" then
								local om, m = pcall(function()
									return f.cha.mtime
								end)
								out[#out + 1] = { path = s, mt = (om and type(m) == "number") and m or nil }
							end
						end
					end
					tg = { mode = "folder", paths = out }
				else
					step("read_dir err: " .. tostring(ferr))
					tg = { mode = "failed", paths = {} }
				end
			else
				tg = { mode = "failed", paths = {} }
			end
		if tg.mode == "failed" or #tg.paths == 0 then
			ya.notify({ title = "Bulk rewrite", content = "Nothing to rewrite", timeout = 4 })
			return
		end
		local pins = load_pins()
		local jobs = {}
		for _, item in ipairs(tg.paths) do
			local ref = row_ref(item.path)
			if ref then
				local name = ref.rel:match("([^/]+)$") or ref.rel
				if not SKIP[name] then
					local pin = pins[ref.rel]
					if not (pin and pin.kind == "verbatim") then
						local hint = ""
						if pin and pin.kind == "hint" and pin.text ~= "" then
							hint = pin.text
						end
						jobs[#jobs + 1] = { rel = ref.rel, name = name, root = ref.root, mt = item.mt, hint = hint }
					else
						step("skip: " .. ref.rel .. " (verbatim pin)")
					end
				else
					step("skip: " .. name .. " (builtin skip)")
				end
			else
				step("skip-badpath: " .. tostring(item.path))
			end
		end
		step("mode=" .. tg.mode .. " listed=" .. #tg.paths .. " jobs=" .. #jobs)
		step("mt1=" .. tostring(jobs[1] and jobs[1].mt))
		if #jobs == 0 then
			if tg.mode == "selected" then
				ya.notify({
					title = "Bulk rewrite",
					content = "0 of " .. #tg.paths .. " selected rows to rewrite (each is frozen or skipped) — Esc clears the marks for a whole-folder rewrite",
					timeout = 6,
				})
			else
				ya.notify({
					title = "Bulk rewrite",
					content = "0 of " .. #tg.paths .. " rows to rewrite (every row is frozen or skipped)",
					timeout = 6,
				})
			end
			return
		end
		local scope
		if tg.mode == "selected" then
			scope = #jobs .. " selected rows"
		else
			scope = "this folder"
		end
		local pok, answer = pcall(ya.confirm, {
			title = "Bulk rewrite",
			body = "Ask the agent to re-summarize " .. scope .. "?",
			pos = { "center", w = 70, h = 9 },
		})
		step("confirm: shown=" .. tostring(pok) .. " yes=" .. tostring(answer))
		if not (pok and answer) then
			return
		end
		local done, failed = 0, 0
		premark(jobs)
		ya.notify({ title = "Bulk rewrite", content = "Rewriting " .. #jobs .. " rows…", timeout = 6 })
		pub_changed()
		refresh()
		for i, job in ipairs(jobs) do
			step("job " .. i .. "/" .. #jobs .. " " .. job.rel .. " spawning")
			local child = Command("node"):arg({
				REWRITE,
				"--root",
				job.root,
				"--cache",
				CACHE,
				"--overrides",
				OVR,
				"--rel",
				job.rel,
				"--hint",
				job.hint,
			}):spawn()
			local succeeded = false
			if child then
				-- Poll instead of wait: one forced render shows the row's
				-- rewriting marker immediately, then each tick pulses it.
				refresh()
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
			step("job " .. i .. "/" .. #jobs .. " done=" .. tostring(succeeded))
			if succeeded then
				done = done + 1
			else
				failed = failed + 1
				-- rewrite.mjs restores "prev" from its own load, which after
				-- premark is the marker itself; put the true pre-bulk row back.
				restore_orig(job)
			end
			pub_changed()
			refresh()
		end
		local summary = done .. " rewritten"
		if failed > 0 then
			summary = summary .. ", " .. failed .. " failed (old text kept)"
		end
		ya.notify({ title = "Bulk rewrite", content = summary, timeout = 8 })
		step("exit: " .. summary)
		end)
		if not ok then
			step("died: " .. tostring(err))
		end
	end,
}
