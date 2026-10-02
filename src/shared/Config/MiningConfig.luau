--!strict

local Dropper = table.freeze({
	BodySize = Vector3.new(6, 6, 6),
	BodyOffsetX = -31,
	BodyOffsetZ = 0,
	BodyCenterHeightAboveGround = 5,
	BodyColor = Color3.fromRGB(61, 132, 204),
	BodyMaterial = Enum.Material.Metal,

	OutletSize = Vector3.new(2, 2, 2),
	OutletCenterHeightAboveGround = 2,
	OutletColor = Color3.fromRGB(43, 91, 145),
	OutletMaterial = Enum.Material.Metal,
})

local Conveyor = table.freeze({
	Length = 56,
	Width = 10,
	Thickness = 1,
	CenterOffsetX = 0,
	CenterOffsetZ = 0,
	CenterHeightAboveGround = 0.5,
	Color = Color3.fromRGB(61, 66, 73),
	Material = Enum.Material.Metal,

	Speed = 12,
	MaxForce = 5000,

	ArrowColor = Color3.fromRGB(255, 196, 48),
	ArrowMaterial = Enum.Material.Neon,
	ArrowHeightAboveBelt = 0.08,
	ArrowShaftSize = Vector3.new(18, 0.18, 0.6),
	ArrowWingSize = Vector3.new(4, 0.18, 0.6),
	ArrowTipX = 23.5,
	ArrowHeadSpread = 2,
	ArrowWingAngleDegrees = 30,
})

local Collector = table.freeze({
	OffsetX = 33,
	OffsetZ = 0,
	BaseSize = Vector3.new(10, 1, 10),
	BaseCenterHeightAboveGround = 0.5,
	WallThickness = 0.7,
	WallHeight = 4,
	WallCenterHeightAboveGround = 2.5,
	IntakeSize = Vector3.new(10, 8, 10),
	IntakeCenterHeightAboveGround = 3,
	Color = Color3.fromRGB(62, 174, 102),
	Material = Enum.Material.Metal,
	IntakeTransparency = 1,
})

return table.freeze({
	-- Each occupied plot gets one server task that sleeps between production attempts.
	DropInterval = 2,
	InitialOreTypeId = "Stone",
	OreLifetime = 30,
	MaxActiveOresPerPlot = 20,

	OreSpawnOffsetX = -24.5,
	OreSpawnOffsetZ = 0,
	OreSpawnHeightAboveBelt = 2.25,

	Dropper = Dropper,
	Conveyor = Conveyor,
	Collector = Collector,
})
