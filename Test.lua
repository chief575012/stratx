--[[
	StratX - Engine v2 (rewritten from scratch)
	===========================================
	SAME public API as the original TDS (your existing strats run UNEDITED),
	but a fundamentally different engine underneath:

	  OLD: 11 files, each action busy-polls `repeat task.wait() until ...`,
	       and the wave was read once into a local that never updated -> froze.

	  NEW: one file, a single event-driven scheduler. Actions YIELD their
	       coroutine and are resumed by Roblox signals (wave attribute change,
	       timer .Changed, game-over) instead of spinning every frame. A wave
	       that is reached OR overshot always fires; nothing can freeze on an
	       exact-match that never happens.

	Load with:
	  loadstring(game:HttpGet("https://raw.githubusercontent.com/chief575012/stratx/refs/heads/main/TDS/ImprovedVersion/Engine.lua"))()

	Strat syntax (unchanged from original — dot OR colon both work):
	  local s = Strat.new()
	  s.Loadout("Ace Pilot","Commander","Farm")
	  s.Map("Pizza Party", true, "Survival")
	  s.Place("Farm",      10,0,25, 1,0,30)   -- 1st Place  => tower index 1
	  s.Place("Ace Pilot", -5,0,12, 2,0,10)   -- 2nd Place  => tower index 2
	  s.Upgrade(1, 2,0,20, false, 1)          -- upgrade index 1, path 1
	  s.Target(2, "Strong", 3,0,0)
	  s.Ability(2, "Barrage", 4,0,5)
	  s.Option(1, "SellRefund", true, 5,0,0)
	  s.AutoChain(2,3,4, 6,0,0)
	  s.SellAllFarms(8,0,0)
	  s.Skip(9,0,5)
]]

-- ════════════════════════════ Services ════════════════════════════
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService   = game:GetService("TeleportService")
local LocalPlayer       = Players.LocalPlayer

local INGAME_PLACE_ID = 5591597781
local LOBBY_PLACE_ID  = 3260590327

local function CheckPlace()
	return game.PlaceId == INGAME_PLACE_ID
end

local RemoteFunction = ReplicatedStorage:WaitForChild("RemoteFunction", 30)
local RemoteEvent    = ReplicatedStorage:WaitForChild("RemoteEvent", 30)

-- ════════════════════════════ Logging ═════════════════════════════
local function Log(kind, msg)
	local sink = ({Info = ConsoleInfo, Warn = ConsoleWarn, Error = ConsoleError})[kind]
	if type(sink) == "function" then sink(msg)
	else print("[StratX]", "["..kind.."]", msg) end
end

-- ═══════════════ Positional → named arg patcher ═══════════════════
-- Copied verbatim (logic-wise) from the proven ConvertFunc so existing
-- strats that pass positional args convert identically.
local Patcher = {
	Mode = function(name) return { Name = name } end,
	Map = function(name, solo, mode)
		return { Map = name or "", Solo = solo ~= false, Mode = mode or "Survival" }
	end,
	Loadout = function(...)
		local list = {...}
		for i = #list, 1, -1 do
			if type(list[i]) == "string" and list[i]:lower() == "nil" then table.remove(list, i) end
		end
		return list
	end,
	Place = function(troop, x, y, z, wave, min, sec, rotate, rx, ry, rz, inbetween)
		return {
			TowerName = troop, TypeIndex = "",
			Position  = Vector3.new(x or 0, y or 0, z or 0),
			Rotation  = CFrame.Angles(rx or 0, ry or 0, rz or 0),
			Wave = wave, Minute = min, Second = sec,
			InBetween = (type(inbetween) == "boolean" and inbetween) or rotate or false,
		}
	end,
	Upgrade = function(troop, wave, min, sec, inbetween, path)
		return { TowerIndex = troop, TypeIndex = "", Wave = wave, Minute = min,
		         Second = sec, InBetween = inbetween or false, PathTarget = path or 1 }
	end,
	Sell = function(troop, wave, min, sec, inbetween)
		return { TowerIndex = type(troop) == "table" and troop or {troop}, TypeIndex = "",
		         Wave = wave, Minute = min, Second = sec, InBetween = inbetween or false }
	end,
	Skip = function(wave, min, sec, inbetween)
		return { Wave = wave, Minute = min, Second = sec, InBetween = inbetween or false }
	end,
	LeaveOn = function(wave, min, sec, inbetween)
		return { Wave = wave, Minute = min, Second = sec, InBetween = inbetween or false }
	end,
	Ability = function(troop, name, wave, min, sec, inbetween, data)
		return { TowerIndex = troop, TypeIndex = "", Ability = name, Wave = wave,
		         Minute = min, Second = sec, InBetween = inbetween or false, Data = data }
	end,
	Target = function(troop, target_a, target_b, min, sec, inbetween)
		return { TowerIndex = troop, TypeIndex = "",
		         Wave   = type(target_a) == "number" and target_a or target_b,
		         Target = type(target_b) == "string" and target_b or target_a,
		         Minute = min, Second = sec, InBetween = inbetween or false }
	end,
	AutoChain = function(t1, t2, t3, wave, min, sec, inbetween)
		return { TowerIndex1 = t1, TowerIndex2 = t2, TowerIndex3 = t3, Wave = wave,
		         Minute = min, Second = sec, InBetween = inbetween or false }
	end,
	SellAllFarms = function(wave, min, sec, inbetween)
		return { Wave = wave, Minute = min, Second = sec, InBetween = inbetween or false }
	end,
	Option = function(troop, name, value, wave, min, sec, inbetween)
		return { TowerIndex = troop, TypeIndex = "", Name = name, Value = value,
		         Wave = wave, Minute = min, Second = sec, InBetween = inbetween or false }
	end,
	SelectLoadout = function(gamesetloadout)
		return { GameSetLoadout = gamesetloadout }
	end,
}

-- ════════════════ Live game state (signal sources) ════════════════
local _rep
local function Replicator()
	if not _rep then
		local sr = ReplicatedStorage:FindFirstChild("StateReplicators")
		_rep = sr and sr:FindFirstChild("GameStateReplicator")
	end
	return _rep
end

local function GetWave()
	local r = Replicator()
	return r and tonumber(r:GetAttribute("Wave")) or nil
end

local function IsGameOver()
	local r = Replicator()
	return (r and r:GetAttribute("GameOver")) and true or false
end

local function TimerValue()
	local state = ReplicatedStorage:FindFirstChild("State")
	local timer = state and state:FindFirstChild("Timer")
	local t     = timer and timer:FindFirstChild("Time")
	return t and t.Value or nil
end

local function TimerObject()
	local state = ReplicatedStorage:FindFirstChild("State")
	local timer = state and state:FindFirstChild("Timer")
	return timer and timer:FindFirstChild("Time")
end

-- ═══════════════════ Event-driven wait primitive ══════════════════
-- Yields the running coroutine until ANY of the given signals fires, then
-- disconnects them all. This is the core "different mechanism": no per-frame
-- task.wait() polling — the coroutine sleeps until the game tells us something
-- relevant changed.
local function waitAny(signals)
	local co = coroutine.running()
	local conns, done = {}, false
	local function wake()
		if done then return end
		done = true
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		task.spawn(co)
	end
	for _, sig in ipairs(signals) do
		if sig then conns[#conns + 1] = sig:Connect(wake) end
	end
	if #conns == 0 then return end -- nothing to wait on; don't deadlock
	coroutine.yield()
end

-- A run token: bumped on match end so all in-flight actions abort cleanly.
local RunToken = { value = 0 }
local function snapshotToken() return RunToken.value end
local function aborted(token) return IsGameOver() or RunToken.value ~= token end

local function totalSeconds(min, sec) return (min or 0) * 60 + math.ceil(sec or 0) end

-- Wait until we reach (or pass) targetWave, then until the wave timer counts
-- down to the requested min:sec. Returns true to proceed, false if aborted.
local function awaitMoment(wave, min, sec, token)
	wave = tonumber(wave) or 0
	local rep = Replicator()
	local waveSignal = rep and rep:GetAttributeChangedSignal("Wave")
	local overSignal = rep and rep:GetAttributeChangedSignal("GameOver")

	-- Phase 1: reach the wave (event-driven, fires on >= so overshoot is fine)
	while true do
		if aborted(token) then return false end
		local w = GetWave()
		if w and w >= wave then break end
		waitAny({ waveSignal, overSignal })
	end

	-- Phase 2: reach the time within the wave
	local want = totalSeconds(min, sec)
	if (TimerValue() or 0) - want < -1 then
		return true -- already past this point in the wave
	end
	local timeObj = TimerObject()
	local timeSignal = timeObj and timeObj:GetPropertyChangedSignal("Value")
	while true do
		if aborted(token) then return false end
		local t = TimerValue()
		if t and (t - want) <= 1 then break end
		waitAny({ timeSignal, overSignal })
	end
	return true
end

-- ════════════════════════ Tower registry ══════════════════════════
-- Indices are assigned in the ORDER Place calls appear in the strat — exactly
-- like the original TowersContained.Index — so strats that reference "1","2"…
-- keep working unedited.
local Towers = { index = 0 }

-- Wait (event-driven-ish, but tower spawns aren't a single signal so we poll
-- lightly) until a tower index has a live instance, or the run aborts.
local function awaitInstance(index, token)
	while true do
		if aborted(token) then return nil end
		local e = Towers[index]
		if e and e.instance and e.placed then return e.instance end
		task.wait(0.05)
	end
end

-- ═══════════════════════ Action implementations ═══════════════════
-- Each returns quickly; the real work runs in a coroutine that yields on
-- signals. `info` is the named table produced by the Patcher.
local Actions = {}

function Actions.Loadout(info)
	if CheckPlace() then return end -- equipping is a lobby action
	task.spawn(function()
		local owned = RemoteFunction:InvokeServer("Session", "Search", "Inventory.Troops")
		if type(owned) ~= "table" then Log("Error", "Loadout: inventory read failed") return end
		for name, data in pairs(owned) do
			if data.Equipped then RemoteEvent:FireServer("Inventory", "Unequip", "Tower", name) end
		end
		for _, name in ipairs(info) do
			RemoteEvent:FireServer("Inventory", "Equip", "tower", name)
		end
		Log("Info", "Loadout set: " .. table.concat(info, ", "))
	end)
end

-- Map / Mode are mostly lobby/recording concerns; keep them accepted so strats
-- that call them don't error. Stored for any matchmaking logic to read.
function Actions.Map(info)  getgenv().StratX_Map  = info end
function Actions.Mode(info) getgenv().StratX_Mode = info end

function Actions.Place(info, index, token)
	-- index was assigned synchronously by the drain loop (see below)
	if not CheckPlace() then return end
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token) then return end
		local result
		local warnedAt = os.clock()
		repeat
			if aborted(token) then return end
			result = RemoteFunction:InvokeServer("Troops", "Place", info.TowerName, {
				["Position"] = info.Position,
				["Rotation"] = info.Rotation or CFrame.new(),
			})
			if typeof(result) ~= "Instance" then
				if os.clock() - warnedAt > 45 then
					Log("Error", ("Index %d (%s) not placed in 45s. Result: %s")
						:format(index, tostring(info.TowerName), tostring(result)))
					warnedAt = os.clock()
				end
				task.wait()
			end
		until typeof(result) == "Instance"
		result.Name = tostring(index)
		Towers[index].instance = result
		Towers[index].placed   = true
		Log("Info", ("Placed %s (index %d) @ wave %s %d:%02d")
			:format(tostring(info.TowerName), index, tostring(info.Wave), info.Minute or 0, info.Second or 0))
	end)
end

function Actions.Upgrade(info, _, token)
	if not CheckPlace() then return end
	local idx, path = info.TowerIndex, tonumber(info.PathTarget) or 1
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token) then return end
		local inst = awaitInstance(idx, token); if not inst then return end
		local ok, deadline = nil, os.clock() + 50
		repeat
			if aborted(token) then return end
			ok = RemoteFunction:InvokeServer("Troops", "Upgrade", "Set", { ["Troop"] = inst, ["Path"] = path })
			if not (type(ok) == "boolean" and ok) then task.wait() end
		until (type(ok) == "boolean" and ok) or os.clock() > deadline
		if type(ok) == "boolean" and ok then
			local e = Towers[idx]
			if path == 1 then e.topPath = (e.topPath or 0) + 1 else e.botPath = (e.botPath or 0) + 1 end
			Log("Info", ("Upgraded index %d path %d"):format(idx, path))
		else
			Log("Error", ("Failed upgrade index %d path %d"):format(idx, path))
		end
	end)
end

function Actions.Sell(info, _, token)
	if not CheckPlace() then return end
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token) then return end
		for _, idx in ipairs(info.TowerIndex) do
			task.spawn(function()
				local inst = awaitInstance(idx, token); if not inst then return end
				local ok
				repeat
					if aborted(token) then return end
					ok = RemoteFunction:InvokeServer("Troops", "Sell", { ["Troop"] = inst })
					if not ok then task.wait() end
				until ok or not inst:FindFirstChild("HumanoidRootPart")
				Log("Info", ("Sold index %d"):format(idx))
			end)
		end
	end)
end

function Actions.Target(info, _, token)
	if not CheckPlace() then return end
	local idx = info.TowerIndex
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token) then return end
		local inst = awaitInstance(idx, token); if not inst then return end
		RemoteFunction:InvokeServer("Troops", "Target", "Set", { ["Troop"] = inst, ["Target"] = info.Target })
		Log("Info", ("Target of index %d -> %s"):format(idx, tostring(info.Target)))
	end)
end

function Actions.Ability(info, _, token)
	if not CheckPlace() then return end
	local idx = info.TowerIndex
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token) then return end
		local inst = awaitInstance(idx, token); if not inst then return end
		local ok, deadline = nil, os.clock() + 50
		repeat
			if aborted(token) then return end
			ok = RemoteFunction:InvokeServer("Troops", "Abilities", "Activate", {
				["Troop"] = inst, ["Name"] = info.Ability, ["Data"] = info.Data })
			if not (type(ok) == "boolean" and ok) then task.wait() end
		until (type(ok) == "boolean" and ok) or os.clock() > deadline
		Log("Info", ("Ability %s on index %d"):format(tostring(info.Ability), idx))
	end)
end

function Actions.Option(info, _, token)
	if not CheckPlace() then return end
	local idx = info.TowerIndex
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token) then return end
		local inst = awaitInstance(idx, token); if not inst then return end
		local ok, deadline = nil, os.clock() + 50
		repeat
			if aborted(token) then return end
			ok = RemoteFunction:InvokeServer("Troops", "Option", "Set", {
				["Troop"] = inst, ["Name"] = info.Name, ["Value"] = info.Value })
			if not (type(ok) == "boolean" and ok) then task.wait() end
		until (type(ok) == "boolean" and ok) or os.clock() > deadline
		Log("Info", ("Option %s=%s on index %d"):format(tostring(info.Name), tostring(info.Value), idx))
	end)
end

function Actions.SellAllFarms(info, _, token)
	if not CheckPlace() then return end
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token) then return end
		local sold = 0
		for i, e in pairs(Towers) do
			if type(e) == "table" and e.name == "Farm" and e.instance then
				RemoteFunction:InvokeServer("Troops", "Sell", { ["Troop"] = e.instance })
				sold += 1
			end
		end
		Log("Info", ("Sold all farms (%d)"):format(sold))
	end)
end

function Actions.AutoChain(info, _, token)
	if not CheckPlace() then return end
	local ids = { info.TowerIndex1, info.TowerIndex2, info.TowerIndex3 }
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token) then return end
		for _, idx in ipairs(ids) do if not awaitInstance(idx, token) then return end end
		Log("Info", "AutoChain enabled: " .. table.concat(ids, ", "))
		while true do
			if aborted(token) then return end
			for _, idx in ipairs(ids) do
				local e = Towers[idx]
				if not (e and e.instance) then Log("Info", "AutoChain stopped (index " .. idx .. " gone)") return end
				if (e.topPath or 0) >= 2 then
					local ok
					repeat
						if aborted(token) then return end
						ok = RemoteFunction:InvokeServer("Troops", "Abilities", "Activate", {
							["Troop"] = e.instance, ["Name"] = "Call Of Arms" })
						if not (type(ok) == "boolean" and ok) then task.wait() end
					until type(ok) == "boolean" and ok
					task.wait(10) -- cooldown
				end
			end
			task.wait()
		end
	end)
end

function Actions.Skip(info, _, token)
	if not CheckPlace() then return end
	if tonumber(info.Wave) == 0 then return end
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token) then return end
		local ok
		repeat
			if aborted(token) then return end
			ok = RemoteFunction:InvokeServer("Voting", "Skip")
			if not (type(ok) == "boolean" and ok) then task.wait() end
		until type(ok) == "boolean" and ok
		Log("Info", "Skipped wave " .. tostring(info.Wave))
	end)
end

function Actions.LeaveOn(info, _, token)
	if not CheckPlace() then return end
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token) then return end
		Log("Info", ("Left on wave %s"):format(tostring(info.Wave)))
		-- restart/rejoin handled by the host loader; just signal it
		if type(getgenv().StratX_OnLeave) == "function" then getgenv().StratX_OnLeave(info) end
	end)
end

-- Recorder emits this in the lobby; the in-game engine just accepts it as a no-op
-- so recorded strats that include it don't error.
function Actions.SelectLoadout(info)
	getgenv().StratX_SelectedLoadout = info.GameSetLoadout
end

-- The set of valid action names (drives the proxy).
local ACTION_NAMES = {
	"Loadout","SelectLoadout","Map","Mode","Place","Upgrade","Sell","Target",
	"Ability","Option","SellAllFarms","AutoChain","Skip","LeaveOn",
}

-- ══════════════════════════ Strat proxy ═══════════════════════════
-- Recreates the original Strat.new() object: each action name is callable
-- with positional args, queued, then drained in order. Dot and colon calls
-- both work (colon passes the strat as the first arg, which we strip).
local Strat = {}
Strat.__index = Strat

function Strat.new()
	local self = setmetatable({ queues = {}, _started = false }, Strat)
	for _, name in ipairs(ACTION_NAMES) do
		self.queues[name] = {}
		self[name] = function(...)
			local args = {...}
			-- strip leading self for colon-call syntax: s:Place(...)
			if args[1] == self then table.remove(args, 1) end
			local patch = Patcher[name]
			local info  = patch and patch(table.unpack(args)) or { table.unpack(args) }
			table.insert(self.queues[name], info)
			-- Place must reserve its index immediately, in call order
			if name == "Place" then
				Towers.index += 1
				info._index = Towers.index
				Towers[info._index] = { name = info.TowerName, instance = nil, placed = false }
			end
		end
	end
	getgenv().Strat = Strat -- expose the class so Strat.new() works globally if needed
	task.defer(function() self:Run() end) -- auto-run once the strat finishes queueing
	return self
end

function Strat:Run()
	if self._started then return end
	self._started = true
	local token = snapshotToken()
	for _, name in ipairs(ACTION_NAMES) do
		local queue = self.queues[name]
		task.spawn(function()
			for _, info in ipairs(queue) do
				if aborted(token) then return end
				Actions[name](info, info._index, token)
			end
		end)
	end
	Log("Info", "Strat running (" .. #self.queues.Place .. " towers queued)")
end

-- ═══════════════ Abort + reset when a match ends ══════════════════
task.spawn(function()
	local r = Replicator()
	if not r then return end
	r:GetAttributeChangedSignal("GameOver"):Connect(function()
		if r:GetAttribute("GameOver") then
			RunToken.value += 1 -- aborts every in-flight action
			for k in pairs(Towers) do if k ~= "index" then Towers[k] = nil end end
			Towers.index = 0
			Log("Info", "Match ended — actions aborted, towers cleared")
		end
	end)
end)

getgenv().Strat = Strat
Log("Info", "StratX Engine v2 loaded. CheckPlace = " .. tostring(CheckPlace()))
-- Recorded strats do `local TDS = loadstring(...)()` then `TDS:Place(...)`,
-- so we must return a ready-to-use strat INSTANCE, not the class.
return Strat.new()
