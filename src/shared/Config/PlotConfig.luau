--!strict

return table.freeze({
	PlotCount = 6,
	GridColumns = 3,
	PlotSize = Vector3.new(120, 1, 120),
	PlotSpacing = 24,

	GroundColor = Color3.fromRGB(91, 123, 78),
	GroundMaterial = Enum.Material.Grass,

	ClaimPlatformSize = Vector3.new(16, 1, 16),
	-- X/Z offset from the plot center; keeps the pad near one edge for future machinery.
	ClaimPlatformOffset = Vector2.new(0, -44),
	AvailableColor = Color3.fromRGB(52, 190, 93),
	OccupiedColor = Color3.fromRGB(190, 75, 65),

	AvailableLabelText = "Reivindicar",
	OccupiedLabelPrefix = "Ocupado: ",
	LabelTextColor = Color3.fromRGB(255, 255, 255),
	LabelSize = Vector2.new(220, 56),
	LabelStudsOffset = Vector3.new(0, 3, 0),
})
