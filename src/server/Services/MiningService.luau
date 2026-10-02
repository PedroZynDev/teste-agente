--!strict

-- MiningService implements the first functional mining loop:
--
--     DROPPER -> STONE -> CONVEYOR -> COLLECTOR -> CASH
--
-- It owns the placeholder mining structure of every claimed plot (built from code, nothing
-- has to be modelled in Studio), produces the ores, keeps the authoritative registry of
-- which ores are legitimate, validates collection and pays through EconomyService.
--
-- Authority / security model
-- --------------------------
-- * Ores are created only here, on the server. The moment an ore exists it is registered in
--   `oreEntries`, keyed by the Part itself. That table - not the Part - is the authority.
-- * A reward is only ever paid for a Part found in `oreEntries`. A client cannot make an
--   arbitrary Part pay: touching the Collector with a part it replicated, renamed, tagged or
--   parented into the Ores folder is simply "not in the registry" and is ignored.
-- * The amount comes from OreConfig via the ore id registered on the server. Nothing is read
--   back from the physical ore (no attribute, no child value, no name parsing), so tampering
--   with the instance cannot change the payout.
-- * Every ore keeps the server as its network owner, so the server simulates it. A client
--   cannot teleport an ore, and it never sends positions or values to us.
-- * One ore can only pay once: the registry entry is removed before the payout, and there is
--   no yield anywhere between the lookup and the removal, so repeated Touched events (which
--   are expected) can never interleave into a double reward.
--
-- Concurrency
-- -----------
-- No function below yields between validating and mutating state. The only yield points are
-- `task.wait` (production pacing and cleanup sweep), always outside any critical
-- section. `EconomyService.AddCash` is itself non-yielding.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

-- This module lives in Server/Services, next to the services it depends on, so script.Parent
-- is the Services folder itself (same assumption EconomyService makes).
local servicesFolder = script.Parent
assert(servicesFolder ~= nil, "[MiningService] MiningService must be parented under Server/Services")
local plotServiceModule = servicesFolder:WaitForChild("PlotService") :: ModuleScript
local economyServiceModule = servicesFolder:WaitForChild("EconomyService") :: ModuleScript

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")
local oreConfigModule = configFolder:WaitForChild("OreConfig") :: ModuleScript
local miningConfigModule = configFolder:WaitForChild("MiningConfig") :: ModuleScript

local PlotService = require(plotServiceModule)
local EconomyService = require(economyServiceModule)
local OreConfig = require(oreConfigModule)
local MiningConfig = require(miningConfigModule)

-- Minimal shape this service needs from an OreConfig entry. OreConfig exports its full
-- OreType, but a module's exported types cannot be referenced through a required value.
type OreDefinition = {
	Id: string,
	DisplayName: string,
	Value: number,
	Color: Color3,
	Material: Enum.Material,
	Size: Vector3,
}

-- Server-side record for one live ore. Held in `oreEntries` (authoritative) and mirrored in
-- the owning plot's `ActiveOres` (per-plot set, used for the cap and for bulk cleanup).
type OreEntry = {
	OreId: string,
	Plot: Model,
	SpawnTime: number,
	-- Set as soon as the entry stops being payable. Both flags are written before anything
	-- else happens, so a Touched or cleanup callback that re-enters sees a dead entry.
	Collected: boolean,
	Destroyed: boolean,
	AncestryConnection: RBXScriptConnection?,
}

type PlotMining = {
	Plot: Model,
	Model: Model,
	Collector: Part,
	Belt: Part,
	DropPoint: CFrame,
	OresFolder: Folder,
	ActiveOres: { [Part]: OreEntry },
	-- Number of entries in ActiveOres. ActiveOres is keyed by Part, so it has no array part
	-- and `#ActiveOres` is always 0: the per-plot cap needs a counter of its own. It is only
	-- ever changed together with ActiveOres, and the decrement is guarded by the key actually
	-- being present, so it cannot drift or go negative.
	ActiveOreCount: number,
	ProductionThread: thread?,
	CollectorConnection: RBXScriptConnection?,
}

-- Must match PlotService's internal container name; PlotService builds the plots, this
-- service only looks them up.
local PLOTS_FOLDER_NAME = "TycoonPlots"
local MINING_MODEL_NAME = "Mining"
local ORES_FOLDER_NAME = "Ores"
local CONVEYOR_DIRECTION = Vector3.xAxis -- belt runs along plot-local +X, towards the Collector

local plotStates: { [Model]: PlotMining } = {}
local plotDestroyedConnections: { [Model]: RBXScriptConnection } = {}
-- Authoritative registry of every legitimate ore in the game, across all plots.
local oreEntries: { [Part]: OreEntry } = {}
local plotClaimedUnsubscribe: (() -> ())? = nil
local plotReleasedUnsubscribe: (() -> ())? = nil
local cleanupThread: thread? = nil
local initialized = false
-- Set the first time the engine refuses to hand an ore's network ownership to the server, so
-- the warning is printed once instead of once per ore.
local ownershipWarningShown = false

local MiningService = {}

-- ============================================================
-- Small build helpers
-- ============================================================

local function makePart(
	name: string,
	parent: Instance,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material,
	canTouch: boolean,
	canCollide: boolean?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = if canCollide == nil then true else canCollide
	part.CanTouch = canTouch
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function findPlotGround(plot: Model): BasePart?
	local ground = plot.PrimaryPart
	if ground == nil or not ground:IsA("BasePart") then
		warn("[MiningService] Plot " .. plot.Name .. " has no usable PrimaryPart; it cannot host a mining structure")
		return nil
	end
	return ground
end

local function cancelThread(thread: thread?)
	if thread == nil then
		return
	end
	-- pcall: every call site clears its reference before a thread can finish on its own, so
	-- this is only a guard against cancelling an already-dead coroutine.
	local ok, cancelError = pcall(function()
		task.cancel(thread)
	end)
	if not ok then
		warn("[MiningService] Could not cancel a mining thread: " .. tostring(cancelError))
	end
end

-- ============================================================
-- Structure
-- ============================================================

-- Builds the placeholder mining structure for one plot, still detached from Workspace. The
-- returned Model must be parented into the plot before the conveyor velocity is applied,
-- because assembly properties only exist for parts that are in the physical world.
local function createMiningModel(ground: BasePart): (Model, Part, Part, CFrame, Folder)
	local origin = ground.CFrame
	local belt = MiningConfig.Belt
	local beltLength = belt.EndX - belt.StartX
	local beltCenterX = (belt.StartX + belt.EndX) / 2
	local beltTopY = belt.Height
	local beltCenterY = beltTopY - belt.Thickness / 2
	local underBeltHeight = belt.Height - belt.Thickness

	local model = Instance.new("Model")
	model.Name = MINING_MODEL_NAME

	-- ---------------- Dropper ----------------
	local dropper = MiningConfig.Dropper
	local dropperFolder = Instance.new("Folder")
	dropperFolder.Name = "Dropper"
	dropperFolder.Parent = model

	makePart(
		"Tower",
		dropperFolder,
		dropper.TowerSize,
		origin * CFrame.new(dropper.TowerOffset),
		dropper.Color,
		dropper.Material,
		false
	)
	makePart(
		"Head",
		dropperFolder,
		dropper.HeadSize,
		origin * CFrame.new(dropper.HeadOffset),
		dropper.Color,
		dropper.Material,
		false
	)

	-- ---------------- Conveyor ----------------
	local conveyorFolder = Instance.new("Folder")
	conveyorFolder.Name = "Conveyor"
	conveyorFolder.Parent = model

	-- One single belt part on purpose: two anchored parts whose faces touch are welded into
	-- one assembly by the engine, and an assembly takes its velocity from its root. A single
	-- part keeps "set the velocity once" unambiguous.
	local beltPart = makePart(
		"Belt",
		conveyorFolder,
		Vector3.new(beltLength, belt.Thickness, belt.Width),
		origin * CFrame.new(beltCenterX, beltCenterY, 0),
		belt.Color,
		belt.Material,
		false
	)
	-- Smooth so an ore slides along the belt instead of catching on a surface texture.
	beltPart.TopSurface = Enum.SurfaceType.Smooth

	for _, legX in belt.LegOffsetsX do
		makePart(
			"Leg",
			conveyorFolder,
			Vector3.new(belt.LegSize.X, underBeltHeight, belt.LegSize.Z),
			origin * CFrame.new(legX, underBeltHeight / 2, 0),
			belt.RailColor,
			belt.RailMaterial,
			false
		)
	end

	for _, side in { 1, -1 } do
		makePart(
			"Rail",
			conveyorFolder,
			Vector3.new(beltLength, belt.RailHeight, belt.RailThickness),
			origin * CFrame.new(beltCenterX, beltTopY + belt.RailHeight / 2, side * belt.RailOffsetZ),
			belt.RailColor,
			belt.RailMaterial,
			false
		)
	end

	-- Chevrons pointing towards the Collector: the direction of the line has to be readable
	-- without textures or animation. Two tilted bars per center form a ">" shape. Pure
	-- geometry - no script, no tween, no per-frame cost.
	local chevron = MiningConfig.Chevron
	local chevronFolder = Instance.new("Folder")
	chevronFolder.Name = "DirectionArrows"
	chevronFolder.Parent = model

	local barAngle = CFrame.Angles(0, math.rad(chevron.BarAngleDegrees), 0)
	for _, centerX in chevron.CentersX do
		local center = origin * CFrame.new(centerX, chevron.Height, 0)
		for _, side in { 1, -1 } do
			makePart(
				"Arrow",
				chevronFolder,
				chevron.BarSize,
				center * barAngle * CFrame.new(0, 0, side * chevron.BarOffsetZ),
				chevron.Color,
				chevron.Material,
				false
			)
		end
	end

	-- ---------------- Collector ----------------
	local collector = MiningConfig.Collector
	local sensor = collector.Sensor
	local hopper = collector.Hopper
	local sensorCenterX = sensor.FrontX + sensor.Size.X / 2
	local hopperSpanX = hopper.BackX - hopper.StartX
	local hopperCenterX = (hopper.StartX + hopper.BackX) / 2
	local collectorFolder = Instance.new("Folder")
	collectorFolder.Name = "Collector"
	collectorFolder.Parent = model

	-- The only part of the structure that listens for touches: it is the sell point, so it is
	-- the only one that needs touch events. Everything else keeps CanTouch = false.
	--
	-- CanCollide = false is what makes this reliable: the trigger overlaps the end of the
	-- belt, and a solid part there would stop the ore while it is still riding (an anchored
	-- part cannot be pushed aside). As a pure trigger the ore rides straight into it.
	local collectorPart = makePart(
		"Collector",
		collectorFolder,
		sensor.Size,
		origin * CFrame.new(sensorCenterX, sensor.CenterY, 0),
		collector.Color,
		collector.Material,
		true,
		false
	)
	collectorPart.Transparency = sensor.Transparency

	-- Visible hopper around the trigger. The floor also catches an ore that ever leaves the
	-- belt, so the line never drops stones onto the plot ground.
	makePart(
		"Floor",
		collectorFolder,
		Vector3.new(hopperSpanX, hopper.FloorTopY, hopper.HalfZ * 2),
		origin * CFrame.new(hopperCenterX, hopper.FloorTopY / 2, 0),
		collector.Color,
		collector.Material,
		false
	)
	makePart(
		"BackWall",
		collectorFolder,
		Vector3.new(hopper.WallThickness, hopper.CapBottomY, hopper.HalfZ * 2),
		origin * CFrame.new(hopper.BackX - hopper.WallThickness / 2, hopper.CapBottomY / 2, 0),
		collector.Color,
		collector.Material,
		false
	)
	for _, side in { 1, -1 } do
		makePart(
			"SideWall",
			collectorFolder,
			Vector3.new(hopperSpanX, hopper.CapBottomY, hopper.WallThickness),
			origin
				* CFrame.new(
					hopperCenterX,
					hopper.CapBottomY / 2,
					side * (hopper.HalfZ - hopper.WallThickness / 2)
				),
			collector.Color,
			collector.Material,
			false
		)
	end
	makePart(
		"Cap",
		collectorFolder,
		Vector3.new(hopperSpanX, hopper.CapThickness, hopper.HalfZ * 2),
		origin * CFrame.new(hopperCenterX, hopper.CapBottomY + hopper.CapThickness / 2, 0),
		collector.Color,
		collector.Material,
		false
	)
	makePart(
		"Top",
		collectorFolder,
		collector.TopSize,
		origin * CFrame.new(hopperCenterX, collector.TopOffsetY, 0),
		collector.TopColor,
		collector.TopMaterial,
		false
	)

	-- ---------------- Ores ----------------
	local oresFolder = Instance.new("Folder")
	oresFolder.Name = ORES_FOLDER_NAME
	oresFolder.Parent = model

	model.PrimaryPart = beltPart

	local dropPoint = origin * CFrame.new(MiningConfig.DropPointOffset)
	return model, collectorPart, beltPart, dropPoint, oresFolder
end

-- ============================================================
-- Ore registry
-- ============================================================

local function unregisterOre(part: Part, entry: OreEntry)
	-- Detach the record from both indexes first: after this the ore can no longer be found,
	-- so it can no longer pay, no matter what happens to the Part next.
	oreEntries[part] = nil
	local plotState = plotStates[entry.Plot]
	-- Presence check first: unregisterOre can legitimately run more than once for the same ore
	-- (collection, expiry, teardown, AncestryChanged), and the counter must only move with the
	-- map entry it tracks.
	if plotState ~= nil and plotState.ActiveOres[part] ~= nil then
		plotState.ActiveOres[part] = nil
		plotState.ActiveOreCount -= 1
	end

	local connection = entry.AncestryConnection
	if connection ~= nil then
		entry.AncestryConnection = nil
		connection:Disconnect()
	end
end

local function destroyOre(part: Part, entry: OreEntry)
	if entry.Destroyed then
		return
	end
	entry.Destroyed = true
	unregisterOre(part, entry)
	part:Destroy()
end

-- Destroys every live ore of one plot. Called when the plot is released and when its
-- structure is torn down, so a plot without an owner can never keep producing money.
-- Only that plot's ores are touched: entries are indexed per plot, never scanned globally.
local function destroyActiveOres(plotState: PlotMining)
	-- Snapshot first: destroyOre mutates ActiveOres, and removing keys from a table while
	-- iterating it is not something to rely on.
	local parts: { Part } = table.create(0)
	for part in plotState.ActiveOres do
		table.insert(parts, part)
	end
	for _, part in parts do
		local entry = plotState.ActiveOres[part]
		if entry ~= nil then
			destroyOre(part, entry)
		end
	end
	table.clear(plotState.ActiveOres)
	plotState.ActiveOreCount = 0
end

local function spawnOre(plot: Model, plotState: PlotMining)
	if plotState.ActiveOreCount >= MiningConfig.MaxActiveOresPerPlot then
		-- Cap reached: skip this drop and try again on the next tick. Nothing is destroyed to
		-- make room, and OreLifetime guarantees the cap cannot stay saturated forever.
		return
	end

	local oreId = OreConfig.DefaultOreId
	local oreType: OreDefinition? = OreConfig.GetOreType(oreId)
	if oreType == nil then
		warn("[MiningService] OreConfig.DefaultOreId '" .. tostring(oreId) .. "' is not defined in OreConfig.OreTypes")
		return
	end

	local part = Instance.new("Part")
	part.Name = MiningConfig.OreName
	part.Size = oreType.Size
	part.Color = oreType.Color
	part.Material = oreType.Material
	-- Never anchored: it has to fall onto the belt, and the network ownership API refuses
	-- anchored parts (see below).
	part.Anchored = false
	part.CanCollide = true
	part.CanTouch = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CFrame = plotState.DropPoint

	-- Debug / future-visual identity only. Never read back to decide a reward: the registry
	-- is the authority, and a client that changes these learns nothing it can cash in.
	part:SetAttribute(MiningConfig.OreTagAttribute, oreId)
	part:SetAttribute(MiningConfig.OrePlotNameAttribute, plot.Name)

	part.Parent = plotState.OresFolder

	local entry: OreEntry = {
		OreId = oreId,
		Plot = plot,
		SpawnTime = os.clock(),
		Collected = false,
		Destroyed = false,
		AncestryConnection = nil,
	}

	-- Network ownership: ask the server to keep simulating the ore.
	--
	-- An ore is money, so its physics should not be decided by a client. With automatic
	-- ownership Roblox may hand a free-falling assembly to whoever is nearest, and that client
	-- would then control where the ore goes: it could keep the ore away from the Collector, or
	-- shove it into another plot's Collector. Requesting the server as owner (nil) makes the
	-- server simulate and replicate it instead, which also keeps Touched on the Collector
	-- firing on the server, exactly where the validation happens. This is affordable because
	-- the caps above bound how many ores are server-simulated at once (PlotCount x
	-- MaxActiveOresPerPlot).
	--
	-- Two engine constraints decide the ordering above:
	--   * assemblies only exist for parts that are in the world, and ownership can only be set
	--     on the root of an assembly, so Parent must be assigned first;
	--   * the ownership API refuses anchored parts ("Network Ownership API cannot be called on
	--     Anchored parts or parts welded to Anchored parts"), which is why the ore is created
	--     unanchored rather than anchored-then-released. Nothing between parenting and this
	--     call yields, so no physics step can run in between.
	local ok, ownershipError = pcall(function()
		part:SetNetworkOwner(nil)
	end)
	if not ok and not ownershipWarningShown then
		-- Deliberately NOT fatal. Refusing to produce would break the entire mining loop over a
		-- defense-in-depth measure: the authoritative protection is the registry. The reward is
		-- read from OreConfig by the ore id the server recorded when it created this Part, and
		-- the payee is re-resolved through PlotService at collection time, so a client that
		-- ended up owning an ore's physics could influence where that ore travels - never what
		-- it pays, never who is paid, and never how many times. Warn once instead of per ore so
		-- the situation stays visible without flooding the output.
		ownershipWarningShown = true
		warn(
			"[MiningService] Could not keep server ownership of an ore on "
				.. plot.Name
				.. " ("
				.. tostring(ownershipError)
				.. "); continuing with automatic ownership. Further occurrences are not logged."
		)
	end

	oreEntries[part] = entry
	plotState.ActiveOres[part] = entry
	plotState.ActiveOreCount += 1

	-- Connected after registration: from here on any unexpected removal of the Part (deleted
	-- from Studio, or by anything else) is detected and unregistered, so the registry and the
	-- per-plot cap can never drift out of sync with reality.
	entry.AncestryConnection = part.AncestryChanged:Connect(function(_, parent: Instance?)
		if entry.Destroyed then
			return
		end
		if parent == nil and oreEntries[part] == entry then
			-- The Part is gone without going through destroyOre; drop the record.
			entry.Destroyed = true
			unregisterOre(part, entry)
		end
	end)
end

-- ============================================================
-- Collection
-- ============================================================

-- Touched handler of one plot's Collector.
--
-- `Touched` fires repeatedly while parts stay in contact and can fire several times for the
-- same ore, so this function is written to be cheap on the (very common) "not an ore" path
-- and unable to pay twice on the "is an ore" path.
local function collectOre(plotState: PlotMining, touchedPart: BasePart)
	-- Anything that is not a registered, live ore of THIS plot is ignored. This is what
	-- rejects arbitrary client-side parts, ores of other plots and ores already paid.
	local entry = oreEntries[touchedPart]
	if entry == nil then
		return
	end
	if entry.Collected or entry.Destroyed then
		return
	end
	if entry.Plot ~= plotState.Plot then
		return
	end

	-- Marked dead before anything else. There is no yield from the lookup above to here, so a
	-- second Touched event for the same ore can only ever observe Collected/Destroyed or a
	-- missing registry entry: the reward cannot be granted twice.
	entry.Collected = true
	unregisterOre(touchedPart, entry)

	-- Ownership is re-resolved from PlotService at this moment instead of being trusted from
	-- spawn time: the player who owned the plot when the ore was created may have left while
	-- the ore was in transit.
	local owner = PlotService.GetPlotOwner(plotState.Plot)
	if owner == nil or owner.Parent ~= Players then
		-- Plot released while the ore was travelling: nobody is paid.
		destroyOre(touchedPart, entry)
		return
	end

	local oreType: OreDefinition? = OreConfig.GetOreType(entry.OreId)
	if oreType == nil then
		warn(
			"[MiningService] Ore id '"
				.. entry.OreId
				.. "' has no OreConfig definition; destroying the ore without paying"
		)
		destroyOre(touchedPart, entry)
		return
	end

	destroyOre(touchedPart, entry)
	if not EconomyService.AddCash(owner, oreType.Value) then
		-- Only possible when the owner has no economy state left (already removed). The ore
		-- stays consumed; Cash is never granted through any other path.
		warn("[MiningService] EconomyService refused " .. tostring(oreType.Value) .. " for " .. owner.Name)
	end
end

-- ============================================================
-- Production
-- ============================================================

local function stopProduction(plotState: PlotMining)
	local thread = plotState.ProductionThread
	plotState.ProductionThread = nil
	cancelThread(thread)
end

local function startProduction(plot: Model, plotState: PlotMining)
	stopProduction(plotState)
	plotState.ProductionThread = task.spawn(function()
		while plotStates[plot] == plotState do
			-- task.wait yields THIS thread, so MiningConfig.DropInterval really is the time
			-- between two ores. (task.delay would need a callback and would not pause the
			-- loop at all.)
			task.wait(MiningConfig.DropInterval)
			-- Re-checked after the wait: the plot may have been released (or released and
			-- claimed again, in which case plotStates holds a different PlotMining) while
			-- this thread was sleeping, and it must not produce for that plot any more.
			if plotStates[plot] ~= plotState then
				break
			end
			spawnOre(plot, plotState)
		end
	end)
end

-- ============================================================
-- Structure lifecycle
-- ============================================================

local function teardownPlot(plot: Model)
	local plotState = plotStates[plot]
	if plotState == nil then
		return
	end

	-- Production stops before the ores go, so nothing can be spawned into a plot that is
	-- being cleared.
	stopProduction(plotState)
	destroyActiveOres(plotState)

	local connection = plotState.CollectorConnection
	if connection ~= nil then
		plotState.CollectorConnection = nil
		connection:Disconnect()
	end

	plotStates[plot] = nil
	plotState.Model:Destroy()
end

local function handlePlotClaimed(plot: Model, _player: Player)
	if plotStates[plot] ~= nil then
		-- Defensive: PlotService guarantees one owner per plot, so this should not happen.
		warn("[MiningService] Plot " .. plot.Name .. " was claimed while its mining structure already existed")
		return
	end
	if not plot:IsDescendantOf(Workspace) then
		warn("[MiningService] Plot " .. plot.Name .. " is not in Workspace; it cannot host a mining structure")
		return
	end

	local ground = findPlotGround(plot)
	if ground == nil then
		return
	end

	local model, collector, belt, dropPoint, oresFolder = createMiningModel(ground)
	model.Parent = plot

	local plotState: PlotMining = {
		Plot = plot,
		Model = model,
		Collector = collector,
		Belt = belt,
		DropPoint = dropPoint,
		OresFolder = oresFolder,
		ActiveOres = {},
		ActiveOreCount = 0,
		ProductionThread = nil,
		CollectorConnection = nil,
	}
	plotStates[plot] = plotState

	-- Applied after the structure is inside Workspace: a velocity set before parenting is
	-- lost, because assemblies only exist for parts in the physical world. Set exactly once -
	-- the belt is anchored and nothing ever moves it, so the engine keeps carrying ores with
	-- no loop, no Heartbeat connection and no per-ore script.
	belt.AssemblyLinearVelocity = belt.CFrame:VectorToWorldSpace(
		CONVEYOR_DIRECTION * MiningConfig.ConveyorSpeed
	)

	plotState.CollectorConnection = collector.Touched:Connect(function(touchedPart: BasePart)
		collectOre(plotState, touchedPart)
	end)

	startProduction(plot, plotState)
end

local function handlePlotReleased(plot: Model, _player: Player)
	teardownPlot(plot)
end

-- Safety net for the plot itself disappearing (deleted in Studio, or PlotService rebuilding
-- its container). Without it the production thread would keep running against a dead plot.
local function handlePlotDestroyed(plot: Model)
	local connection = plotDestroyedConnections[plot]
	if connection ~= nil then
		plotDestroyedConnections[plot] = nil
		connection:Disconnect()
	end
	teardownPlot(plot)
end

-- ============================================================
-- Cleanup
-- ============================================================

-- One sweep for the whole game on a fixed interval, instead of one timer per ore. It only
-- iterates the registry (bounded by PlotCount * MaxActiveOresPerPlot) and destroys ores that
-- outlived OreLifetime. Collected ores are already gone from the registry so they are never
-- revisited, and ores of other plots are untouched because every entry knows its own plot.
local function cleanupExpiredOres()
	local now = os.clock()
	for part, entry in oreEntries do
		if entry.Destroyed then
			oreEntries[part] = nil
		elseif now - entry.SpawnTime >= MiningConfig.OreLifetime then
			destroyOre(part, entry)
		end
	end
end

-- ============================================================
-- Validation
-- ============================================================

-- EconomyService.AddCash only accepts positive whole numbers, so an ore value that is not one
-- would silently pay nothing. Catching that at startup is much cheaper than debugging a loop
-- that produces ores and never increases Cash.
local function isPositiveWholeNumber(value: any): boolean
	return type(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value > 0
		and value % 1 == 0
end

local function isFinitePositive(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value > 0
end

local function validateOreTypes()
	local defined = 0
	for oreId, oreType in OreConfig.OreTypes do
		defined += 1
		if type(oreId) ~= "string" or oreId == "" then
			error("[MiningService] Every key of OreConfig.OreTypes must be a non-empty string")
		end
		if type(oreType) ~= "table" then
			error("[MiningService] OreConfig.OreTypes." .. oreId .. " must be a table")
		end
		if oreType.Id ~= oreId then
			error("[MiningService] OreConfig.OreTypes." .. oreId .. ".Id must equal its key")
		end
		if type(oreType.DisplayName) ~= "string" or oreType.DisplayName == "" then
			error("[MiningService] OreConfig.OreTypes." .. oreId .. ".DisplayName must be a non-empty string")
		end
		if not isPositiveWholeNumber(oreType.Value) then
			error(
				"[MiningService] OreConfig.OreTypes."
					.. oreId
					.. ".Value must be a whole number > 0 (EconomyService requirement)"
			)
		end
		if typeof(oreType.Color) ~= "Color3" then
			error("[MiningService] OreConfig.OreTypes." .. oreId .. ".Color must be a Color3")
		end
		if typeof(oreType.Size) ~= "Vector3" then
			error("[MiningService] OreConfig.OreTypes." .. oreId .. ".Size must be a Vector3")
		end
		local size = oreType.Size :: Vector3
		if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
			error("[MiningService] OreConfig.OreTypes." .. oreId .. ".Size must be positive on every axis")
		end
	end
	if defined == 0 then
		error("[MiningService] OreConfig.OreTypes must define at least one ore")
	end

	local defaultId = OreConfig.DefaultOreId
	if type(defaultId) ~= "string" or OreConfig.GetOreType(defaultId) == nil then
		error("[MiningService] OreConfig.DefaultOreId must name an ore defined in OreConfig.OreTypes")
	end
end

-- Checks the relationships that would otherwise only fail as "the ore never reaches the
-- Collector", which is very hard to diagnose from inside Studio.
local function validateMiningConfig()
	if not isFinitePositive(MiningConfig.DropInterval) then
		error("[MiningService] MiningConfig.DropInterval must be a finite number > 0")
	end
	if not isFinitePositive(MiningConfig.OreLifetime) then
		error("[MiningService] MiningConfig.OreLifetime must be a finite number > 0")
	end
	if not isFinitePositive(MiningConfig.CleanupInterval) then
		error("[MiningService] MiningConfig.CleanupInterval must be a finite number > 0")
	end
	if not isFinitePositive(MiningConfig.ConveyorSpeed) then
		error("[MiningService] MiningConfig.ConveyorSpeed must be a finite number > 0")
	end
	if not isPositiveWholeNumber(MiningConfig.MaxActiveOresPerPlot) then
		error("[MiningService] MiningConfig.MaxActiveOresPerPlot must be a whole number > 0")
	end

	local belt = MiningConfig.Belt
	if type(belt.StartX) ~= "number" or type(belt.EndX) ~= "number" then
		error("[MiningService] MiningConfig.Belt.StartX/EndX must be numbers")
	end
	if belt.EndX - belt.StartX <= 0 then
		error("[MiningService] MiningConfig.Belt.EndX must be greater than Belt.StartX (ores travel towards +X)")
	end
	if belt.Width <= 0 or belt.Thickness <= 0 or belt.Height <= belt.Thickness then
		error("[MiningService] MiningConfig.Belt.Width/Thickness must be > 0 and Height must be > Thickness")
	end

	-- The ore has to land on the belt, between the rails, and clear of the Dropper head.
	local defaultOre = OreConfig.GetOreType(OreConfig.DefaultOreId) :: OreDefinition
	local halfOre = (defaultOre.Size :: Vector3) / 2
	local dropPoint = MiningConfig.DropPointOffset :: Vector3

	if dropPoint.X - halfOre.X < belt.StartX or dropPoint.X + halfOre.X > belt.EndX then
		error("[MiningService] MiningConfig.DropPointOffset.X must keep the whole ore on the belt")
	end
	if math.abs(dropPoint.Z) + halfOre.Z > belt.RailOffsetZ - belt.RailThickness / 2 then
		error("[MiningService] MiningConfig.DropPointOffset.Z must keep the ore inside the conveyor rails")
	end
	if dropPoint.Y - halfOre.Y <= belt.Height then
		error("[MiningService] MiningConfig.DropPointOffset.Y must place the ore above the belt surface")
	end
	local dropper = MiningConfig.Dropper
	local headBottom = (dropper.HeadOffset :: Vector3).Y - (dropper.HeadSize :: Vector3).Y / 2
	if dropPoint.Y + halfOre.Y > headBottom then
		error("[MiningService] MiningConfig.DropPointOffset.Y must place the ore below the Dropper head")
	end

	-- The sell trigger has to cover the end of the belt. An ore is only guaranteed to be sold
	-- while it is still supported by the belt: past Belt.EndX it becomes a projectile, and
	-- where exactly it lands is not something a tycoon loop should depend on.
	local collector = MiningConfig.Collector
	local sensor = collector.Sensor
	local sensorSize = sensor.Size :: Vector3
	local sensorFrontX = sensor.FrontX
	local sensorBackX = sensorFrontX + sensorSize.X
	local sensorBottomY = sensor.CenterY - sensorSize.Y / 2
	local sensorTopY = sensor.CenterY + sensorSize.Y / 2

	if sensorBackX <= belt.EndX then
		error(
			"[MiningService] MiningConfig.Collector.Sensor must reach past MiningConfig.Belt.EndX, "
				.. "otherwise an ore can leave the belt without ever being sold"
		)
	end
	-- At least one ore width of belt-side overlap, so the trigger catches the ore before it
	-- reaches the belt end instead of relying on its flight path.
	local requiredOverlap = 2
	if sensorFrontX > belt.EndX - requiredOverlap then
		error(
			"[MiningService] MiningConfig.Collector.Sensor.FrontX must overlap MiningConfig.Belt.EndX by at least "
				.. requiredOverlap
				.. " studs, otherwise ores can slide off the belt without touching the Collector"
		)
	end
	if sensorBottomY > belt.Height or sensorTopY < belt.Height + defaultOre.Size.Y then
		error(
			"[MiningService] MiningConfig.Collector.Sensor must cover the whole ore path above the belt "
				.. "(from Belt.Height up to Belt.Height + ore height)"
		)
	end
	if dropPoint.X + halfOre.X > sensorFrontX then
		error("[MiningService] MiningConfig.DropPointOffset.X must spawn ores before the Collector")
	end

	-- The hopper floor has to sit under the trigger so anything that does leave the belt is
	-- caught inside the machine instead of falling onto the plot ground.
	local hopper = collector.Hopper
	if hopper.FloorTopY > sensorBottomY or hopper.StartX > sensorFrontX or hopper.BackX < sensorBackX then
		error("[MiningService] MiningConfig.Collector.Hopper must span and floor the whole Sensor volume")
	end
end

-- ============================================================
-- Public API
-- ============================================================

function MiningService.Initialize()
	if initialized then
		return
	end

	validateOreTypes()
	validateMiningConfig()

	-- PlotService must already have built the plots: this service reacts to its claim/release
	-- notifications and reads plot ownership through it.
	local plotsFolder = Workspace:FindFirstChild(PLOTS_FOLDER_NAME)
	if plotsFolder == nil then
		error(
			"[MiningService] Workspace."
				.. PLOTS_FOLDER_NAME
				.. " is missing; PlotService.Initialize() must run first"
		)
	end

	plotClaimedUnsubscribe = PlotService.OnPlotClaimed(handlePlotClaimed)
	plotReleasedUnsubscribe = PlotService.OnPlotReleased(handlePlotReleased)

	-- Plots that are already owned when this service starts (only possible if the
	-- initialization order ever changes) get their structure immediately, so no claim
	-- notification is needed for them.
	local plots: { Model } = table.create(0)
	for _, child in plotsFolder:GetChildren() do
		if child:IsA("Model") then
			table.insert(plots, child)
		end
	end
	table.sort(plots, function(a: Model, b: Model): boolean
		return (a.Name :: string) < (b.Name :: string)
	end)

	for _, plot in plots do
		plotDestroyedConnections[plot] = plot.AncestryChanged:Connect(function(_, parent: Instance?)
			if parent == nil then
				handlePlotDestroyed(plot)
			end
		end)

		local owner = PlotService.GetPlotOwner(plot)
		if owner ~= nil then
			handlePlotClaimed(plot, owner)
		end
	end

	cleanupThread = task.spawn(function()
		while true do
			task.wait(MiningConfig.CleanupInterval)
			cleanupExpiredOres()
		end
	end)

	initialized = true
end

-- Stops production everywhere, destroys every ore and removes every structure. Nothing is
-- paid out by this call. Intended for tests and for Studio iteration.
function MiningService.Shutdown()
	if not initialized then
		return
	end

	if plotClaimedUnsubscribe ~= nil then
		plotClaimedUnsubscribe()
		plotClaimedUnsubscribe = nil
	end
	if plotReleasedUnsubscribe ~= nil then
		plotReleasedUnsubscribe()
		plotReleasedUnsubscribe = nil
	end

	cancelThread(cleanupThread)
	cleanupThread = nil

	for _, connection in plotDestroyedConnections do
		connection:Disconnect()
	end
	table.clear(plotDestroyedConnections)

	for plot in plotStates do
		teardownPlot(plot)
	end
	table.clear(plotStates)
	table.clear(oreEntries)

	initialized = false
end

-- Number of live ores registered for a plot. Useful when testing the MaxActiveOresPerPlot cap
-- from the Studio command bar; the mining loop itself never calls it.
function MiningService.GetActiveOreCount(plot: Model): number
	local plotState = plotStates[plot]
	if plotState == nil then
		return 0
	end
	return plotState.ActiveOreCount
end

-- Age in seconds of the oldest live ore of a plot, or -1 when it has none. Debug helper used
-- to observe that OreLifetime cleanup is really bounding how long an ore can exist.
function MiningService.GetOldestActiveOreAge(plot: Model): number
	local plotState = plotStates[plot]
	if plotState == nil then
		return -1
	end

	local oldest = -1
	local now = os.clock()
	for _, entry in plotState.ActiveOres do
		local age = now - entry.SpawnTime
		if age > oldest then
			oldest = age
		end
	end
	return oldest
end

return MiningService
