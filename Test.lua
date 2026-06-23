--[[
	StratX - Engine v3 (self-contained, full feature port)
	======================================================
	SAME public API as the original TDS (run recorded strats UNEDITED), but the
	whole thing lives in ONE file with its own internal library state (`Lib`),
	so MatchMaking, the elevator-join lobby path, loadout buy/equip, and the
	restart-after-loss loop all work without the multi-file StratXLibrary.

	Engine: event-driven wave/timer waiting (no busy-poll freeze). Live wave from
	GameStateReplicator attributes. A reached-or-overshot wave always fires.

	Load (lobby AND in-game both run this same file):
	  local TDS = loadstring(game:HttpGet(".../TDS/ImprovedVersion/Engine.lua"))()
	  TDS:Map("Pizza Party", true, "Survival")
	  TDS:Loadout({"Ace Pilot","Commander","Farm"})
	  TDS:Mode("Fallen")
	  TDS:Place("Ace Pilot", 17.1,0.9,37.7, 2,0,10)
	  TDS:Upgrade(1, 3,0,20, false, 1)
	  TDS:Skip(9,0,5)

	NOTE: I can't run Roblox Lua, so this is untested until you run it in-game.
	If a line errors, send me the `:<line>: <message>` and I'll pinpoint it.
]]

-- ════════════════════════════ Services ════════════════════════════
local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService   = game:GetService("TeleportService")
local Marketplace       = game:GetService("MarketplaceService")
local LocalPlayer       = Players.LocalPlayer

local INGAME_PLACE_ID = 5591597781
local LOBBY_PLACE_ID  = 3260590327
local GAMEPASS_CHANGE_MAP = 10518590

local function CheckPlace() return game.PlaceId == INGAME_PLACE_ID end

local RemoteFunction = ReplicatedStorage:WaitForChild("RemoteFunction", 30)
local RemoteEvent    = ReplicatedStorage:WaitForChild("RemoteEvent", 30)

-- ════════════════════════════ Logging ═════════════════════════════
local function Log(kind, msg)
	local sink = ({Info = ConsoleInfo, Warn = ConsoleWarn, Error = ConsoleError})[kind]
	if type(sink) == "function" then sink(msg)
	else print("[StratX]", "["..kind.."]", msg) end
end

-- ════════════════════════════ Config ══════════════════════════════
-- Read from getgenv flags, same names the original honored.
local Config = {
	PreferMatchmaking = getgenv().PreferMatchmaking or getgenv().Matchmaking or false,
	RestartMatch      = getgenv().AutoRestart or false,
	AutoSkip          = getgenv().AutoSkip or false,
	AutoBuyMissing    = getgenv().BuyMissingTowers or false,
	WeeklyChallenge   = getgenv().WeeklyChallenge or false,
	EventEasyMode     = getgenv().EventEasyMode or false,
}

-- ════════════════════════ Internal library ════════════════════════
local Lib = {
	Strat = {},                 -- array of strat instances
	Global = { Map = {} },      -- shared map registry (like StratXLibrary.Global.Map)
	RestartCount = 0,
	CurrentCount = 0,
}

-- ═══════════════ Positional → named arg patcher ═══════════════════
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
		local golden = getgenv().GoldenPerks or {}
		if #golden > 0 then list.Golden = golden end
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
	SelectLoadout = function(gamesetloadout) return { GameSetLoadout = gamesetloadout } end,
}

-- ════════════════ Special-map / difficulty tables ═════════════════
local SPECIAL_GAMEMODE = {
	["Pizza Party"]            = {mode = "halloween",      challenge = "PizzaParty"},
	["Badlands II"]            = {mode = "badlands",       challenge = "Badlands"},
	["Polluted Wasteland II"]  = {mode = "polluted",       challenge = "PollutedWasteland"},
	["Failed Gateway"]         = {mode = "halloween2024",  difficulty = "Act1", night = 1},
	["The Nightmare Realm"]    = {mode = "halloween2024",  difficulty = "Act2", night = 2},
	["Containment"]            = {mode = "halloween2024",  difficulty = "Act3", night = 3},
	["Pls Donate"]             = {mode = "plsDonate",      difficulty = "PlsDonateHard"},
	["Outpost 32"]             = {mode = "frostInvasion",  difficulty = "Hard"},
	["Classic Candy Cane Lane"]= {mode = "Event",          part = "ClassicRobloxPart1"},
	["Classic Winter"]         = {mode = "Event",          part = "ClassicRobloxPart2"},
	["Classic Forest Camp"]    = {mode = "Event",          part = "ClassicRobloxPart3"},
	["Classic Island Chaos"]   = {mode = "Event",          part = "ClassicRobloxPart4"},
	["Classic Castle"]         = {mode = "Event",          part = "ClassicRobloxPart5"},
}
local DIFF_VOTE = { Easy="Easy", Casual="Casual", Intermediate="Intermediate", Molten="Molten", Fallen="Fallen" }
local MAP_DIFF  = { Easy="Easy", Normal="Molten", Intermediate="Intermediate", Molten="Molten", Fallen="Fallen" }

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
local function StateValue(name)
	local state = ReplicatedStorage:FindFirstChild("State")
	local obj = state and state:FindFirstChild(name)
	return obj
end
local function TimerObject()
	local t = StateValue("Timer")
	return t and t:FindFirstChild("Time")
end
local function TimerValue()
	local o = TimerObject()
	return o and o.Value or nil
end

-- ═══════════════════ Event-driven wait primitive ══════════════════
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
	if #conns == 0 then task.wait() return end
	coroutine.yield()
end

local RunToken = { value = 0 }
local function snapshotToken() return RunToken.value end
local function aborted(token) return IsGameOver() or RunToken.value ~= token end
local function totalSeconds(min, sec) return (min or 0) * 60 + math.ceil(sec or 0) end

-- Wait until wave reached/overshot, then until the wave timer hits min:sec.
local function awaitMoment(wave, min, sec, token, debugFlag)
	wave = tonumber(wave) or 0
	local rep = Replicator()
	local waveSignal = rep and rep:GetAttributeChangedSignal("Wave")
	local overSignal = rep and rep:GetAttributeChangedSignal("GameOver")
	if debugFlag then return true end

	while true do
		if aborted(token) then return false end
		local w = GetWave()
		if w and w >= wave then break end
		waitAny({ waveSignal, overSignal })
	end

	local want = totalSeconds(min, sec)
	if (TimerValue() or 0) - want < -1 then return true end
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
local Towers = { index = 0 }
local function awaitInstance(index, token)
	while true do
		if aborted(token) then return nil end
		local e = Towers[index]
		if e and e.instance and e.placed then return e.instance end
		task.wait(0.05)
	end
end

-- ═══════════════════════ Action implementations ═══════════════════
-- Signature: (S, info, token). S is the strat instance.
local Actions = {}

function Actions.Loadout(S, info, token)
	local towers = {}
	for _, n in ipairs(info) do if type(n) == "string" then towers[#towers + 1] = n end end
	local golden = info.Golden or {}

	if CheckPlace() then
		task.spawn(function()
			local owned = RemoteFunction:InvokeServer("Session", "Search", "Inventory.Troops")
			if type(owned) ~= "table" then return end
			for _, n in ipairs(towers) do
				if not (owned[n] and owned[n].Equipped) then
					Log("Error", "Tower not equipped: " .. n .. ". Rejoining lobby")
					task.wait(1)
					TeleportService:Teleport(LOBBY_PLACE_ID, LocalPlayer)
					return
				end
			end
			Log("Info", "Loadout verified: " .. table.concat(towers, ", "))
		end)
		return
	end

	S.Loadout.AllowTeleport = false
	task.spawn(function()
		local owned = RemoteFunction:InvokeServer("Session", "Search", "Inventory.Troops")
		if type(owned) ~= "table" then Log("Error", "Loadout: inventory read failed") return end
		if Config.AutoBuyMissing then
			local missing = {}
			for _, n in ipairs(towers) do if not owned[n] then missing[#missing + 1] = n end end
			while #missing > 0 do
				owned = RemoteFunction:InvokeServer("Session", "Search", "Inventory.Troops")
				for i = #missing, 1, -1 do
					local n = missing[i]
					if owned[n] then table.remove(missing, i)
					else RemoteFunction:InvokeServer("Shop", "Purchase", "tower", n) end
				end
				task.wait(0.5)
			end
		end
		for name, data in pairs(owned) do
			if data.Equipped then RemoteEvent:FireServer("Inventory", "Unequip", "Tower", name) end
		end
		for _, n in ipairs(towers) do
			RemoteEvent:FireServer("Inventory", "Equip", "tower", n)
			local wantGolden = table.find(golden, n) ~= nil
			if owned[n] and owned[n].GoldenPerks and not wantGolden then
				RemoteEvent:FireServer("Inventory", "Unequip", "Golden", n)
			elseif wantGolden then
				RemoteEvent:FireServer("Inventory", "Equip", "Golden", n)
			end
		end
		S.Loadout.AllowTeleport = true
		Log("Info", "Loadout equipped: " .. table.concat(towers, ", "))
	end)
end

function Actions.Mode(S, info, token)
	getgenv().StratX_Mode = info
	if not CheckPlace() then return end
	local modeName = DIFF_VOTE[info.Name] or info.Name
	task.spawn(function()
		local voted
		local buttons = LocalPlayer.PlayerGui
			:WaitForChild("ReactGameDifficulty"):WaitForChild("Frame"):WaitForChild("buttons")
		repeat
			voted = RemoteFunction:InvokeServer("Difficulty", "Vote", modeName)
			task.wait()
		until voted
		local formatted = modeName:sub(1, 1):lower() .. modeName:sub(2)
		local countLabel = buttons:WaitForChild(formatted .. "Button"):WaitForChild("button")
			:WaitForChild("content"):WaitForChild("count"):WaitForChild("textLabel")
		if tostring(countLabel.Text) ~= "0" then
			RemoteFunction:InvokeServer("Difficulty", "Ready")
		end
		Log("Info", "Mode selected: " .. tostring(info.Name))
	end)
end

-- Map: in-game verifies the loaded map. Lobby join is handled centrally by
-- Strat:Join (special teleport / matchmaking / elevator), so Map here only
-- registers the target and (in-game) verifies.
function Actions.Map(S, info, token)
	getgenv().StratX_Map = info
	Lib.Global.Map[(info.Map or "") .. ":" .. (info.Mode or "Survival")] = info
	if not CheckPlace() then return end
	task.spawn(function()
		local RSMap, RSMode = StateValue("Map"), StateValue("Mode")
		if not (RSMap and RSMode) then return end
		repeat task.wait() until typeof(RSMap.Value) == "string" and RSMap.Value ~= "" and RSMode.Value ~= ""
		if RSMap.Value ~= info.Map then
			Log("Error", ("Wrong map: got '%s', expected '%s'"):format(RSMap.Value, tostring(info.Map)))
			return
		end
		Log("Info", ("Map verified: %s, Mode: %s, Solo: %s"):format(RSMap.Value, tostring(info.Mode), tostring(info.Solo)))
	end)
end

function Actions.Place(S, info, token)
	if not CheckPlace() then return end
	local index = info._index
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token, info.Debug) then return end
		local result, warnedAt = nil, os.clock()
		repeat
			if aborted(token) then return end
			result = RemoteFunction:InvokeServer("Troops", "Place", info.TowerName, {
				["Position"] = info.Position, ["Rotation"] = info.Rotation or CFrame.new() })
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

function Actions.Upgrade(S, info, token)
	if not CheckPlace() then return end
	local idx, path = info.TowerIndex, tonumber(info.PathTarget) or 1
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token, info.Debug) then return end
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

function Actions.Sell(S, info, token)
	if not CheckPlace() then return end
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token, info.Debug) then return end
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

function Actions.Target(S, info, token)
	if not CheckPlace() then return end
	local idx = info.TowerIndex
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token, info.Debug) then return end
		local inst = awaitInstance(idx, token); if not inst then return end
		RemoteFunction:InvokeServer("Troops", "Target", "Set", { ["Troop"] = inst, ["Target"] = info.Target })
		Log("Info", ("Target of index %d -> %s"):format(idx, tostring(info.Target)))
	end)
end

function Actions.Ability(S, info, token)
	if not CheckPlace() then return end
	local idx = info.TowerIndex
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token, info.Debug) then return end
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

function Actions.Option(S, info, token)
	if not CheckPlace() then return end
	local idx = info.TowerIndex
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token, info.Debug) then return end
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

function Actions.SellAllFarms(S, info, token)
	if not CheckPlace() then return end
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token, info.Debug) then return end
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

function Actions.AutoChain(S, info, token)
	if not CheckPlace() then return end
	local ids = { info.TowerIndex1, info.TowerIndex2, info.TowerIndex3 }
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token, info.Debug) then return end
		for _, idx in ipairs(ids) do if not awaitInstance(idx, token) then return end end
		Log("Info", "AutoChain enabled: " .. table.concat(ids, ", "))
		while true do
			if aborted(token) then return end
			for _, idx in ipairs(ids) do
				local e = Towers[idx]
				if not (e and e.instance) then Log("Info", "AutoChain stopped (index " .. tostring(idx) .. " gone)") return end
				if (e.topPath or 0) >= 2 then
					local ok
					repeat
						if aborted(token) then return end
						ok = RemoteFunction:InvokeServer("Troops", "Abilities", "Activate", {
							["Troop"] = e.instance, ["Name"] = "Call Of Arms" })
						if not (type(ok) == "boolean" and ok) then task.wait() end
					until type(ok) == "boolean" and ok
					task.wait(10)
				end
			end
			task.wait()
		end
	end)
end

function Actions.Skip(S, info, token)
	if not CheckPlace() then return end
	if tonumber(info.Wave) == 0 then return end
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token, info.Debug) then return end
		local ok
		repeat
			if aborted(token) then return end
			ok = RemoteFunction:InvokeServer("Voting", "Skip")
			if not (type(ok) == "boolean" and ok) then task.wait() end
		until type(ok) == "boolean" and ok
		Log("Info", "Skipped wave " .. tostring(info.Wave))
	end)
end

function Actions.LeaveOn(S, info, token)
	if not CheckPlace() then return end
	task.spawn(function()
		if not awaitMoment(info.Wave, info.Minute, info.Second, token, info.Debug) then return end
		Log("Info", ("Left on wave %s"):format(tostring(info.Wave)))
		if type(getgenv().StratX_OnLeave) == "function" then getgenv().StratX_OnLeave(info) end
	end)
end

function Actions.SelectLoadout(S, info, token)
	getgenv().StratX_SelectedLoadout = info.GameSetLoadout
end

local ACTION_NAMES = {
	"Loadout","SelectLoadout","Map","Mode","Place","Upgrade","Sell","Target",
	"Ability","Option","SellAllFarms","AutoChain","Skip","LeaveOn",
}

-- ════════════════════════════ Strat object ════════════════════════
local Strat = {}
Strat.__index = Strat
-- Map/Mode/Loadout REPLACE their list (one-shot), others APPEND (queue).
local REPLACE = { Map = true, Mode = true, Loadout = true }

function Strat.new()
	local self = setmetatable({}, Strat)
	self.Index = #Lib.Strat + 1
	for _, name in ipairs(ACTION_NAMES) do
		local category = { Name = name, Lists = {}, ListNum = 1, AllowTeleport = false }
		setmetatable(category, { __call = function(_, ...)
			local args = {...}
			if args[1] == self then table.remove(args, 1) end -- strip self for colon calls
			local info
			if #args == 1 and type(args[1]) == "table" then
				info = args[1]                                -- already a named table (recorder/Loadout)
			else
				info = Patcher[name] and Patcher[name](table.unpack(args)) or { table.unpack(args) }
			end
			if REPLACE[name] then category.Lists = { info } else table.insert(category.Lists, info) end
			if name == "Place" then
				Towers.index += 1
				info._index = Towers.index
				Towers[info._index] = { name = info.TowerName, instance = nil, placed = false }
			elseif name == "Mode" then
				getgenv().StratX_Mode = info
			end
			self.Active = true
		end })
		self[name] = category
	end
	table.insert(Lib.Strat, self)
	getgenv().Strat = Strat
	task.defer(function() self:Run() end)
	return self
end

-- ───────────── Lobby join: special / matchmaking / elevator ──────────────
local function SafeTeleport() end -- remotes return server refs; teleport is server-driven

function Strat:Join(token)
	local mapInfo = self.Map.Lists[1]
	if not mapInfo then return end
	local mapName = mapInfo.Map
	local mode    = mapInfo.Mode or "Survival"

	-- wait until loadout finished equipping
	if self.Loadout and not self.Loadout.AllowTeleport and #self.Loadout.Lists > 0 then
		Log("Info", "Waiting for loadout to equip…")
		repeat task.wait() until self.Loadout.AllowTeleport or aborted(token)
	end
	if aborted(token) then return end

	if mapName == "Tutorial" then
		RemoteEvent:FireServer("Tutorial", "Start")
		Log("Info", "Teleporting to Tutorial"); return
	end

	-- Special gamemode maps: matchmaking-style create+start
	local special = SPECIAL_GAMEMODE[mapName]
	if Config.WeeklyChallenge then
		RemoteFunction:InvokeServer("Multiplayer", "v2:start",
			{ mode = "weeklyChallengeMap", count = 1, challenge = Config.WeeklyChallenge })
		Log("Info", "Weekly challenge: " .. tostring(Config.WeeklyChallenge)); return
	elseif special then
		RemoteFunction:InvokeServer("Multiplayer", "single_create")
		if special.mode == "halloween2024" then
			RemoteFunction:InvokeServer("Multiplayer", "v2:start", {
				difficulty = Config.EventEasyMode and (special.difficulty .. "Easy") or special.difficulty,
				night = special.night, count = 1, mode = special.mode })
		elseif special.mode == "plsDonate" then
			RemoteFunction:InvokeServer("Multiplayer", "v2:start", {
				difficulty = Config.EventEasyMode and "PlsDonate" or special.difficulty, count = 1, mode = special.mode })
		elseif special.mode == "frostInvasion" then
			RemoteFunction:InvokeServer("Multiplayer", "v2:start", {
				difficulty = Config.EventEasyMode and "Easy" or special.difficulty, mode = special.mode, count = 1 })
		elseif special.mode == "Event" then
			RemoteFunction:InvokeServer("EventMissions", "Start", special.part)
		else
			RemoteFunction:InvokeServer("Multiplayer", "v2:start",
				{ mode = special.mode, count = 1, challenge = special.challenge })
		end
		Log("Info", "Teleporting to special gamemode: " .. tostring(special.mode)); return
	end

	-- Decide: matchmaking (gamepass/private/prefer) vs elevator hopping
	local canChangeMap = false
	pcall(function() canChangeMap = Marketplace:UserOwnsGamePassAsync(LocalPlayer.UserId, GAMEPASS_CHANGE_MAP) end)
	local isPrivate = Workspace:GetAttribute("IsPrivateServer")
	if Config.PreferMatchmaking or isPrivate or canChangeMap then
		self:MatchMaking(mapInfo, canChangeMap)
	else
		self:ElevatorJoin(mapInfo, token)
	end
end

-- ───────────── MatchMaking: vote/override the target map ──────────────
function Strat:MatchMaking(mapInfo, canChangeMap)
	local mapName = mapInfo.Map
	local gameMode = Workspace:FindFirstChild("IntermissionLobby") and "Survival" or "Hardcore"
	local lobbyName = (gameMode == "Survival") and "IntermissionLobby" or "HardcoreIntermissionLobby"
	local lobby = Workspace:FindFirstChild(lobbyName)
	if not lobby then Log("Warn", "MatchMaking: no intermission lobby"); return end

	local function boardMaps()
		local list = {}
		for _, v in next, lobby:WaitForChild("Boards"):GetChildren() do
			local ok, title = pcall(function()
				return v.Hitboxes.Bottom.MapDisplay.Title.Text
			end)
			if ok and title then list[#list + 1] = title end
		end
		return list
	end

	task.wait(1)
	local maps = boardMaps()
	if table.find(maps, mapName) then
		-- present on a board: just vote it below
	elseif canChangeMap then
		RemoteFunction:InvokeServer("LobbyVoting", "Override", mapName)
		Log("Info", "MatchMaking: overrode map " .. mapName)
	else
		RemoteEvent:FireServer("LobbyVoting", "Veto")
		Log("Info", "MatchMaking: vetoed once")
		task.wait(3)
		maps = boardMaps()
	end

	RemoteFunction:InvokeServer("LobbyVoting", "Override", mapName)
	local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
	RemoteEvent:FireServer("LobbyVoting", "Vote", mapName, hrp and hrp.Position)
	RemoteEvent:FireServer("LobbyVoting", "Ready")
	Lib.Strat.ChosenID = self.Index
	Log("Info", "MatchMaking: voted & readied for map " .. mapName)
end

-- ───────────── Elevator join: scan & enter matching elevator ──────────────
function Strat:ElevatorJoin(mapInfo, token)
	local mapName = mapInfo.Map
	local solo    = mapInfo.Solo
	local newLobby = Workspace:FindFirstChild("NewLobby")
	local elevatorsFolder = newLobby and newLobby:FindFirstChild("Elevators")
	if not elevatorsFolder then Log("Warn", "ElevatorJoin: no elevators folder"); return end

	local netElevators = ReplicatedStorage:WaitForChild("Network"):WaitForChild("Elevators")
	local EnterRemote   = netElevators:WaitForChild("RF:Enter")
	local LeaveRemote   = netElevators:WaitForChild("RF:Leave")
	local SetSizeRemote = netElevators:WaitForChild("RF:SetSize")
	local SetReadyRemote= netElevators:WaitForChild("RF:SetReady")

	local joined = false
	while not joined do
		if aborted(token) then return end
		for _, elevator in ipairs(elevatorsFolder:GetChildren()) do
			local elevMap = elevator:GetAttribute("Map")
			local elevPlayers = elevator:GetAttribute("Players") or 0
			local elevCapacity = elevator:GetAttribute("Capacity") or 1
			if elevMap == mapName and elevPlayers < elevCapacity and not (solo and elevPlayers ~= 0) then
				Log("Info", ("ElevatorJoin: entering elevator for %s (%d/%d)"):format(mapName, elevPlayers, elevCapacity))
				EnterRemote:InvokeServer(elevator)
				task.wait(0.05)
				SetSizeRemote:InvokeServer(1)
				task.wait(0.05)
				SetReadyRemote:InvokeServer(true)
				joined = true

				-- watch the timer; bail if the map changes or someone joins a solo map
				local conn
				conn = elevator:GetAttributeChangedSignal("Timer"):Connect(function()
					local m = elevator:GetAttribute("Map")
					local p = elevator:GetAttribute("Players") or 0
					local timer = elevator:GetAttribute("Timer") or 0
					if m ~= mapName or (solo and p > 1) then
						conn:Disconnect()
						LeaveRemote:InvokeServer()
						joined = false
						Log("Info", "ElevatorJoin: left (map changed / solo invaded)")
					elseif timer == 0 then
						conn:Disconnect()
						Log("Info", "ElevatorJoin: launching to match")
					end
				end)
				break
			end
		end
		task.wait(0.3)
	end
end

-- ════════════════════════════ Run ═════════════════════════════════
function Strat:Run()
	if self._started then return end
	self._started = true
	local token = snapshotToken()
	Lib.CurrentCount = Lib.RestartCount

	for _, name in ipairs(ACTION_NAMES) do
		local cat = self[name]
		task.spawn(function()
			for _, info in ipairs(cat.Lists) do
				if aborted(token) then return end
				Actions[name](self, info, token)
			end
		end)
	end

	if not CheckPlace() then
		task.spawn(function() self:Join(token) end)
	end
	Log("Info", ("Strat running (%d towers, place=%s)"):format(#self.Place.Lists, tostring(CheckPlace())))
end

-- ═══════════ Restart-after-loss + abort on match end ══════════════
task.spawn(function()
	local r = Replicator()
	if not r then return end
	r:GetAttributeChangedSignal("GameOver"):Connect(function()
		if not r:GetAttribute("GameOver") then return end
		Lib.RestartCount += 1
		RunToken.value += 1 -- abort every in-flight action
		for k in pairs(Towers) do if k ~= "index" then Towers[k] = nil end end
		Towers.index = 0
		Log("Info", "Match ended — actions aborted, towers cleared")

		task.wait(1)
		local health = StateValue("Health")
		local cur = health and health:FindFirstChild("Current")
		local lost = cur and cur.Value == 0

		if Config.RestartMatch and lost then
			Log("Info", "Lost — restarting match shortly")
			task.wait(3)
			-- vote skip / ready until accepted, then the strat re-runs in the new round
			task.spawn(function()
				local voted
				repeat voted = RemoteFunction:InvokeServer("Voting", "Skip"); task.wait()
				until voted or IsGameOver() == false
			end)
		else
			Log("Info", "Rejoining lobby")
			pcall(function() TeleportService:Teleport(LOBBY_PLACE_ID, LocalPlayer) end)
		end
	end)
end)

getgenv().Strat = Strat
Log("Info", "StratX Engine v3 loaded. CheckPlace = " .. tostring(CheckPlace()))
-- recorded strats do `local TDS = loadstring(...)()` then `TDS:Map(...)`,
-- so return a ready INSTANCE.
return Strat.new()
