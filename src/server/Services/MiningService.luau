--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")
local oreConfigModule = configFolder:WaitForChild("OreConfig") :: ModuleScript
local miningConfigModule = configFolder:WaitForChild("MiningConfig") :: ModuleScript
local OreConfig = require(oreConfigModule)
local MiningConfig = require(miningConfigModule)

local servicesFolder = script.Parent
assert(servicesFolder ~= nil, "[MiningService] MiningService.luau must be parented under Services")
local plotServiceModule = servicesFolder:WaitForChild("PlotService") :: ModuleScript
local economyServiceModule = servicesFolder:WaitForChild("EconomyService") :: ModuleScript
local PlotService = require(plotServiceModule)
local EconomyService = require(economyServiceModule)

type OreStatus = "Active" | "Collected" | "Removed"

type OreRecord = {
	OreTypeId: string,
	Plot: Model,
	Owner: Player,
	Status: OreStatus,
	ConveyorAttempted: boolean,
	LifetimeThread: thread?,
	DestroyingConnection: RBXScriptConnection?,
	AncestryConnection: RBXScriptConnection?,
}

type PlotMiningState = {
	Plot: Model,
	Ground: BasePart,
	OreFolder: Folder,
	ConveyorDirection: Vector3,
	Owner: Player?,
	IsRunning: boolean,
	ProductionGeneration: number,
	ActiveOres: { [BasePart]: OreRecord },
	ActiveOreCount: number,
}

local plotMiningStates: { [Model]: PlotMiningState } = {}
-- This server-only table is the authority for whether a physical part is a rewardable ore.
local activeOreRegistry: { [BasePart]: OreRecord } = {}
local initialized = false
local warnedNetworkOwnershipFailure = false

local MiningService = {}

local function isFinitePositiveNumber(value: any): boolean
	return type(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value > 0
end

local function isPositiveInteger(value: any): boolean
	return isFinitePositiveNumber(value) and value % 1 == 0
end

local function validateConfig()
	if not isFinitePositiveNumber(MiningConfig.DropInterval) then
		error("[MiningService] MiningConfig.DropInterval must be a finite positive number")
	end
	if not isFinitePositiveNumber(MiningConfig.OreLifetime) then
		error("[MiningService] MiningConfig.OreLifetime must be a finite positive number")
	end
	if not isPositiveInteger(MiningConfig.MaxActiveOresPerPlot) then
		error("[MiningService] MiningConfig.MaxActiveOresPerPlot must be a positive integer")
	end
	if not isFinitePositiveNumber(MiningConfig.Conveyor.Speed)
		or not isFinitePositiveNumber(MiningConfig.Conveyor.MaxForce)
	then
		error("[MiningService] Conveyor speed and maximum force must be finite positive numbers")
	end

	local initialOre = OreConfig[MiningConfig.InitialOreTypeId]
	if initialOre == nil or initialOre.Id ~= MiningConfig.InitialOreTypeId then
		error("[MiningService] MiningConfig.InitialOreTypeId must name an ore in OreConfig")
	end
	if not isPositiveInteger(initialOre.Value) then
		error("[MiningService] The initial ore must have a positive integer Value in OreConfig")
	end
	if not isFinitePositiveNumber(initialOre.Size.X)
		or not isFinitePositiveNumber(initialOre.Size.Y)
		or not isFinitePositiveNumber(initialOre.Size.Z)
	then
		error("[MiningService] The initial ore must have finite positive dimensions in OreConfig")
	end
end

local function cframeOnPlot(
	ground: BasePart,
	offsetX: number,
	heightAboveGround: number,
	offsetZ: number
): CFrame
	local localHeight = ground.Size.Y / 2 + heightAboveGround
	return ground.CFrame * CFrame.new(offsetX, localHeight, offsetZ)
end

local function createStaticPart(
	parent: Instance,
	name: string,
	size: Vector3,
	color: Color3,
	material: Enum.Material,
	cframe: CFrame,
	canCollide: boolean,
	canTouch: boolean,
	transparency: number?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = canCollide
	part.CanTouch = canTouch
	part.CanQuery = canCollide or canTouch
	part.Color = color
	part.Material = material
	part.Size = size
	part.CFrame = cframe
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Transparency = transparency or 0
	part.CastShadow = part.Transparency < 1
	part.Parent = parent
	return part
end

local function isCurrentProduction(state: PlotMiningState, generation: number): boolean
	local owner = state.Owner
	return state.IsRunning
		and state.ProductionGeneration == generation
		and plotMiningStates[state.Plot] == state
		and owner ~= nil
		and owner.Parent == Players
		and PlotService.GetPlotOwner(state.Plot) == owner
end

local function isRegisteredActiveOre(
	state: PlotMiningState,
	ore: BasePart,
	record: OreRecord
): boolean
	local owner = state.Owner
	if owner == nil then
		return false
	end

	return record.Status == "Active"
		and activeOreRegistry[ore] == record
		and state.ActiveOres[ore] == record
		and record.Plot == state.Plot
		and record.Owner == owner
		and owner.Parent == Players
		and state.IsRunning
		and PlotService.GetPlotOwner(state.Plot) == owner
		and ore.Parent == state.OreFolder
end

local function unregisterOre(ore: BasePart, record: OreRecord, finalStatus: OreStatus): boolean
	if record.Status ~= "Active" or activeOreRegistry[ore] ~= record then
		return false
	end

	record.Status = finalStatus
	activeOreRegistry[ore] = nil

	local state = plotMiningStates[record.Plot]
	if state ~= nil and state.ActiveOres[ore] == record then
		state.ActiveOres[ore] = nil
		state.ActiveOreCount -= 1
		if state.ActiveOreCount < 0 then
			-- Keep a bookkeeping bug from permitting unbounded production.
			state.ActiveOreCount = 0
			warn("[MiningService] Active ore count underflowed for " .. state.Plot.Name)
		end
	end

	local lifetimeThread = record.LifetimeThread
	record.LifetimeThread = nil
	if lifetimeThread ~= nil then
		pcall(task.cancel, lifetimeThread)
	end

	local destroyingConnection = record.DestroyingConnection
	record.DestroyingConnection = nil
	if destroyingConnection ~= nil then
		destroyingConnection:Disconnect()
	end

	local ancestryConnection = record.AncestryConnection
	record.AncestryConnection = nil
	if ancestryConnection ~= nil then
		ancestryConnection:Disconnect()
	end

	return true
end

local function destroyActiveOre(ore: BasePart, record: OreRecord)
	if unregisterOre(ore, record, "Removed") then
		ore:Destroy()
	end
end

local function onConveyorTouched(state: PlotMiningState, touchedPart: BasePart)
	local record = activeOreRegistry[touchedPart]
	if record == nil or record.Plot ~= state.Plot or record.Status ~= "Active" then
		return
	end
	if not isRegisteredActiveOre(state, touchedPart, record) then
		destroyActiveOre(touchedPart, record)
		return
	end
	if record.ConveyorAttempted then
		return
	end
	-- Avoid repeatedly rebuilding a failed constraint if Touched fires again for this ore.
	record.ConveyorAttempted = true

	-- A server-created line constraint moves only a registered ore that touches this belt;
	-- Roblox physics applies it between events without a RunService frame loop.
	local attachment = Instance.new("Attachment")
	attachment.Name = "ConveyorAttachment"

	local movement = Instance.new("LinearVelocity")
	movement.Name = "ConveyorMovement"

	local succeeded, errorMessage = pcall(function()
		attachment.Parent = touchedPart
		movement.Attachment0 = attachment
		movement.RelativeTo = Enum.ActuatorRelativeTo.World
		movement.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
		movement.LineDirection = state.ConveyorDirection
		movement.LineVelocity = MiningConfig.Conveyor.Speed
		movement.ForceLimitsEnabled = true
		movement.MaxForce = MiningConfig.Conveyor.MaxForce
		movement.Parent = touchedPart
	end)

	if not succeeded then
		movement:Destroy()
		attachment:Destroy()
		warn(
			("[MiningService] Could not attach conveyor motion to an ore on %s: %s"):format(
				state.Plot.Name,
				tostring(errorMessage)
			)
		)
		return
	end

	-- Line mode controls only travel along the belt, leaving gravity and vertical collisions intact.
end

local function onCollectorTouched(state: PlotMiningState, touchedPart: BasePart)
	local record = activeOreRegistry[touchedPart]
	if record == nil or record.Plot ~= state.Plot or record.Status ~= "Active" then
		return
	end
	if not isRegisteredActiveOre(state, touchedPart, record) then
		destroyActiveOre(touchedPart, record)
		return
	end

	local oreDefinition = OreConfig[record.OreTypeId]
	if oreDefinition == nil
		or oreDefinition.Id ~= record.OreTypeId
		or not isPositiveInteger(oreDefinition.Value)
	then
		warn(
			("[MiningService] Rejecting ore with unknown or invalid server configuration on %s"):format(
				state.Plot.Name
			)
		)
		destroyActiveOre(touchedPart, record)
		return
	end

	-- The ore is server-owned from creation through collection. Reject it if that invariant ever changes.
	local ownershipSucceeded, networkOwner = pcall(function()
		return touchedPart:GetNetworkOwner()
	end)
	if not ownershipSucceeded or networkOwner ~= nil then
		destroyActiveOre(touchedPart, record)
		return
	end

	-- Unregister before granting Cash so duplicate Touched callbacks cannot pay this ore twice.
	if not unregisterOre(touchedPart, record, "Collected") then
		return
	end

	local rewardCallSucceeded, rewardAdded = pcall(function()
		return EconomyService.AddCash(record.Owner, oreDefinition.Value)
	end)
	if not rewardCallSucceeded then
		warn(
			("[MiningService] EconomyService.AddCash failed for %s: %s"):format(
				record.Owner.Name,
				tostring(rewardAdded)
			)
		)
	elseif not rewardAdded and record.Owner.Parent == Players then
		warn("[MiningService] EconomyService rejected a validated ore reward for " .. record.Owner.Name)
	end

	if touchedPart.Parent ~= nil then
		touchedPart:Destroy()
	end
end

local function createPlotStructure(plot: Model): PlotMiningState
	local existingState = plotMiningStates[plot]
	if existingState ~= nil then
		return existingState
	end

	local groundInstance = plot:FindFirstChild("Ground")
	if groundInstance == nil or not groundInstance:IsA("BasePart") then
		error("[MiningService] " .. plot.Name .. " must contain a BasePart named Ground")
	end
	local ground = groundInstance :: BasePart

	local oldMiningModel = plot:FindFirstChild("Mining")
	if oldMiningModel ~= nil then
		oldMiningModel:Destroy()
	end

	local miningModel = Instance.new("Model")
	miningModel.Name = "Mining"

	local dropperModel = Instance.new("Model")
	dropperModel.Name = "Dropper"
	dropperModel.Parent = miningModel

	local dropperConfig = MiningConfig.Dropper
	createStaticPart(
		dropperModel,
		"Body",
		dropperConfig.BodySize,
		dropperConfig.BodyColor,
		dropperConfig.BodyMaterial,
		cframeOnPlot(
			ground,
			dropperConfig.BodyOffsetX,
			dropperConfig.BodyCenterHeightAboveGround,
			dropperConfig.BodyOffsetZ
		),
		true,
		false
	)
	local outletOffsetX = dropperConfig.BodyOffsetX
		+ dropperConfig.BodySize.X / 2
		+ dropperConfig.OutletSize.X / 2
	createStaticPart(
		dropperModel,
		"Outlet",
		dropperConfig.OutletSize,
		dropperConfig.OutletColor,
		dropperConfig.OutletMaterial,
		cframeOnPlot(
			ground,
			outletOffsetX,
			dropperConfig.OutletCenterHeightAboveGround,
			dropperConfig.BodyOffsetZ
		),
		true,
		false
	)

	local conveyorModel = Instance.new("Model")
	conveyorModel.Name = "Conveyor"
	conveyorModel.Parent = miningModel

	local conveyorConfig = MiningConfig.Conveyor
	local conveyorCFrame = cframeOnPlot(
		ground,
		conveyorConfig.CenterOffsetX,
		conveyorConfig.CenterHeightAboveGround,
		conveyorConfig.CenterOffsetZ
	)
	local belt = createStaticPart(
		conveyorModel,
		"Belt",
		Vector3.new(conveyorConfig.Length, conveyorConfig.Thickness, conveyorConfig.Width),
		conveyorConfig.Color,
		conveyorConfig.Material,
		conveyorCFrame,
		true,
		true
	)

	local arrowHeight = conveyorConfig.CenterHeightAboveGround
		+ conveyorConfig.Thickness / 2
		+ conveyorConfig.ArrowHeightAboveBelt
	createStaticPart(
		conveyorModel,
		"DirectionShaft",
		conveyorConfig.ArrowShaftSize,
		conveyorConfig.ArrowColor,
		conveyorConfig.ArrowMaterial,
		cframeOnPlot(
			ground,
			conveyorConfig.CenterOffsetX,
			arrowHeight,
			conveyorConfig.CenterOffsetZ
		),
		false,
		false
	)

	local wingAngle = math.rad(conveyorConfig.ArrowWingAngleDegrees)
	local wingCenterX = conveyorConfig.ArrowTipX
		- conveyorConfig.ArrowWingSize.X / 2 * math.cos(wingAngle)
	local wingCenterZ = conveyorConfig.ArrowHeadSpread / 2
	createStaticPart(
		conveyorModel,
		"DirectionArrowUpper",
		conveyorConfig.ArrowWingSize,
		conveyorConfig.ArrowColor,
		conveyorConfig.ArrowMaterial,
		cframeOnPlot(
			ground,
			conveyorConfig.CenterOffsetX + wingCenterX,
			arrowHeight,
			conveyorConfig.CenterOffsetZ + wingCenterZ
		) * CFrame.Angles(0, wingAngle, 0),
		false,
		false
	)
	createStaticPart(
		conveyorModel,
		"DirectionArrowLower",
		conveyorConfig.ArrowWingSize,
		conveyorConfig.ArrowColor,
		conveyorConfig.ArrowMaterial,
		cframeOnPlot(
			ground,
			conveyorConfig.CenterOffsetX + wingCenterX,
			arrowHeight,
			conveyorConfig.CenterOffsetZ - wingCenterZ
		) * CFrame.Angles(0, -wingAngle, 0),
		false,
		false
	)

	local collectorModel = Instance.new("Model")
	collectorModel.Name = "Collector"
	collectorModel.Parent = miningModel

	local collectorConfig = MiningConfig.Collector
	createStaticPart(
		collectorModel,
		"Base",
		collectorConfig.BaseSize,
		collectorConfig.Color,
		collectorConfig.Material,
		cframeOnPlot(
			ground,
			collectorConfig.OffsetX,
			collectorConfig.BaseCenterHeightAboveGround,
			collectorConfig.OffsetZ
		),
		true,
		false
	)
	local sideWallSize = Vector3.new(
		collectorConfig.BaseSize.X,
		collectorConfig.WallHeight,
		collectorConfig.WallThickness
	)
	local sideWallOffsetZ = collectorConfig.BaseSize.Z / 2 - collectorConfig.WallThickness / 2
	for _, side in { -1, 1 } do
		createStaticPart(
			collectorModel,
			if side < 0 then "SideWallA" else "SideWallB",
			sideWallSize,
			collectorConfig.Color,
			collectorConfig.Material,
			cframeOnPlot(
				ground,
				collectorConfig.OffsetX,
				collectorConfig.WallCenterHeightAboveGround,
				collectorConfig.OffsetZ + side * sideWallOffsetZ
			),
			true,
			false
		)
	end
	local backWallX = collectorConfig.OffsetX
		+ collectorConfig.BaseSize.X / 2
		- collectorConfig.WallThickness / 2
	createStaticPart(
		collectorModel,
		"BackWall",
		Vector3.new(collectorConfig.WallThickness, collectorConfig.WallHeight, collectorConfig.BaseSize.Z),
		collectorConfig.Color,
		collectorConfig.Material,
		cframeOnPlot(
			ground,
			backWallX,
			collectorConfig.WallCenterHeightAboveGround,
			collectorConfig.OffsetZ
		),
		true,
		false
	)
	local collectorTrigger = createStaticPart(
		collectorModel,
		"Intake",
		collectorConfig.IntakeSize,
		collectorConfig.Color,
		collectorConfig.Material,
		cframeOnPlot(
			ground,
			collectorConfig.OffsetX,
			collectorConfig.IntakeCenterHeightAboveGround,
			collectorConfig.OffsetZ
		),
		false,
		true,
		collectorConfig.IntakeTransparency
	)
	collectorTrigger.CastShadow = false

	local oreFolder = Instance.new("Folder")
	oreFolder.Name = "Ores"
	oreFolder.Parent = miningModel

	local state: PlotMiningState = {
		Plot = plot,
		Ground = ground,
		OreFolder = oreFolder,
		ConveyorDirection = belt.CFrame.RightVector.Unit,
		Owner = nil,
		IsRunning = false,
		ProductionGeneration = 0,
		ActiveOres = {},
		ActiveOreCount = 0,
	}
	plotMiningStates[plot] = state

	belt.Touched:Connect(function(touchedPart: BasePart)
		onConveyorTouched(state, touchedPart)
	end)
	collectorTrigger.Touched:Connect(function(touchedPart: BasePart)
		onCollectorTouched(state, touchedPart)
	end)

	miningModel.Parent = plot
	return state
end

local function retireOreAfterLifetime(ore: BasePart, record: OreRecord)
	if activeOreRegistry[ore] == record and record.Status == "Active" then
		destroyActiveOre(ore, record)
	end
end

local function spawnOre(state: PlotMiningState, oreTypeId: string, generation: number): boolean
	if not isCurrentProduction(state, generation)
		or state.ActiveOreCount >= MiningConfig.MaxActiveOresPerPlot
	then
		return false
	end

	local oreDefinition = OreConfig[oreTypeId]
	if oreDefinition == nil or oreDefinition.Id ~= oreTypeId or not isPositiveInteger(oreDefinition.Value) then
		warn("[MiningService] Refusing to spawn an ore without valid server configuration: " .. oreTypeId)
		return false
	end

	local owner = state.Owner
	if owner == nil then
		return false
	end

	local conveyorConfig = MiningConfig.Conveyor
	local beltTopHeightAboveGround = conveyorConfig.CenterHeightAboveGround + conveyorConfig.Thickness / 2
	local spawnHeightAboveGround = beltTopHeightAboveGround + MiningConfig.OreSpawnHeightAboveBelt
	local ore = Instance.new("Part")
	ore.Name = oreDefinition.Id
	ore.Shape = Enum.PartType.Ball
	ore.Anchored = false
	ore.CanCollide = true
	ore.CanTouch = true
	ore.CanQuery = true
	ore.Color = oreDefinition.Color
	ore.Material = oreDefinition.Material
	ore.Size = oreDefinition.Size
	ore.CFrame = cframeOnPlot(
		state.Ground,
		MiningConfig.OreSpawnOffsetX,
		spawnHeightAboveGround,
		MiningConfig.OreSpawnOffsetZ
	)
	ore.TopSurface = Enum.SurfaceType.Smooth
	ore.BottomSurface = Enum.SurfaceType.Smooth
	ore.Parent = state.OreFolder

	-- Manual server ownership prevents clients from steering or locally simulating rewardable ores.
	local ownershipSucceeded, ownershipError = pcall(function()
		ore:SetNetworkOwner(nil)
	end)
	if not ownershipSucceeded then
		if not warnedNetworkOwnershipFailure then
			warnedNetworkOwnershipFailure = true
			warn(
				("[MiningService] Could not assign server network ownership for an ore on %s: %s"):format(
					state.Plot.Name,
					tostring(ownershipError)
				)
			)
		end
		ore:Destroy()
		return false
	end

	local record: OreRecord = {
		OreTypeId = oreTypeId,
		Plot = state.Plot,
		Owner = owner,
		Status = "Active",
		ConveyorAttempted = false,
		LifetimeThread = nil,
		DestroyingConnection = nil,
		AncestryConnection = nil,
	}
	activeOreRegistry[ore] = record
	state.ActiveOres[ore] = record
	state.ActiveOreCount += 1

	record.DestroyingConnection = ore.Destroying:Connect(function()
		unregisterOre(ore, record, "Removed")
	end)
	record.AncestryConnection = ore.AncestryChanged:Connect(function()
		if ore.Parent ~= state.OreFolder then
			destroyActiveOre(ore, record)
		end
	end)
	record.LifetimeThread = task.delay(MiningConfig.OreLifetime, function()
		record.LifetimeThread = nil
		retireOreAfterLifetime(ore, record)
	end)

	return true
end

local function clearPendingOres(state: PlotMiningState)
	local oresToClear: { BasePart } = {}
	for ore in state.ActiveOres do
		table.insert(oresToClear, ore)
	end
	for _, ore in oresToClear do
		local record = state.ActiveOres[ore]
		if record ~= nil then
			destroyActiveOre(ore, record)
		end
	end
end

local function stopPlotState(state: PlotMiningState, previousOwner: Player)
	if state.Owner ~= previousOwner then
		return
	end

	-- Invalidate sleepers before destroying pending ores or accepting a new owner.
	state.IsRunning = false
	state.ProductionGeneration += 1
	state.Owner = nil
	clearPendingOres(state)
end

local function startPlotProduction(plot: Model, owner: Player)
	if PlotService.GetPlotOwner(plot) ~= owner or owner.Parent ~= Players then
		return
	end

	local state = createPlotStructure(plot)
	if state.Owner == owner and state.IsRunning then
		return
	end
	if state.Owner ~= nil then
		local previousOwner = state.Owner
		stopPlotState(state, previousOwner)
	end

	state.Owner = owner
	state.IsRunning = true
	state.ProductionGeneration += 1
	local generation = state.ProductionGeneration

	-- One sleeping worker per occupied plot; no global per-frame production loop is used.
	task.spawn(function()
		while isCurrentProduction(state, generation) do
			task.wait(MiningConfig.DropInterval)
			if not isCurrentProduction(state, generation) then
				break
			end

			if state.ActiveOreCount < MiningConfig.MaxActiveOresPerPlot then
				spawnOre(state, MiningConfig.InitialOreTypeId, generation)
			end
		end
	end)
end

local function releasePlotProduction(plot: Model, previousOwner: Player)
	local state = plotMiningStates[plot]
	if state == nil then
		return
	end

	stopPlotState(state, previousOwner)
end

function MiningService.Initialize()
	if initialized then
		return
	end

	validateConfig()

	local plots = PlotService.GetPlots()
	if #plots == 0 then
		error("[MiningService] PlotService.Initialize() must run before MiningService.Initialize()")
	end

	-- Subscribe before enumerating. PlotService replays owners if registration is late, and
	-- createPlotStructure is idempotent, so claims/releases cannot be missed during startup.
	PlotService.RegisterLifecycleListener({
		OnPlotClaimed = startPlotProduction,
		OnPlotReleased = releasePlotProduction,
	})

	for _, plot in plots do
		createPlotStructure(plot)
		local owner = PlotService.GetPlotOwner(plot)
		if owner ~= nil then
			startPlotProduction(plot, owner)
		end
	end

	initialized = true
end

return MiningService
