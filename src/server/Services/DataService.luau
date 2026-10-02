--!strict

-- DataService: basic persistence for Cash (GAME_DESIGN priority 6, "persistência básica").
--
-- This is the ONLY module in the project that touches DataStoreService. Everything else
-- (plot state, purchases, ore registry) intentionally stays session-scoped, exactly as
-- scoped: Rubis/rebirth/persistent upgrades belong to later priorities and must extend
-- the record schema via DataVersion, not scatter new store callers.
--
-- Lifecycle:
-- * Load: on PlayerAdded a single bounded-retry GetAsync runs on its own thread. On
--   success the saved balance is restored ADDITIVELY through
--   EconomyService.RestoreCash (the balance starts at StartingCash = 0, so earnings
--   that arrive before the load resolves are neither doubled nor overwritten). On total
--   failure the session fail-opens at 0 with a warning; saves stay enabled so a store
--   outage never punishes the player.
-- * Save: three moments only (never "every small change"):
--     - PlayerRemoving (waits briefly for an in-flight load so leaving within the first
--       seconds cannot drop the just-loaded balance; a snapshot through
--       EconomyService.SnapshotCash survives that event's handler ordering),
--     - periodic autosave every DataConfig.SaveIntervalSeconds, only for players whose
--       Cash changed since their last save,
--     - one final pass inside game:BindToClose.
-- * Conflicts: saves go through UpdateAsync with a transform that refuses to lower the
--   stored value, so a server that skipped/failed its exit save can never have stale
--   data clobber a newer record ("last-writer" here means "last-writer WITH FULL DATA").
-- * Roblox throttles DataStore traffic (bandwidth/request budget); the high autosave
--   period and the changed-only check exist for that reason. A crash between autosaves
--   can lose at most SaveIntervalSeconds of income: accepted for the basic phase.
--
-- Security: keys derive from Player.UserId on the server; saved values are fully
-- re-validated before use; no client can read or write through this service, and it
-- creates no remotes.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")
local dataConfigModule = configFolder:WaitForChild("DataConfig") :: ModuleScript
local DataConfig = require(dataConfigModule)

local servicesFolder = script.Parent
local economyServiceModule = servicesFolder:WaitForChild("EconomyService") :: ModuleScript
local EconomyService = require(economyServiceModule)

-- Largest integer a double (and therefore a saved value) represents exactly.
local MAX_EXACT_INTEGER = 2 ^ 53 - 1
-- Poll interval for the short waits in save paths (0.2s keeps DataStore bursts cheap).
local POLL_INTERVAL = 0.2
-- Wall budget spent inside BindToClose waiting for final saves (Roblox reserves
-- ~30 seconds on shutdown).
local CLOSE_SAVE_BUDGET_SECONDS = 25

type PlayerSession = {
	-- Load resolved (success, empty account, or fail-open after exhausted retries).
	Loaded: boolean,
	-- Validated saved balance awaiting application; zeroed once applied.
	LoadCash: number,
	-- Whether LoadCash was already added to this session's balance.
	Restored: boolean,
	-- Balance of the most recent successful save (drives the changed-only check).
	LastSavedCash: number?,
	-- One save in flight at a time per player.
	Saving: boolean,
	-- Player is leaving / server closing: autosave hands the player to the exit save.
	Closing: boolean,
}

local sessions: { [Player]: PlayerSession } = {}
local store: DataStore? = nil
local initialized = false

local DataService = {}

local function isFiniteNumber(value: any): boolean
	return type(value) == "number"
		and value == value -- false only for NaN
		and value ~= math.huge
		and value ~= -math.huge
end

local function isWholeNumber(value: any): boolean
	return isFiniteNumber(value) and value % 1 == 0
end

local function dataKeyFor(player: Player): string
	return DataConfig.KeyPrefix .. tostring(player.UserId)
end

-- Validates a raw stored record. Returns (accepted, cashToRestore). A missing record is
-- a fresh account (0); anything malformed/foreign-versioned is rejected so it can never
-- inject an unexpected balance.
local function validateLoadedRecord(value: any): (boolean, number)
	if value == nil then
		return true, 0
	end
	if typeof(value) ~= "table" then
		return false, 0
	end
	if value.Version ~= DataConfig.DataVersion then
		return false, 0
	end
	local cash = value.Cash
	if not isWholeNumber(cash) or cash < 0 or cash > MAX_EXACT_INTEGER then
		return false, 0
	end
	return true, cash :: number
end

-- Completes the load: publishes the balance to the session first (so exit saves can add
-- it back if EconomyService state is already gone), then applies it, and only then flips
-- Loaded — any thread woken by Loaded sees a fully consistent session.
local function finishLoad(player: Player, session: PlayerSession, cash: number)
	session.LoadCash = cash
	if cash > 0 then
		if EconomyService.RestoreCash(player, cash) then
			session.LoadCash = 0
			session.Restored = true
		end
		-- RestoreCash fails only when the player's economy state is already gone
		-- (left during loading); the exit save then adds LoadCash back to its snapshot.
	else
		session.Restored = true
	end
	session.Loaded = true
end

local function loadPlayerData(player: Player)
	local session = sessions[player]
	local storeRef = store
	if session == nil or storeRef == nil then
		return
	end

	local key = dataKeyFor(player)
	local lastError: any = nil
	for attempt = 1, DataConfig.MaxRetries do
		if sessions[player] ~= session then
			-- Session replaced/cleared while we were back off; stop quietly.
			return
		end
		local ok, result = pcall(function()
			return storeRef:GetAsync(key)
		end)
		if ok then
			local accepted, cash = validateLoadedRecord(result)
			if not accepted then
				warn(("[DataService] Ignoring malformed or foreign-versioned data for %s (expected a v%d record); starting the session empty.")
					:format(player.Name, DataConfig.DataVersion))
				cash = 0
			end
			finishLoad(player, session, cash)
			return
		end
		lastError = result
		if attempt < DataConfig.MaxRetries then
			task.wait(DataConfig.RetryBackoffSeconds * attempt)
		end
	end

	-- Fail-open: play this session from zero, keep saving (so the outage cannot turn a
	-- read failure into a write-wipes-account failure; UpdateAsync still refuses to
	-- lower a higher stored value).
	warn(("[DataService] Load failed for %s after %d attempts (%s); the session starts at 0 Cash and saves remain enabled.")
		:format(player.Name, DataConfig.MaxRetries, tostring(lastError)))
	finishLoad(player, session, 0)
end

-- Core save: computes the final balance, skips no-op writes, and pushes one record with
-- retry. NEVER raises; failures are logged and retried at the next opportunity.
local function performSave(player: Player, session: PlayerSession)
	local storeRef = store
	if storeRef == nil or session.Saving then
		return
	end
	session.Saving = true

	-- Never overwrite the store with a half-loaded view: wait for the load to resolve
	-- (bounded), then give up this write if it is still stuck.
	local loadDeadline = os.clock() + DataConfig.SaveWaitForLoadSeconds
	while not session.Loaded and os.clock() < loadDeadline do
		task.wait(POLL_INTERVAL)
	end
	if not session.Loaded then
		warn(("[DataService] Skipping a save for %s while its load is unresolved; the previous record stays intact.")
			:format(player.Name))
		session.Saving = false
		return
	end

	-- SnapshotCash survives EconomyService's own PlayerRemoving cleanup (the display
	-- mirror keeps the last synced value); unapplied load cash is added back so money
	-- loaded during the exit flow is never lost.
	local cash = EconomyService.SnapshotCash(player)
	if not session.Restored then
		cash += session.LoadCash
	end

	if session.LastSavedCash == cash then
		-- Nothing changed since the last save: skip (DataStore bandwidth is a budget).
		session.Saving = false
		return
	end

	local key = dataKeyFor(player)
	local lastError: any = nil
	local ok = false
	for attempt = 1, DataConfig.MaxRetries do
		ok, lastError = pcall(function()
			storeRef:UpdateAsync(key, function(oldValue: any): any
				-- Last-writer-with-full-data guard: an old/broken session may never
				-- lower what is already stored. Returning nil leaves the record as is.
				local incomingCash =
					if typeof(oldValue) == "table" and oldValue.Version == DataConfig.DataVersion
						then tonumber(oldValue.Cash)
						else nil
				if typeof(incomingCash) == "number" and incomingCash > cash then
					return nil
				end
				return { Version = DataConfig.DataVersion, Cash = cash }
			end)
		end)
		if ok then
			break
		end
		if attempt < DataConfig.MaxRetries then
			task.wait(DataConfig.RetryBackoffSeconds * attempt)
		end
	end

	if ok then
		session.LastSavedCash = cash
	else
		warn(("[DataService] Save failed for %s after %d attempts (%s); the value will be retried at the next autosave/exit save.")
			:format(player.Name, DataConfig.MaxRetries, tostring(lastError)))
	end
	session.Saving = false
end

local function onPlayerAdded(player: Player)
	if store == nil then
		return
	end
	if sessions[player] ~= nil then
		-- A prior session for this exact Player instance is still finishing its exit
		-- save; skip persistence for this one rather than race it (extreme edge in a
		-- live server; basic phase accepts a no-persistence fallback over a corrupt one).
		return
	end
	sessions[player] = {
		Loaded = false,
		LoadCash = 0,
		Restored = false,
		LastSavedCash = nil,
		Saving = false,
		Closing = false,
	}
	task.spawn(loadPlayerData, player)
end

local function onPlayerRemoving(player: Player)
	local session = sessions[player]
	if session == nil or session.Closing then
		return
	end
	session.Closing = true

	task.spawn(function()
		-- Let an in-flight autosave finish first (bounded by the same safety cap).
		local settleDeadline = os.clock() + DataConfig.SaveWaitForLoadSeconds
		while session.Saving and os.clock() < settleDeadline do
			task.wait(POLL_INTERVAL)
		end
		performSave(player, session)
		if sessions[player] == session then
			sessions[player] = nil
		end
	end)
end

local function startAutosaveLoop()
	task.spawn(function()
		while store ~= nil do
			task.wait(DataConfig.SaveIntervalSeconds)
			for player, session in sessions do
				if not session.Closing and not session.Saving and session.Loaded then
					-- Changed-only autosave; GetCash is authoritative for present players.
					if EconomyService.GetCash(player) ~= session.LastSavedCash then
						task.spawn(performSave, player, session)
					end
				end
			end
		end
	end)
end

function DataService.Initialize()
	if initialized then
		return
	end
	initialized = true

	local problems: { string } = {}
	if typeof(DataConfig.StoreName) ~= "string" or #DataConfig.StoreName == 0 then
		table.insert(problems, "DataConfig.StoreName must be a non-empty string")
	end
	if typeof(DataConfig.KeyPrefix) ~= "string" or #DataConfig.KeyPrefix == 0 then
		table.insert(problems, "DataConfig.KeyPrefix must be a non-empty string")
	end
	if not isWholeNumber(DataConfig.DataVersion) or DataConfig.DataVersion < 1 then
		table.insert(problems, "DataConfig.DataVersion must be a whole number >= 1")
	end
	if not isWholeNumber(DataConfig.MaxRetries) or DataConfig.MaxRetries < 1 then
		table.insert(problems, "DataConfig.MaxRetries must be a whole number >= 1")
	end
	if not isFiniteNumber(DataConfig.RetryBackoffSeconds) or DataConfig.RetryBackoffSeconds < 0 then
		table.insert(problems, "DataConfig.RetryBackoffSeconds must be a finite number >= 0")
	end
	if not isFiniteNumber(DataConfig.SaveIntervalSeconds) or DataConfig.SaveIntervalSeconds < 5 then
		table.insert(problems, "DataConfig.SaveIntervalSeconds must be a finite number >= 5")
	end
	if not isFiniteNumber(DataConfig.SaveWaitForLoadSeconds) or DataConfig.SaveWaitForLoadSeconds < 1 then
		table.insert(problems, "DataConfig.SaveWaitForLoadSeconds must be a finite number >= 1")
	end

	if #problems > 0 then
		-- Unlike MiningService (whose product feature cannot exist without its asset),
		-- persistence failure is a SOFT degradation: a config mistake must not take the
		-- game down. Warn loudly for every problem and disable persistence entirely;
		-- players still play, they simply do not save or load this session.
		warn(("[DataService] Persistence is DISABLED because validation failed (%d problem(s)); the game will run without saving or loading:")
			:format(#problems))
		for _, problem in problems do
			warn("[DataService]  - " .. problem)
		end
		return
	end

	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(DataConfig.StoreName)
	end)
	if not ok then
		-- Same soft policy: no store access -> play without persistence, loudly.
		warn(("[DataService] GetDataStore(%q) failed (%s); running WITHOUT persistence this session.")
			:format(DataConfig.StoreName, tostring(result)))
	else
		store = result :: DataStore
	end

	-- Connect first, then handle players that already exist (same pattern as
	-- EconomyService). Restore on load requires EconomyService state, which Main
	-- initializes before this call.
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	if store ~= nil then
		startAutosaveLoop()

		game:BindToClose(function()
			-- Roblox keeps the DataModel alive for ~30s inside BindToClose; run one final
			-- save for every still-present player and wait for them to settle.
			local remaining = 0
			for player, session in sessions do
				if not session.Closing then
					session.Closing = true
					remaining += 1
					task.spawn(function()
						local settleDeadline = os.clock() + DataConfig.SaveWaitForLoadSeconds
						while session.Saving and os.clock() < settleDeadline do
							task.wait(POLL_INTERVAL)
						end
						performSave(player, session)
						remaining -= 1
					end)
				end
			end
			local deadline = os.clock() + CLOSE_SAVE_BUDGET_SECONDS
			while remaining > 0 and os.clock() < deadline do
				task.wait(POLL_INTERVAL)
			end
			if remaining > 0 then
				warn(("[DataService] Shutdown save budget exceeded; %d player save(s) may not have persisted.")
					:format(remaining))
			end
		end)
	end
end

return DataService
