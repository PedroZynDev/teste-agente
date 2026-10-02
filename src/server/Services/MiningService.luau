--!strict

-- MiningService: the mining production cycle.
--
--	Dropper -> physical Stone Part -> ConveyorSurface (belt) -> CollectorTrigger
--	-> EconomyService.AddCash(owner, OreConfig entry Value)  =>  +$1 per stone.
--
-- A plot's production is modelled as "lines". One line = one full clone of the
-- starter setup installed at its own pivot offset. Claiming installs the free
-- starter line (index 1); the first purchase flow (PurchaseService) can add
-- purchasable extra lines through MiningService.AddExtraDropperLine. Everything
-- in this module is server-side only; no RemoteEvents/RemoteFunctions are created.
--
-- Design notes:
--
-- * The visual setup is the Studio-authored asset
--     ServerStorage.Assets.Mining.StarterMiningSetup
--   (~212 parts, configured pivot). It is NOT recreated here and NOT in Git; the service
--   only clones it at runtime and depends on its three integration points:
--     Dropper.OreSpawn, Conveyor.ConveyorSurface, Collector.CollectorTrigger
--   Decorative geometry can change freely as long as those points exist.
--
-- * Each clone is placed with Model:PivotTo() using a CFrame computed from the plot
--   itself (plot ground top surface + the line's offset from MiningConfig.LinePivotOffsets,
--   identity rotation). Dropper/Conveyor/Collector are never moved individually and no
--   world coordinates of the original template are hardcoded. All plots get the same
--   local placement, so installations can never overlap each other.
--
-- * Reward authority is a server-side registry (`activeOres` below), keyed by the ore
--   Part itself. Names and attributes on parts are debug aids only; an arbitrary or
--   spoofed part touching the collector can never mint Cash, and no client input is ever
--   trusted for positions, ownership or values.
--
-- * Conveyor movement uses ONE centralized Heartbeat pass over all active ores (no per-ore
--   coroutine): while an ore is within its line's belt span its horizontal velocity is
--   pinned to BeltSpeed and its vertical velocity is left to physics. Movement is smooth,
--   constant and physical; ores are never teleported to the collector. The belt direction
--   is derived from the ConveyorSurface CFrame, so a future rotated setup still works.
--
-- * Ores stay server-owned (SetNetworkOwner(nil)) so nearby clients cannot simulate or
--   influence them.
--
-- Deliberately out of scope for this phase: upgrade levels, multiple ore types, buttons
-- and screen UI, levels, DataStore/persistence, rebirth, Rubis, shop, and any RemoteEvent/
-- RemoteFunction. The StarterMiningSetup appears automatically after claim only to
-- validate the core loop; only the extra-line capacity for the first purchase is exposed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")
local miningConfigModule = configFolder:WaitForChild("MiningConfig") :: ModuleScript
local MiningConfig = require(miningConfigModule)
local oreConfigModule = configFolder:WaitForChild("OreConfig") :: ModuleScript
local OreConfig = require(oreConfigModule)

local servicesFolder = script.Parent
local plotServiceModule = servicesFolder:WaitForChild("PlotService") :: ModuleScript
local PlotService = require(plotServiceModule)
local economyServiceModule = servicesFolder:WaitForChild("EconomyService") :: ModuleScript
local EconomyService = require(economyServiceModule)

local TEMPLATE_PATH = "ServerStorage.Assets.Mining.StarterMiningSetup"
local MINING_SETUP_NAME = "Mining"
local ORES_FOLDER_NAME = "Ores"
-- Plot ground part created by PlotService.createPlot; used to place the setup on the
-- surface of the plot. Falls back to Model:GetPivot() if the layout is renamed.
local GROUND_PART_NAME = "Ground"

-- The three mandatory integration points, as <container>.<part> inside StarterMiningSetup.
local INTEGRATION_POINTS = table.freeze({
	table.freeze({ Container = "Dropper", Point = "OreSpawn" }),
	table.freeze({ Container = "Conveyor", Point = "ConveyorSurface" }),
	table.freeze({ Container = "Collector", Point = "CollectorTrigger" }),
})

type OreDefinition = {
	Id: string,
	DisplayName: string,
	Value: number,
	Size: Vector3,
	Color: Color3,
	Material: Enum.Material,
}

-- One installed clone of the template (one conveyor flow with its own collector).
type MiningLine = {
	Setup: Model,
	SpawnPoint: BasePart,
	Collector: BasePart,
	CollectorConnection: RBXScriptConnection?,
	-- Belt geometry cached in world space right after PivotTo: unit direction (derived
	-- from ConveyorSurface, NOT assumed to be world +Z), the drop point as origin and
	-- how far along the direction ores are still pushed.
	BeltDirection: Vector3,
	BeltVelocity: Vector3,
	BeltOrigin: Vector3,
	BeltLimit: number,
}

-- Per-plot state shared by all lines of that plot. Releasing the plot tears the whole
-- state down and never touches another plot's state.
type PlotMiningState = {
	Plot: Model,
	Owner: Player,
	Lines: { MiningLine },
	OresFolder: Folder,
	-- Authoritative per-plot ore bookkeeping (cap + cleanup), shared across lines:
	ActiveOres: { [BasePart]: boolean },
	ActiveOreCount: number,
	Active: boolean,
}

-- Authoritative record of every ore this service created, keyed by the Part itself.
-- An instance that is not in this table does not exist for the economy.
type OreRegistration = {
	OreId: string,
	Plot: Model,
	State: PlotMiningState,
	Line: MiningLine,
	Owner: Player,
	Collected: boolean,
	SpawnedAt: number,
}

local oreConfigsById: { [string]: OreDefinition } = {}
local setupsByPlot: { [Model]: PlotMiningState } = {}
local activeOres: { [BasePart]: OreRegistration } = {}

local initialized = false
local enabled = false
local template: Model? = nil
local dropOreDefinition: OreDefinition? = nil
local activePlotCount = 0
local heartbeatConnection: RBXScriptConnection? = nil

local MiningService = {}

local function isFiniteNumber(value: any): boolean
	return type(value) == "number"
		and value == value -- false only for NaN
		and value ~= math.huge
		and value ~= -math.huge
end

local function isWholeNumber(value: any): boolean
	return isFiniteNumber(value) and value % 1 == 0
end

-- Resolves one mandatory integration point (<container>.<part>) inside a setup model.
local function findIntegrationPoint(root: Instance, containerName: string, pointName: string): BasePart?
	local container = root:FindFirstChild(containerName)
	if container == nil then
		return nil
	end
	local point = container:FindFirstChild(pointName)
	if point == nil or not point:IsA("BasePart") then
		return nil
	end
	return point
end

local function describeIntegrationPoint(rootPath: string, containerName: string, pointName: string): string
	return ("%s.%s.%s (must be a BasePart)"):format(rootPath, containerName, pointName)
end

-- === Ore registry ===

-- Idempotent: removes the ore from the global registry and decrements the per-plot
-- authoritative counter exactly once (the registry entry is the proof it was counted).
local function unregisterOre(part: BasePart)
	local info = activeOres[part]
	if info == nil then
		return
	end
	activeOres[part] = nil
	local state = info.State
	if state.ActiveOres[part] ~= nil then
		state.ActiveOres[part] = nil
		state.ActiveOreCount -= 1
	end
end

-- Cleanup is idempotent for collect/lifetime/release races: whoever gets here first does
-- the work, whoever arrives later sees no registry entry and a safe no-op Destroy.
local function destroyOre(part: BasePart)
	unregisterOre(part)
	part:Destroy()
end

-- === Conveyor + lifetime (one centralized pass for every plot) ===

-- A single Heartbeat drives all ores in all plots, instead of one coroutine per ore.
-- The pass is O(number of live ores) (capped at MaxActiveOresPerPlot per plot), reads
-- only cached geometry, and never queries the setup hierarchy, so it stays cheap with
-- several plots running multiple lines simultaneously.
local function onHeartbeat()
	local now = os.clock()
	local lifetime = MiningConfig.OreLifetime
	for part, info in activeOres do
		if now - info.SpawnedAt >= lifetime then
			-- Uncollected ore: remove from registry, destroy the part, free the slot.
			destroyOre(part)
		else
			local line = info.Line
			local along = (part.Position - line.BeltOrigin):Dot(line.BeltDirection)
			if along <= line.BeltLimit then
				-- Pin horizontal velocity to the belt speed and preserve vertical velocity
				-- so physics still owns falling/bouncing. Constant, visible movement with
				-- no teleporting; server-owned parts, so clients only receive results.
				local beltVelocity = line.BeltVelocity
				part.AssemblyLinearVelocity = Vector3.new(
					beltVelocity.X,
					part.AssemblyLinearVelocity.Y,
					beltVelocity.Z
				)
			end
		end
	end
end

-- Only run the conveyor pass while at least one plot is producing; idle servers pay
-- nothing for it.
local function updateConveyorLoop()
	if activePlotCount > 0 and heartbeatConnection == nil then
		heartbeatConnection = RunService.Heartbeat:Connect(onHeartbeat)
	elseif activePlotCount == 0 and heartbeatConnection ~= nil then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
end

-- === Collector ===

-- The only place ore is converted into Cash. Everything here is synchronous (the Touched
-- handler never yields), which is what makes the claim atomic: once Collected is set, no
-- second callback can pay for the same ore, and EconomyService.AddCash does not yield.
local function handleCollectorTouched(state: PlotMiningState, touchedPart: BasePart)
	if not state.Active then
		return
	end

	-- (1-3) Only parts we spawned AND registered AND not yet collected can be paid for.
	-- A foreign/fake part (any name or attributes) is simply ignored, never destroyed.
	local info = activeOres[touchedPart]
	if info == nil or info.Collected then
		return
	end
	-- (4) A collector may only consume ores registered to its own plot (any line of it;
	-- the owner is identical across lines). An ore from another plot is ignored and the
	-- foreign ore stays alive for its own collector.
	if info.Plot ~= state.Plot or info.State ~= state then
		return
	end
	-- (5) The plot must still belong to the expected player (owner still present and
	-- authoritative in PlotService).
	local owner = info.Owner
	if owner.Parent == nil then
		return
	end
	if PlotService.GetPlotOwner(state.Plot) ~= owner then
		return
	end
	-- (6-7) The OreId must exist in OreConfig and the value comes from the config ONLY.
	local definition = oreConfigsById[info.OreId]
	if definition == nil then
		warn(("[MiningService] Refusing to reward ore id %q: no OreConfig entry defines it."):format(tostring(info.OreId)))
		return
	end

	-- (8) Mark collected and free the slot BEFORE rewarding. Stone pays exactly
	-- OreConfig.Stone.Value = 1.
	info.Collected = true
	unregisterOre(touchedPart)
	local paid = EconomyService.AddCash(owner, definition.Value)
	touchedPart:Destroy()
	if not paid then
		warn(("[MiningService] Collector could not pay %s for plot %s (ore id %s, value %d); ore was consumed without reward.")
			:format(owner.Name, state.Plot.Name, info.OreId, definition.Value))
	end
end

-- === Dropper ===

-- Server-created physical ore. Deliberately no Cash on spawn: money exists only after the
-- ore is collected by the registered collector flow.
local function spawnOre(state: PlotMiningState, line: MiningLine)
	if state.ActiveOreCount >= MiningConfig.MaxActiveOresPerPlot then
		return
	end
	local definition = dropOreDefinition
	if definition == nil then
		-- Initialize() validated this; defensive guard only.
		return
	end

	local part = Instance.new("Part")
	part.Name = "Ore_" .. definition.Id
	part.Size = definition.Size
	part.Color = definition.Color
	part.Material = definition.Material
	part.Anchored = false
	-- CanCollide so the stone physically rests on / walks along the belt; CanTouch so
	-- the (non-colliding) CollectorTrigger can detect its arrival.
	part.CanCollide = true
	part.CanTouch = true
	-- No spatial queries target ores; skip query replication work.
	part.CanQuery = false
	-- Drop straight from the OreSpawn integration point with a small clearance, never a
	-- hardcoded offset relative to the model.
	part.CFrame = line.SpawnPoint.CFrame + Vector3.new(0, MiningConfig.DropClearance, 0)
	-- Debug/inspection aids ONLY. They are never read back as proof of legitimacy; the
	-- authoritative source is the activeOres registry below.
	part:SetAttribute("OreId", definition.Id)
	part:SetAttribute("OwnerPlot", state.Plot.Name)
	part.Parent = state.OresFolder

	-- Keep physics authority on the server: unanchored parts can otherwise be auto-assigned
	-- to a nearby client, which would let clients simulate (and desync) the belt. pcall
	-- because SetNetworkOwner can fail on transient states; reward logic never depends on
	-- ownership succeeding (it never trusts client-reported positions at all).
	local ownershipOk, ownershipError = pcall(part.SetNetworkOwner, part, nil)
	if not ownershipOk then
		warn(("[MiningService] SetNetworkOwner(nil) failed on a fresh ore in plot %s: %s. Server remains the logic authority, but belt physics may be replicated from a client.")
			:format(state.Plot.Name, tostring(ownershipError)))
	end

	activeOres[part] = {
		OreId = definition.Id,
		Plot = state.Plot,
		State = state,
		Line = line,
		Owner = state.Owner,
		Collected = false,
		SpawnedAt = os.clock(),
	}
	state.ActiveOres[part] = true
	state.ActiveOreCount += 1
end

-- One lightweight loop per line (spawn + task.wait). Loops end via state.Active on
-- release; they are not an ownership poll: the plot lifecycle itself is event-driven.
-- The per-plot ore cap is shared, so with several lines the total production stops at the
-- cap and resumes automatically as slots free up.
local function runDropLoop(state: PlotMiningState, line: MiningLine)
	while state.Active do
		if state.ActiveOreCount < MiningConfig.MaxActiveOresPerPlot then
			local ok, err = pcall(spawnOre, state, line)
			if not ok then
				-- Stop this line only; other lines and plots keep running.
				local connection = line.CollectorConnection
				if connection ~= nil then
					connection:Disconnect()
					line.CollectorConnection = nil
				end
				warn(("[MiningService] Stopping one production line on plot %s after a spawn error: %s")
					:format(state.Plot.Name, tostring(err)))
				return
			end
		end
		task.wait(MiningConfig.DropInterval)
	end
end

-- === Placement ===

-- Target pivot for a line, computed from the plot itself (never from the template's
-- original world position). The template's pivot sits on the plot's ground top surface,
-- shifted by the line's configured LOCAL offset, rotation left identity so every plot
-- shows the machinery facing the same way with its local +Z flow pointing away from the
-- claim pad.
local function computeSetupPivotCFrame(plot: Model, pivotOffset: Vector3): CFrame
	local ground = plot:FindFirstChild(GROUND_PART_NAME)
	local surfaceCFrame
	if ground ~= nil and ground:IsA("BasePart") then
		surfaceCFrame = ground.CFrame * CFrame.new(0, ground.Size.Y / 2, 0)
	else
		-- PlotService currently always generates Ground; if that changes, the model pivot
		-- is still a plot-relative anchor and placement remains consistent for every plot.
		surfaceCFrame = plot:GetPivot()
	end
	return surfaceCFrame * CFrame.new(pivotOffset)
end

-- The ore flow runs along the template's local +Z. Derive a horizontal direction from the
-- ConveyorSurface's own CFrame (falling back to the model pivot), so the setup can be
-- rotated in the future without code changes. Never assume world (0,0,1).
local function resolveBeltDirection(setup: Model, belt: BasePart): Vector3
	local candidates = { belt.CFrame.LookVector, setup:GetPivot().LookVector }
	for _, candidate in candidates do
		local horizontal = Vector3.new(candidate.X, 0, candidate.Z)
		if horizontal.Magnitude >= 0.5 then
			return horizontal / horizontal.Magnitude
		end
	end
	return Vector3.new(0, 0, 1)
end

-- Clones the template for line `lineIndex`, validates the integration points, places the
-- whole model with one PivotTo(), connects its collector and starts its drop loop.
-- Returns the line, or nil after a loud warning (never a substitute model, never money).
local function installLine(state: PlotMiningState, lineIndex: number): MiningLine?
	local templateModel = template
	local pivotOffset = MiningConfig.LinePivotOffsets[lineIndex]
	if templateModel == nil or pivotOffset == nil or not state.Active then
		return nil
	end

	-- Clone the Studio-authored model as a whole; nothing here rebuilds its ~212 parts.
	local setup = templateModel:Clone()
	setup.Name = MINING_SETUP_NAME .. (if lineIndex > 1 then tostring(lineIndex) else "")

	local clonePath = ("Workspace.%s.%s"):format(state.Plot.Name, setup.Name)
	local spawnPoint: BasePart? = nil
	local belt: BasePart? = nil
	local collector: BasePart? = nil
	for _, integrationPoint in INTEGRATION_POINTS do
		local part = findIntegrationPoint(setup, integrationPoint.Container, integrationPoint.Point)
		if part == nil then
			warn(("[MiningService] Not installing mining line %d on plot %s: the clone of %s is missing %s. Fix the asset; no substitute setup is generated and no ore will be produced.")
				:format(lineIndex, state.Plot.Name, TEMPLATE_PATH, describeIntegrationPoint(clonePath, integrationPoint.Container, integrationPoint.Point)))
			setup:Destroy()
			return nil
		end
		if integrationPoint.Point == "OreSpawn" then
			spawnPoint = part
		elseif integrationPoint.Point == "ConveyorSurface" then
			belt = part
		else
			collector = part
		end
	end

	-- All three points were validated above; this only narrows optionality for the reader.
	if spawnPoint == nil or belt == nil or collector == nil then
		setup:Destroy()
		return nil
	end

	-- Move the ENTIRE set once with its pivot. Dropper, Conveyor and Collector are only
	-- referenced (never repositioned); their relative geometry belongs to the asset.
	setup:PivotTo(computeSetupPivotCFrame(state.Plot, pivotOffset))

	local direction = resolveBeltDirection(setup, belt)
	local beltOrigin = spawnPoint.Position
	-- Distance from the drop point to the collector, measured along the belt's derived
	-- forward axis. If the collector is not downstream, the asset is misconfigured (e.g.
	-- wrong pivot/orientation) and this line is refused loudly.
	local collectorAhead = (collector.Position - beltOrigin):Dot(direction)
	if collectorAhead <= 0.5 then
		warn(("[MiningService] Not installing mining line %d on plot %s: CollectorTrigger is not downstream along ConveyorSurface's local +Z (measured %.2f studs). Check the template's pivot/orientation.")
			:format(lineIndex, state.Plot.Name, collectorAhead))
		setup:Destroy()
		return nil
	end

	setup.Parent = state.Plot

	local line: MiningLine = {
		Setup = setup,
		SpawnPoint = spawnPoint,
		Collector = collector,
		CollectorConnection = nil,
		BeltDirection = direction,
		BeltVelocity = direction * MiningConfig.BeltSpeed,
		BeltOrigin = beltOrigin,
		BeltLimit = collectorAhead + MiningConfig.BeltOvershoot,
	}
	table.insert(state.Lines, line)

	line.CollectorConnection = collector.Touched:Connect(function(touchedPart: BasePart)
		handleCollectorTouched(state, touchedPart)
	end)

	task.spawn(runDropLoop, state, line)
	return line
end

-- Full teardown of one plot's mining: idempotent, only affects this plot.
local function teardownPlotState(state: PlotMiningState)
	setupsByPlot[state.Plot] = nil
	state.Active = false

	for _, line in state.Lines do
		local connection = line.CollectorConnection
		if connection ~= nil then
			connection:Disconnect()
			line.CollectorConnection = nil
		end
	end

	-- Drop every still-active ore of this plot from the shared registry first (so a late
	-- Touched can never pay out after release), then destroy the instances via the folder.
	for part in state.ActiveOres do
		activeOres[part] = nil
	end
	state.ActiveOres = {}
	state.OresFolder:Destroy()
	for _, line in state.Lines do
		line.Setup:Destroy()
	end
	state.Lines = {}

	activePlotCount -= 1
	updateConveyorLoop()
end

-- === Plot lifecycle ===

local function onPlotClaimed(player: Player, plot: Model)
	if not enabled or setupsByPlot[plot] ~= nil then
		-- A second claim for an already-mining plot must never double-install.
		return
	end

	local oresFolder = Instance.new("Folder")
	oresFolder.Name = ORES_FOLDER_NAME
	oresFolder.Parent = plot

	local state: PlotMiningState = {
		Plot = plot,
		Owner = player,
		Lines = {},
		OresFolder = oresFolder,
		ActiveOres = {},
		ActiveOreCount = 0,
		Active = true,
	}
	setupsByPlot[plot] = state
	activePlotCount += 1
	updateConveyorLoop()

	-- Starter line at index 1; failure means this plot cannot mine at all.
	local line = installLine(state, 1)
	if line == nil then
		teardownPlotState(state)
	end
end

local function onPlotReleased(_player: Player, plot: Model)
	local state = setupsByPlot[plot]
	if state == nil then
		return
	end
	teardownPlotState(state)
end

-- === Purchasable extra lines (used by PurchaseService; server-side only) ===

-- Extra lines available for purchase beyond the free starter line. Zero when mining is
-- disabled or the configuration offers only the starter offset.
function MiningService.GetPurchasableLineCount(): number
	if not enabled then
		return 0
	end
	return math.max(0, #MiningConfig.LinePivotOffsets - 1)
end

-- Installs the next production line on a plot. Returns true only when the line was
-- actually installed. `player` must currently own `plot`; the check makes this safe to
-- call even if a caller's validation is ever weakened.
function MiningService.AddExtraDropperLine(player: Player, plot: Model): boolean
	if not enabled then
		return false
	end
	local state = setupsByPlot[plot]
	if state == nil or not state.Active then
		return false
	end
	if PlotService.GetPlotOwner(plot) ~= player then
		return false
	end
	local lineIndex = #state.Lines + 1
	if lineIndex <= 1 or lineIndex > #MiningConfig.LinePivotOffsets then
		-- Purchases start at line 2 and stop at the configured capacity.
		return false
	end
	return installLine(state, lineIndex) ~= nil
end

-- === Initialization / asset + config validation ===

function MiningService.Initialize()
	if initialized then
		return
	end
	-- Set before validating: a failed Initialize must not be retried in a loop by callers;
	-- the service stays disabled (enabled == false) and produces nothing.
	initialized = true

	local problems: { string } = {}

	-- --- Configuration validation (repo-owned configs are allowed to hard-error) ---
	if not isFiniteNumber(MiningConfig.DropInterval) or MiningConfig.DropInterval < 0.05 then
		table.insert(problems, "MiningConfig.DropInterval must be a finite number of at least 0.05 seconds")
	end
	if not isFiniteNumber(MiningConfig.OreLifetime) or MiningConfig.OreLifetime <= 0 then
		table.insert(problems, "MiningConfig.OreLifetime must be a finite number of seconds > 0")
	end
	if not isWholeNumber(MiningConfig.MaxActiveOresPerPlot) or MiningConfig.MaxActiveOresPerPlot < 1 then
		table.insert(problems, "MiningConfig.MaxActiveOresPerPlot must be a whole number >= 1")
	end
	if not isFiniteNumber(MiningConfig.BeltSpeed) or MiningConfig.BeltSpeed <= 0 then
		table.insert(problems, "MiningConfig.BeltSpeed must be a finite number of studs/second > 0")
	end
	if not isFiniteNumber(MiningConfig.BeltOvershoot) or MiningConfig.BeltOvershoot < 0 then
		table.insert(problems, "MiningConfig.BeltOvershoot must be a finite number of studs >= 0")
	end
	if not isFiniteNumber(MiningConfig.DropClearance) or MiningConfig.DropClearance < 0 then
		table.insert(problems, "MiningConfig.DropClearance must be a finite number of studs >= 0")
	end
	if typeof(MiningConfig.LinePivotOffsets) ~= "table" or #MiningConfig.LinePivotOffsets < 1 then
		table.insert(problems, "MiningConfig.LinePivotOffsets must be a non-empty array of Vector3 offsets")
	else
		for index, offset in MiningConfig.LinePivotOffsets do
			if typeof(offset) ~= "Vector3" then
				table.insert(problems, ("MiningConfig.LinePivotOffsets[%d] must be a Vector3"):format(index))
			end
		end
	end

	local oreCount = 0
	for key, definition in OreConfig do
		oreCount += 1
		if typeof(definition) ~= "table" then
			table.insert(problems, ("OreConfig.%s must be a table"):format(tostring(key)))
		elseif definition.Id ~= key then
			table.insert(problems, ("OreConfig entry %q must have Id equal to its key"):format(tostring(key)))
		end
		if typeof(definition) == "table" and definition.Id ~= nil then
			if not isWholeNumber(definition.Value) or definition.Value < 1 then
				table.insert(problems, ("OreConfig.%s.Value must be a whole number >= 1 (reward in Cash)"):format(tostring(definition.Id)))
			end
			if typeof(definition.Size) ~= "Vector3"
				or definition.Size.X <= 0
				or definition.Size.Y <= 0
				or definition.Size.Z <= 0
			then
				table.insert(problems, ("OreConfig.%s.Size must be a Vector3 with all components > 0"):format(tostring(definition.Id)))
			end
			if oreConfigsById[definition.Id] ~= nil then
				table.insert(problems, ("OreConfig defines duplicate ore id %q"):format(tostring(definition.Id)))
			end
			oreConfigsById[definition.Id] = definition
		end
	end
	if oreCount == 0 then
		table.insert(problems, "OreConfig must define at least one ore")
	end
	local dropperOreId = MiningConfig.DropperOreId
	if type(dropperOreId) ~= "string" or oreConfigsById[dropperOreId] == nil then
		table.insert(problems, ("MiningConfig.DropperOreId (%s) must exist as an entry in OreConfig"):format(tostring(dropperOreId)))
	else
		dropOreDefinition = oreConfigsById[dropperOreId]
	end

	-- --- Asset validation: the StarterMiningSetup template lives in the Roblox place,
	-- NOT in Git. A missing/broken asset must be reported with the expected path and must
	-- disable mining loudly (no fallback model is auto-generated, no money is produced).
	local assetsFolder = ServerStorage:FindFirstChild("Assets")
	local miningFolder: Instance? = nil
	if assetsFolder ~= nil then
		miningFolder = assetsFolder:FindFirstChild("Mining")
	end
	local templateCandidate: Instance? = nil
	if miningFolder ~= nil then
		templateCandidate = miningFolder:FindFirstChild("StarterMiningSetup")
	end
	if templateCandidate == nil then
		table.insert(problems, (
			"StarterMiningSetup not found. Expected the Studio-authored asset at %s. "
			.. "This asset lives inside the Roblox place (it is intentionally not in Git); "
			.. "place it under ServerStorage with that exact hierarchy."
		):format(TEMPLATE_PATH))
	elseif not templateCandidate:IsA("Model") then
		table.insert(problems, ("%s must be a Model (currently a %s)"):format(TEMPLATE_PATH, templateCandidate.ClassName))
	else
		local templateProblemsBefore = #problems
		for _, integrationPoint in INTEGRATION_POINTS do
			if findIntegrationPoint(templateCandidate, integrationPoint.Container, integrationPoint.Point) == nil then
				table.insert(problems, ("Missing integration point: %s")
					:format(describeIntegrationPoint(TEMPLATE_PATH, integrationPoint.Container, integrationPoint.Point)))
			end
		end
		if #problems == templateProblemsBefore then
			template = templateCandidate :: Model
		end
	end

	if #problems > 0 then
		-- Loud, immediate and fatal for this thread only: PlotService and EconomyService are
		-- already initialized by Main before this call, and no mining listener is connected,
		-- so nothing can produce ores or money. Fix the asset/config and restart.
		error(("[MiningService] Mining is disabled because validation failed:\n - %s")
			:format(table.concat(problems, "\n - ")), 2)
	end

	enabled = true

	-- Event-driven integration (no polling, no remotes). Note: Main initializes services in
	-- one synchronous pass before any player can reach a claim platform, so connecting after
	-- PlotService.Initialize() cannot miss a claim; there are no plots yet to backfill.
	-- The subscriptions intentionally live for the whole server session (this service is never
	-- unloaded), so their disconnect functions are discarded on purpose.
	PlotService.OnPlotClaimed(onPlotClaimed)
	PlotService.OnPlotReleased(onPlotReleased)
end

return MiningService
