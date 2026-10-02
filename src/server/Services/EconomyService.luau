--!strict

-- EconomyService is the single authority for a player's Cash.
--
-- * Cash lives only in the server-side table below. Nothing else (including the leaderstats
--   IntValue) is ever read back as a balance, with one narrow exception: SnapshotCash
--   (used only by DataService on exit) may read the display mirror AFTER the authoritative
--   state is already gone, because the mirror is only ever written by this module.
-- * Cash is always a whole number in the range [0, EconomyConfig.MaxCash].
-- * Persistence is not this module's job: balances still start at StartingCash and are
--   discarded when the player leaves. DataService (basic persistence) layers save/load on
--   top through the two functions at the bottom of this module (RestoreCash,
--   SnapshotCash); it never reads or mutates anything else here.
-- * This module creates no Remotes. Cash can only change through the functions below, called
--   by other server code.
--
-- Functions use dot syntax (like PlotService): EconomyService.AddCash(player, amount).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")
local economyConfigModule = configFolder:WaitForChild("EconomyConfig") :: ModuleScript
local EconomyConfig = require(economyConfigModule)

type EconomyState = {
	Cash: number,
	CashValue: IntValue?,
	CashValueChangedConnection: RBXScriptConnection?,
}

local LEADERSTATS_NAME = "leaderstats"
local CASH_VALUE_NAME = "Dinheiro"
-- Largest integer a double (and therefore a Luau number / DataStore number) represents exactly.
local MAX_EXACT_INTEGER = 2 ^ 53 - 1

local economyStates: { [Player]: EconomyState } = {}
local initialized = false
local warnedNotInitialized = false

local EconomyService = {}

-- True only for real, finite whole numbers. Rejects strings (no implicit coercion), NaN,
-- +/-math.huge and fractions. The explicit infinity check must stay before `% 1`.
local function isWholeNumber(value: any): boolean
	return type(value) == "number"
		and value == value -- false only for NaN
		and value ~= math.huge
		and value ~= -math.huge
		and value % 1 == 0
end

-- Amounts that change a balance must be whole numbers strictly greater than zero.
local function isValidAmount(value: any): boolean
	return isWholeNumber(value) and value > 0
end

-- Prices may be zero ("free"), but never negative.
local function isValidPrice(value: any): boolean
	return isWholeNumber(value) and value >= 0
end

-- Looks up a player's authoritative state. Every public function goes through here so that
-- calling this module copy before Initialize() is reported instead of failing silently.
-- Each copy of the module (e.g. one required separately by the Studio Command Bar) has its own
-- private state, so a copy that never ran Initialize() can only ever see "no state".
local function getState(player: Player, caller: string): EconomyState?
	if not initialized then
		if not warnedNotInitialized then
			warnedNotInitialized = true
			warn(
				"[EconomyService] "
					.. caller
					.. " was called on a module copy where Initialize() never ran; it has no player "
					.. "state. Use the instance initialized by Main.server.luau (e.g. call it from a "
					.. "Script running under ServerScriptService, not the Command Bar)."
			)
		end
		return nil
	end

	return economyStates[player]
end

local function findOrCreateLeaderstats(player: Player): Folder
	local existing = player:FindFirstChild(LEADERSTATS_NAME)
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end
	if existing ~= nil then
		-- Something else squats on the reserved name; Roblox only shows a Folder.
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = LEADERSTATS_NAME
	folder.Parent = player
	return folder
end

local function findOrCreateCashValue(leaderstats: Folder, cash: number): IntValue
	local existing = leaderstats:FindFirstChild(CASH_VALUE_NAME)
	if existing ~= nil and existing:IsA("IntValue") then
		return existing
	end
	if existing ~= nil then
		existing:Destroy()
	end

	local value = Instance.new("IntValue")
	value.Name = CASH_VALUE_NAME
	value.Value = cash
	value.Parent = leaderstats
	return value
end

-- Makes sure state.CashValue points at a live IntValue under player.leaderstats.
-- The IntValue is display only: whenever it is touched from outside, it is overwritten with the
-- authoritative balance instead of being trusted.
local function bindCashValue(player: Player, state: EconomyState): IntValue
	local previousConnection = state.CashValueChangedConnection
	if previousConnection ~= nil then
		previousConnection:Disconnect()
		state.CashValueChangedConnection = nil
	end

	local leaderstats = findOrCreateLeaderstats(player)
	local cashValue = findOrCreateCashValue(leaderstats, state.Cash)

	state.CashValue = cashValue
	state.CashValueChangedConnection = cashValue:GetPropertyChangedSignal("Value"):Connect(function()
		if economyStates[player] == state and cashValue.Value ~= state.Cash then
			cashValue.Value = state.Cash
		end
	end)

	return cashValue
end

-- One-way sync: authoritative balance -> leaderstats. Never reads the IntValue back.
local function syncLeaderstats(player: Player, state: EconomyState)
	local cashValue = state.CashValue
	if cashValue == nil or cashValue.Parent == nil or cashValue.Parent.Parent ~= player then
		-- Missing or detached (e.g. destroyed by another script): rebuild it.
		cashValue = bindCashValue(player, state)
	end

	if cashValue.Value ~= state.Cash then
		cashValue.Value = state.Cash
	end
end

local function setCash(player: Player, state: EconomyState, newCash: number)
	-- The authoritative state is updated first; the sync only mirrors it.
	state.Cash = newCash
	syncLeaderstats(player, state)
end

local function initializePlayer(player: Player)
	-- Idempotent: never reset an existing balance (PlayerAdded and the startup loop may overlap).
	if economyStates[player] ~= nil or player.Parent ~= Players then
		return
	end

	local state: EconomyState = {
		Cash = EconomyConfig.StartingCash,
		CashValue = nil,
		CashValueChangedConnection = nil,
	}
	economyStates[player] = state
	syncLeaderstats(player, state)
end

local function cleanupPlayer(player: Player)
	local state = economyStates[player]
	if state == nil then
		return
	end

	local connection = state.CashValueChangedConnection
	if connection ~= nil then
		connection:Disconnect()
	end
	-- Nothing is saved on purpose: persistence is a separate, future system.
	economyStates[player] = nil
end

local function validateConfig()
	local maxCash = EconomyConfig.MaxCash
	local startingCash = EconomyConfig.StartingCash

	if not isWholeNumber(maxCash) or maxCash < 1 or maxCash > MAX_EXACT_INTEGER then
		error("[EconomyService] EconomyConfig.MaxCash must be a whole number between 1 and 2^53 - 1")
	end
	if not isWholeNumber(startingCash) or startingCash < 0 or startingCash > maxCash then
		error("[EconomyService] EconomyConfig.StartingCash must be a whole number between 0 and MaxCash")
	end
end

function EconomyService.Initialize()
	if initialized then
		return
	end

	validateConfig()

	-- Connect first, then handle players that already exist, so nobody is missed.
	Players.PlayerAdded:Connect(initializePlayer)
	Players.PlayerRemoving:Connect(cleanupPlayer)
	for _, player in Players:GetPlayers() do
		initializePlayer(player)
	end

	initialized = true
end

-- Returns the player's Cash. Players without economy state (not initialized yet, already
-- removed, or not a Player at all) read as 0; mutating functions return false for them, so
-- callers can never create Cash by accident.
function EconomyService.GetCash(player: Player): number
	local state = getState(player, "GetCash")
	if state == nil then
		return 0
	end

	return state.Cash
end

-- Adds Cash. Returns true if the request was valid and the player has economy state.
-- amount must be a whole number > 0 (no strings, NaN, infinities, zero, negatives, fractions).
-- Saturation: if the result would exceed EconomyConfig.MaxCash, the balance is clamped to
-- MaxCash and the call still returns true (also when the balance was already at MaxCash).
-- The excess is discarded. On false, the balance is untouched.
function EconomyService.AddCash(player: Player, amount: number): boolean
	if not isValidAmount(amount) then
		return false
	end

	local state = getState(player, "AddCash")
	if state == nil then
		return false
	end

	local maxCash = EconomyConfig.MaxCash
	local headroom = maxCash - state.Cash
	-- Compared against the headroom (not balance + amount) so a huge amount cannot lose
	-- precision or overflow before the clamp.
	local newCash = if amount >= headroom then maxCash else state.Cash + amount
	setCash(player, state, newCash)

	return true
end

-- Read-only check. price must be a whole number >= 0, so a price of 0 IS allowed here ("free"
-- is always affordable for a player with economy state). SpendCash rejects 0, so callers that
-- sell free items must skip SpendCash instead of calling it with 0.
-- Returns false for invalid prices and for players without economy state.
function EconomyService.CanAfford(player: Player, price: number): boolean
	if not isValidPrice(price) then
		return false
	end

	local state = getState(player, "CanAfford")
	if state == nil then
		return false
	end

	return state.Cash >= price
end

-- Spends Cash. Returns true only if the money was actually deducted.
-- amount must be a whole number > 0. The balance is checked again here, with no yield between
-- the check and the deduction, so this call is the atomic purchase step: never rely on a
-- previous CanAfford call. The balance can never become negative.
-- On false (invalid amount, no state, insufficient funds) the balance is untouched.
function EconomyService.SpendCash(player: Player, amount: number): boolean
	if not isValidAmount(amount) then
		return false
	end

	local state = getState(player, "SpendCash")
	if state == nil then
		return false
	end

	if state.Cash < amount then
		return false
	end

	setCash(player, state, state.Cash - amount)
	return true
end

-- === Extensions added for DataService (basic persistence) ===

-- Applies a balance loaded from the DataStore on top of the current balance. This is
-- deliberately ADDITIVE (delegates to AddCash): a player can earn legitimately before
-- the async load resolves, and restoring must neither overwrite that income nor double
-- anything (StartingCash is 0, so saved + earned is the correct total). Returns false
-- (nothing changed) when the amount is invalid or the player has no economy state; in
-- the "no state" case (player already left), DataService keeps the value pending and
-- adds it to the exit-save snapshot instead.
function EconomyService.RestoreCash(player: Player, amount: number): boolean
	if not isValidAmount(amount) then
		return false
	end

	return EconomyService.AddCash(player, amount)
end

-- Read-only balance snapshot that survives the exit race: DataService saves during
-- PlayerRemoving, but EconomyService's own PlayerRemoving handler (connected first) may
-- already have dropped the state. The leaderstats IntValue is a one-way mirror that
-- syncLeaderstats keeps equal to the authoritative value on every change, and nothing
-- reads back from it, so the mirror's last synced value is exactly the last balance.
-- Prefers the live state when present; falls back to the mirror; returns 0 when neither
-- can be found. This function never mutates anything and stays bounded by [0, MaxCash].
function EconomyService.SnapshotCash(player: Player): number
	local state = economyStates[player]
	if state ~= nil then
		return state.Cash
	end

	if not initialized then
		return 0
	end

	local leaderstats = player:FindFirstChild(LEADERSTATS_NAME)
	if leaderstats ~= nil and leaderstats:IsA("Folder") then
		local cashValue = leaderstats:FindFirstChild(CASH_VALUE_NAME)
		if cashValue ~= nil and cashValue:IsA("IntValue") and isWholeNumber(cashValue.Value) then
			-- The mirror is display state, but it is only ever written by this module
			-- (or reset back to state.Cash when touched from outside), so reading it as a
			-- fallback AFTER the authoritative state is gone is safe. Clamp defensively:
			-- a rogue value must never enter persisted data.
			local value = cashValue.Value
			local maxCash = EconomyConfig.MaxCash
			if value < 0 then
				return 0
			elseif value > maxCash then
				return maxCash
			end
			return value
		end
	end

	return 0
end

return EconomyService
