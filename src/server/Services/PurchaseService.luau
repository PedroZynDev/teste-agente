--!strict

-- PurchaseService: the first purchase flow ("primeira compra" in GAME_DESIGN.md).
--
-- One touch pad per item per occupied plot, in the classic Roblox tycoon style — the
-- same mechanism PlotService uses for claiming. No RemoteEvents/RemoteFunctions: the
-- only client influence is "a character touched a part", which the server validates.
--
-- Rules enforced here (all server-side):
-- * Pads exist only while a plot is occupied; they are created on PlotClaimed and
--   destroyed on PlotReleased. Only the plot's CURRENT owner (per PlotService) can buy.
-- * One purchase per plot occupancy per item (no persistence exists yet; a re-claimed
--   plot starts unpurchased on purpose, mirroring the auto-granted setup).
-- * Price comes from PurchaseConfig ONLY. EconomyService.SpendCash re-checks the
--   balance atomically and is the single deduct step; a failed purchase never charges.
-- * Money is spent first; if granting the item afterwards fails (e.g. the mining asset
--   broke mid-session), the price is refunded with AddCash so cash is only ever spent
--   for an item that was actually granted.
--
-- This phase sells exactly one thing (the extra dropper line). Grant logic is intentionally
-- a single call into MiningService.AddExtraDropperLine; richer catalogs belong to the
-- later "progressão" phase, not to this one.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")
local purchaseConfigModule = configFolder:WaitForChild("PurchaseConfig") :: ModuleScript
local PurchaseConfig = require(purchaseConfigModule)

local servicesFolder = script.Parent
local plotServiceModule = servicesFolder:WaitForChild("PlotService") :: ModuleScript
local PlotService = require(plotServiceModule)
local economyServiceModule = servicesFolder:WaitForChild("EconomyService") :: ModuleScript
local EconomyService = require(economyServiceModule)
local miningServiceModule = servicesFolder:WaitForChild("MiningService") :: ModuleScript
local MiningService = require(miningServiceModule)

local GROUND_PART_NAME = "Ground"
local PAD_NAME_PREFIX = "PurchasePad_"

type PurchaseItem = {
	Id: string,
	DisplayName: string,
	Price: number,
	PadOffset: Vector3,
	PadSize: Vector3,
	PadAvailableColor: Color3,
	PadSoldColor: Color3,
	LabelAvailableFormat: string,
	LabelSoldText: string,
	LabelTextColor: Color3,
	LabelSize: Vector2,
}

type PadEntry = {
	Pad: BasePart,
	Label: TextLabel,
	Sold: boolean,
	Connection: RBXScriptConnection?,
}

-- itemId -> validated item (validated at Initialize, so pad handlers can trust it).
local itemsById: { [string]: PurchaseItem } = {}
-- Per-plot pad bookkeeping; released plots lose their pads AND their "sold" marks.
local padsByPlot: { [Model]: { [string]: PadEntry } } = {}
local initialized = false

local PurchaseService = {}

local function isFiniteNumber(value: any): boolean
	return type(value) == "number"
		and value == value -- false only for NaN
		and value ~= math.huge
		and value ~= -math.huge
end

-- Same pattern PlotService uses to resolve a Player from a Touched part. Deliberately
-- duplicated (10 lines) instead of widening PlotService's public surface for a helper.
local function getPlayerFromTouchedPart(touchedPart: BasePart): Player?
	local ancestor: Instance? = touchedPart
	while ancestor ~= nil do
		if ancestor:IsA("Model") then
			local player = Players:GetPlayerFromCharacter(ancestor)
			if player ~= nil then
				return player
			end
		end
		ancestor = ancestor.Parent
	end

	return nil
end

local function createPad(item: PurchaseItem, plot: Model): PadEntry
	local ground = plot:FindFirstChild(GROUND_PART_NAME)
	local padCFrame
	if ground ~= nil and ground:IsA("BasePart") then
		-- Rest on the ground's top surface, like the claim platform does.
		padCFrame = ground.CFrame * CFrame.new(
			item.PadOffset.X,
			ground.Size.Y / 2 + item.PadSize.Y / 2,
			item.PadOffset.Z
		)
	else
		padCFrame = plot:GetPivot() * CFrame.new(item.PadOffset)
	end

	local pad = Instance.new("Part")
	pad.Name = PAD_NAME_PREFIX .. item.Id
	pad.Anchored = true
	pad.CanCollide = true
	pad.CanTouch = true
	pad.Color = item.PadAvailableColor
	pad.Material = Enum.Material.Neon
	pad.Size = item.PadSize
	pad.TopSurface = Enum.SurfaceType.Smooth
	pad.BottomSurface = Enum.SurfaceType.Smooth
	pad.CFrame = padCFrame
	pad.Parent = plot

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "PurchaseStatus"
	billboard.Adornee = pad
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Size = UDim2.fromOffset(item.LabelSize.X, item.LabelSize.Y)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.Parent = pad

	local label = Instance.new("TextLabel")
	label.Name = "StatusLabel"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.Text = (item.LabelAvailableFormat):format(item.DisplayName, item.Price)
	label.TextColor3 = item.LabelTextColor
	label.TextScaled = true
	label.TextStrokeTransparency = 0.25
	label.TextWrapped = true
	label.Parent = billboard

	return { Pad = pad, Label = label, Sold = false, Connection = nil }
end

-- Runs synchronously inside the pad's Touched handler; everything through the Sold mark
-- must not yield, which makes "check -> charge -> grant -> mark" atomic per plot pad.
-- Repeated Touched callbacks (common with characters standing on pads) are filtered by
-- the Sold mark and by SpendCash's balance check, so nothing can double-buy or double-pay.
local function handlePadTouched(plot: Model, item: PurchaseItem, entry: PadEntry, touchedPart: BasePart)
	if entry.Sold then
		return
	end

	local player = getPlayerFromTouchedPart(touchedPart)
	if player == nil or player.Parent ~= Players then
		return
	end

	-- Only the plot's current owner may buy this plot's upgrade (server-authoritative).
	if PlotService.GetPlotOwner(plot) ~= player then
		return
	end

	-- SpendCash re-checks the balance atomically; false means "not charged", and the pad
	-- simply stays available for a later attempt. No cooldown spam risk: a successful
	-- buy flips Sold and every further touch becomes a no-op.
	if not EconomyService.SpendCash(player, item.Price) then
		return
	end

	if not MiningService.AddExtraDropperLine(player, plot) then
		-- Item could not be granted (mining disabled, plot state lost, cap reached,
		-- broken asset...). Hand the money straight back; never keep an unpaid-for fee.
		local refunded = EconomyService.AddCash(player, item.Price)
		warn(("[PurchaseService] '%s' could not be granted on plot %s to %s; refund %s.")
			:format(item.Id, plot.Name, player.Name, if refunded then "succeeded" else "FAILED"))
		return
	end

	entry.Sold = true
	entry.Pad.Color = item.PadSoldColor
	entry.Label.Text = item.LabelSoldText
end

local function onPlotClaimed(_player: Player, plot: Model)
	if padsByPlot[plot] ~= nil then
		return
	end
	if MiningService.GetPurchasableLineCount() < 1 then
		-- Mining unavailable or no extra lines configured: nothing to sell.
		return
	end

	local pads: { [string]: PadEntry } = {}
	padsByPlot[plot] = pads

	for itemId, item in itemsById do
		local entry = createPad(item, plot)
		pads[itemId] = entry
		entry.Connection = entry.Pad.Touched:Connect(function(touchedPart: BasePart)
			-- Ignore any event aimed at a torn-down pad/plot (safety net; connections are
			-- also explicitly disconnected on release).
			local currentPads = padsByPlot[plot]
			if currentPads ~= pads or touchedPart.Parent == nil then
				return
			end
			handlePadTouched(plot, item, entry, touchedPart)
		end)
	end
end

local function onPlotReleased(_player: Player, plot: Model)
	local pads = padsByPlot[plot]
	if pads == nil then
		return
	end
	padsByPlot[plot] = nil

	for _, entry in pads do
		local connection = entry.Connection
		if connection ~= nil then
			connection:Disconnect()
			entry.Connection = nil
		end
		-- Destroying the pad takes the billboard and label with it.
		entry.Pad:Destroy()
	end
end

function PurchaseService.Initialize()
	if initialized then
		return
	end
	initialized = true

	local problems: { string } = {}
	for key, item in PurchaseConfig do
		if typeof(item) ~= "table" then
			table.insert(problems, ("PurchaseConfig.%s must be a table"):format(tostring(key)))
		elseif item.Id ~= key then
			table.insert(problems, ("PurchaseConfig entry %q must have Id equal to its key"):format(tostring(key)))
		else
			if not isFiniteNumber(item.Price) or item.Price % 1 ~= 0 or item.Price < 1 then
				table.insert(problems, ("PurchaseConfig.%s.Price must be a whole number >= 1 (Cash)")
					:format(tostring(item.Id)))
			end
			if typeof(item.DisplayName) ~= "string" or #item.DisplayName == 0 then
				table.insert(problems, ("PurchaseConfig.%s.DisplayName must be a non-empty string")
					:format(tostring(item.Id)))
			end
			if typeof(item.PadOffset) ~= "Vector3" then
				table.insert(problems, ("PurchaseConfig.%s.PadOffset must be a Vector3")
					:format(tostring(item.Id)))
			end
			if typeof(item.PadSize) ~= "Vector3"
				or not isFiniteNumber(item.PadSize.X) or item.PadSize.X <= 0
				or not isFiniteNumber(item.PadSize.Y) or item.PadSize.Y <= 0
				or not isFiniteNumber(item.PadSize.Z) or item.PadSize.Z <= 0
			then
				table.insert(problems, ("PurchaseConfig.%s.PadSize must be a Vector3 with all components > 0")
					:format(tostring(item.Id)))
			end
			-- The pad label is built with (format):format(DisplayName, Price), so both
			-- placeholders must be present or the label would show raw format specifiers.
			if type(item.LabelAvailableFormat) ~= "string"
				or string.find(item.LabelAvailableFormat, "%s", 1, true) == nil
				or string.find(item.LabelAvailableFormat, "%d", 1, true) == nil
			then
				table.insert(problems, ("PurchaseConfig.%s.LabelAvailableFormat must be a string containing %%s and %%d")
					:format(tostring(item.Id)))
			end
			if itemsById[item.Id] ~= nil then
				table.insert(problems, ("PurchaseConfig defines duplicate item id %q"):format(tostring(item.Id)))
			end
			itemsById[item.Id] = item
		end
	end

	if #problems > 0 then
		-- Same policy as MiningService: loud startup failure, plots/economy/mining keep
		-- working, no pads and no purchases exist.
		error(("[PurchaseService] Purchases are disabled because validation failed:\n - %s")
			:format(table.concat(problems, "\n - ")), 2)
	end

	-- Pads only for plots claimed after this point; Main initializes everything in one
	-- synchronous pass before players can touch any platform, so there is nothing to
	-- backfill (see the identical note in MiningService.Initialize).
	PlotService.OnPlotClaimed(onPlotClaimed)
	PlotService.OnPlotReleased(onPlotReleased)
end

return PurchaseService
