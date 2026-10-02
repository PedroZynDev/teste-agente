--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")
local plotConfigModule = configFolder:WaitForChild("PlotConfig") :: ModuleScript
local PlotConfig = require(plotConfigModule)

type PlotState = {
	ClaimPlatform: Part,
	StatusLabel: TextLabel,
	Owner: Player?,
	ClaimLocked: boolean,
}

-- Notified after a plot changed hands, so other server services can react instead of polling
-- for ownership. Server-side only: these are plain Luau callbacks and never a Remote.
type PlotClaimedListener = (plot: Model, player: Player) -> ()
type PlotReleasedListener = (plot: Model, player: Player) -> ()

local PLOTS_FOLDER_NAME = "TycoonPlots"
local PLOT_NAME_PREFIX = "Plot"

local plotStates: { [Model]: PlotState } = {}
local playerPlots: { [Player]: Model } = {}
local playerClaimLocks: { [Player]: boolean } = {}
local playersLeaving = setmetatable({}, { __mode = "k" }) :: { [Player]: boolean }
local initialized = false

local plotClaimedListeners: { PlotClaimedListener } = {}
local plotReleasedListeners: { PlotReleasedListener } = {}

local PlotService = {}

-- Notifies subscribers and isolates their errors: one broken listener must not stop the
-- others and, more importantly, must not leave a plot half claimed or half released.
local function firePlotClaimed(plot: Model, player: Player)
	for _, listener in plotClaimedListeners do
		local ok, callbackError = pcall(listener, plot, player)
		if not ok then
			warn("[PlotService] A PlotClaimed listener errored: " .. tostring(callbackError))
		end
	end
end

local function firePlotReleased(plot: Model, player: Player)
	for _, listener in plotReleasedListeners do
		local ok, callbackError = pcall(listener, plot, player)
		if not ok then
			warn("[PlotService] A PlotReleased listener errored: " .. tostring(callbackError))
		end
	end
end

local function updatePlotVisuals(state: PlotState)
	local owner = state.Owner
	if owner == nil then
		state.ClaimPlatform.Color = PlotConfig.AvailableColor
		state.StatusLabel.Text = PlotConfig.AvailableLabelText
	else
		state.ClaimPlatform.Color = PlotConfig.OccupiedColor
		state.StatusLabel.Text = PlotConfig.OccupiedLabelPrefix .. owner.Name
	end
end

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

local function releasePlayerPlot(player: Player)
	playerClaimLocks[player] = nil

	local plot = playerPlots[player]
	if plot == nil then
		return
	end

	local state = plotStates[plot]
	if state == nil or state.Owner ~= player then
		-- Do not clear a plot if an inconsistent stale mapping points at another owner.
		playerPlots[player] = nil
		return
	end

	state.Owner = nil
	playerPlots[player] = nil
	plot:SetAttribute("OwnerUserId", 0)
	updatePlotVisuals(state)

	-- The plot is fully released before listeners run, so a listener that asks
	-- PlotService.GetPlotOwner(plot) already sees the new (ownerless) state.
	firePlotReleased(plot, player)
end

local function handleClaimTouch(plot: Model, touchedPart: BasePart)
	local state = plotStates[plot]
	if state == nil then
		return
	end

	local player = getPlayerFromTouchedPart(touchedPart)
	if player == nil then
		return
	end

	-- These per-plot and per-player locks prevent duplicate Touched callbacks without
	-- blocking unrelated plots. The section through the owner/attribute update must not yield.
	if state.ClaimLocked or playerClaimLocks[player] then
		return
	end
	state.ClaimLocked = true
	playerClaimLocks[player] = true

	if playersLeaving[player]
		or player.Parent ~= Players
		or state.Owner ~= nil
		or playerPlots[player] ~= nil
	then
		state.ClaimLocked = false
		playerClaimLocks[player] = nil
		return
	end

	state.Owner = player
	playerPlots[player] = plot
	plot:SetAttribute("OwnerUserId", player.UserId)
	updatePlotVisuals(state)

	state.ClaimLocked = false
	playerClaimLocks[player] = nil

	-- Fires after the claim is fully committed and the locks above are released, so listeners
	-- observe a consistent state and can safely query this service without being rejected by a
	-- lock that is still held.
	firePlotClaimed(plot, player)
end

local function createClaimLabel(platform: Part): TextLabel
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "ClaimStatus"
	billboard.Adornee = platform
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Size = UDim2.fromOffset(PlotConfig.LabelSize.X, PlotConfig.LabelSize.Y)
	billboard.StudsOffset = PlotConfig.LabelStudsOffset
	billboard.Parent = platform

	local label = Instance.new("TextLabel")
	label.Name = "StatusLabel"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.Text = PlotConfig.AvailableLabelText
	label.TextColor3 = PlotConfig.LabelTextColor
	label.TextScaled = true
	label.TextStrokeTransparency = 0.25
	label.TextWrapped = true
	label.Parent = billboard

	return label
end

local function createPlot(
	index: number,
	plotsFolder: Folder,
	baseplate: BasePart,
	columns: number,
	gridWidth: number,
	gridDepth: number
)
	local row = math.floor((index - 1) / columns)
	local column = (index - 1) % columns
	local offsetX = -gridWidth / 2
		+ PlotConfig.PlotSize.X / 2
		+ column * (PlotConfig.PlotSize.X + PlotConfig.PlotSpacing)
	local offsetZ = -gridDepth / 2
		+ PlotConfig.PlotSize.Z / 2
		+ row * (PlotConfig.PlotSize.Z + PlotConfig.PlotSpacing)

	local plot = Instance.new("Model")
	plot.Name = PLOT_NAME_PREFIX .. tostring(index)
	plot:SetAttribute("OwnerUserId", 0)

	local ground = Instance.new("Part")
	ground.Name = "Ground"
	ground.Anchored = true
	ground.CanCollide = true
	ground.CanTouch = false
	ground.Color = PlotConfig.GroundColor
	ground.Material = PlotConfig.GroundMaterial
	ground.Size = PlotConfig.PlotSize
	ground.TopSurface = Enum.SurfaceType.Smooth
	ground.BottomSurface = Enum.SurfaceType.Smooth

	local groundCFrame = baseplate.CFrame
		* CFrame.new(
			offsetX,
			baseplate.Size.Y / 2 + PlotConfig.PlotSize.Y / 2,
			offsetZ
		)
	ground.CFrame = groundCFrame
	ground.Parent = plot
	plot.PrimaryPart = ground

	local claimPlatform = Instance.new("Part")
	claimPlatform.Name = "ClaimPlatform"
	claimPlatform.Anchored = true
	claimPlatform.CanCollide = true
	claimPlatform.CanTouch = true
	claimPlatform.Color = PlotConfig.AvailableColor
	claimPlatform.Material = Enum.Material.Neon
	claimPlatform.Size = PlotConfig.ClaimPlatformSize
	claimPlatform.TopSurface = Enum.SurfaceType.Smooth
	claimPlatform.BottomSurface = Enum.SurfaceType.Smooth
	claimPlatform.CFrame = groundCFrame
		* CFrame.new(
			PlotConfig.ClaimPlatformOffset.X,
			ground.Size.Y / 2 + PlotConfig.ClaimPlatformSize.Y / 2,
			PlotConfig.ClaimPlatformOffset.Y
		)
	claimPlatform.Parent = plot

	local statusLabel = createClaimLabel(claimPlatform)
	local state: PlotState = {
		ClaimPlatform = claimPlatform,
		StatusLabel = statusLabel,
		Owner = nil,
		ClaimLocked = false,
	}
	plotStates[plot] = state
	updatePlotVisuals(state)

	claimPlatform.Touched:Connect(function(touchedPart: BasePart)
		handleClaimTouch(plot, touchedPart)
	end)

	-- Parent only after the state and touch handler are ready, so no early touch is lost.
	plot.Parent = plotsFolder
end

local function createPlotsFolder(): Folder
	local existingFolder = Workspace:FindFirstChild(PLOTS_FOLDER_NAME)
	if existingFolder ~= nil then
		-- Rebuild the generated container so initialization always produces one clean set of plots.
		existingFolder:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = PLOTS_FOLDER_NAME
	folder.Parent = Workspace
	return folder
end

function PlotService.Initialize()
	if initialized then
		return
	end

	local baseplate = Workspace:FindFirstChild("Baseplate")
	if baseplate == nil or not baseplate:IsA("BasePart") then
		error("[PlotService] Workspace.Baseplate must be a BasePart before plots can be created")
	end

	local plotCount = PlotConfig.PlotCount
	if plotCount ~= 6 then
		error("[PlotService] PlotConfig.PlotCount must remain exactly 6")
	end

	local columns = math.min(PlotConfig.GridColumns, plotCount)
	if columns < 1 then
		error("[PlotService] PlotConfig.GridColumns must be at least 1")
	end

	local rows = math.ceil(plotCount / columns)
	local gridWidth = columns * PlotConfig.PlotSize.X
		+ (columns - 1) * PlotConfig.PlotSpacing
	local gridDepth = rows * PlotConfig.PlotSize.Z
		+ (rows - 1) * PlotConfig.PlotSpacing
	if gridWidth > baseplate.Size.X or gridDepth > baseplate.Size.Z then
		error("[PlotService] The configured plot grid does not fit on Workspace.Baseplate")
	end

	local plotsFolder = createPlotsFolder()
	for index = 1, plotCount do
		createPlot(index, plotsFolder, baseplate, columns, gridWidth, gridDepth)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		-- Mark first so a late Touched callback cannot reclaim the plot during removal.
		playersLeaving[player] = true
		releasePlayerPlot(player)
	end)

	initialized = true
end

function PlotService.GetPlotForPlayer(player: Player): Model?
	return playerPlots[player]
end

function PlotService.GetPlotOwner(plot: Model): Player?
	local state = plotStates[plot]
	if state == nil then
		return nil
	end

	return state.Owner
end

function PlotService.IsPlotAvailable(plot: Model): boolean
	local state = plotStates[plot]
	return state ~= nil and state.Owner == nil and not state.ClaimLocked
end

-- Subscribes to claim notifications and returns the unsubscribe function.
--
-- Notifications are delivered synchronously, in subscription order, on the thread that
-- changed the plot, and listeners must not yield: a claim/release is applied atomically and
-- a yielding listener would let other Touched callbacks interleave with it. Building a
-- structure out of Instances (what MiningService does here) never yields, so this is fine.
--
-- Subscribing or unsubscribing from inside a listener is not supported: the listener list is
-- being iterated at that moment.
function PlotService.OnPlotClaimed(listener: PlotClaimedListener): () -> ()
	table.insert(plotClaimedListeners, listener)

	local subscribed = true
	return function()
		if not subscribed then
			return
		end
		subscribed = false

		local index = table.find(plotClaimedListeners, listener)
		if index ~= nil then
			table.remove(plotClaimedListeners, index)
		end
	end
end

-- Same contract as OnPlotClaimed, for the moment a plot stops belonging to a player
-- (including when that player leaves the game).
function PlotService.OnPlotReleased(listener: PlotReleasedListener): () -> ()
	table.insert(plotReleasedListeners, listener)

	local subscribed = true
	return function()
		if not subscribed then
			return
		end
		subscribed = false

		local index = table.find(plotReleasedListeners, listener)
		if index ~= nil then
			table.remove(plotReleasedListeners, index)
		end
	end
end

return PlotService
