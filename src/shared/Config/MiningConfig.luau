--!strict

-- MiningConfig centralizes every tunable number of the first mining loop (Dropper -> ore ->
-- conveyor -> Collector -> Cash), so no magic numbers are spread through MiningService.
--
-- The layout below describes ONE plot. It is expressed as offsets from the plot's own
-- origin, which is the center of the plot Ground part, so the exact same structure works
-- for all 6 plots regardless of where PlotService placed them (and regardless of any
-- rotation the Baseplate/plot may have).
--
-- Axis convention inside a plot:
--   * the machinery runs along the plot-local X axis;
--   * ores travel from -X (Dropper) towards +X (Collector);
--   * plot-local Z = 0 is the machinery lane. The ClaimPlatform is placed by PlotConfig at
--     plot-local Z = -44, so the lane must stay well away from it.
--
-- Units are studs. Offsets are Vector3 relative to the plot origin; the plot Ground surface
-- is plot-local Y = 0 (PlotConfig.PlotSize.Y is 1 and the Ground is centered on the origin).

return table.freeze({
	-- ============================================================
	-- Production
	-- ============================================================

	-- Seconds between two ores from one Dropper.
	DropInterval = 2.0,

	-- Seconds an ore may exist before the cleanup sweep destroys it. Bounds how long a
	-- blocked or lost ore can hold one of the MaxActiveOresPerPlot slots.
	OreLifetime = 30.0,

	-- How often the single global cleanup sweep runs. One sweep for the whole game, not one
	-- timer per ore: with 6 plots x 20 ores that would be 120 threads for no benefit.
	CleanupInterval = 1.0,

	-- ============================================================
	-- Limits
	-- ============================================================

	-- Hard cap of live ores per plot. When it is reached the Dropper simply skips its next
	-- tick and retries on the following one; ores are never force-destroyed to make room,
	-- because an ore in transit is money the player already earned. OreLifetime bounds how
	-- long the cap can stay saturated, so production always resumes.
	MaxActiveOresPerPlot = 20,

	-- ============================================================
	-- Conveyor
	-- ============================================================

	-- Studs per second the belt surface moves. This is written to the belt's
	-- AssemblyLinearVelocity exactly once, when the structure is built and already inside
	-- Workspace; the engine then carries every ore resting on it. No per-frame script.
	ConveyorSpeed = 16.0,

	-- ============================================================
	-- Ore placeholder
	-- ============================================================

	-- Extra identity markers on the physical Part. They are for debugging and for future
	-- visual systems only: MiningService never reads them back to decide a reward.
	OreName = "Ore",
	OreTagAttribute = "MiningTycoonOre",
	OrePlotNameAttribute = "MiningTycoonPlot",

	-- ============================================================
	-- Plot layout
	-- ============================================================

	Dropper = table.freeze({
		Color = Color3.fromRGB(70, 92, 130),
		Material = Enum.Material.Metal,

		-- Vertical column. Sits behind (more negative X than) the belt start.
		TowerSize = Vector3.new(6.5, 9, 6.5),
		TowerOffset = Vector3.new(-33.5, 4.5, 0),

		-- Dispensing head, directly above the belt start. The ore appears in the gap between
		-- the head and the belt, so it drops a short, predictable distance and cannot bounce
		-- off the belt.
		HeadSize = Vector3.new(5, 2.5, 7),
		HeadOffset = Vector3.new(-26, 8, 0),
	}),

	Belt = table.freeze({
		Color = Color3.fromRGB(52, 56, 62),
		Material = Enum.Material.DiamondPlate,
		Thickness = 1.0,
		Width = 10.0,
		-- Height of the belt TOP surface above the plot ground.
		Height = 3.0,
		-- Belt span along the plot-local X axis.
		StartX = -26.0,
		EndX = 22.0,

		-- Support legs from the ground up to the belt bottom.
		LegSize = Vector3.new(1.2, 0, 1.2), -- Y is derived from the belt height
		LegOffsetsX = { -20.0, -8.0, 4.0, 16.0 },

		-- Side rails keep ores on the belt. Physics jitter, a bump between two ores or a
		-- player standing on the belt could otherwise push an ore off the side, where it
		-- would never reach the Collector.
		RailColor = Color3.fromRGB(120, 126, 134),
		RailMaterial = Enum.Material.Metal,
		RailThickness = 0.6,
		RailHeight = 2.0,
		-- Distance from the belt center line to the rail center line. Slightly larger than
		-- half the belt width so the rails hug the belt edges.
		RailOffsetZ = 5.15,
	}),

	-- Direction markers painted on the belt: chevrons pointing towards the Collector. Purely
	-- visual geometry (no script, no tween, no per-frame cost).
	Chevron = table.freeze({
		Color = Color3.fromRGB(255, 170, 60),
		Material = Enum.Material.Neon,
		BarSize = Vector3.new(0.7, 0.15, 5.0),
		-- Bar tilt around the plot-local Y axis; +45/-45 form the ">" shape.
		BarAngleDegrees = 45.0,
		-- Distance from the belt center line to each bar's center, along Z.
		BarOffsetZ = 1.6,
		-- Height of the chevron center above the plot ground. Just above the belt top so the
		-- bars read as painted on the belt and stay clear of the ore.
		Height = 3.07,
		CentersX = { -18.0, -8.0, 2.0, 12.0, 20.0 },
	}),

	Collector = table.freeze({
		-- The sell point is an invisible trigger box, NOT a solid block.
		--
		-- A solid Collector in front of the belt end stops the ore while it is still riding
		-- the belt (an anchored part cannot be pushed), and a Collector that only starts
		-- after the belt end relies on the ore's ballistic hop landing inside it. A
		-- CanCollide = false / CanTouch = true box overlapping the last studs of the belt
		-- gets neither problem: the ore keeps riding into it and Touched fires while the ore
		-- is still supported.
		Sensor = table.freeze({
			-- X of the belt-side face of the trigger. Must sit a few studs BEFORE Belt.EndX.
			FrontX = 18.0,
			-- Trigger depth along X. FrontX + Size.X must reach past Belt.EndX.
			Size = Vector3.new(7.0, 6.0, 12.0),
			-- Center height above the plot ground. The box must bracket the whole ore path:
			-- from the belt surface up to belt surface + ore height.
			CenterY = 4.5,
			Transparency = 1.0,
		}),

		-- Visible hopper around the trigger: purely decorative frame plus a floor that catches
		-- anything that does leave the belt, so the line never looks broken.
		Color = Color3.fromRGB(168, 92, 40),
		Material = Enum.Material.Metal,
		Hopper = table.freeze({
			-- Spans of the hopper shell in plot-local coordinates. StartX/BackX must span the
			-- whole Sensor volume and FloorTopY must sit under it, so an ore that ever leaves
			-- the belt lands inside the machine instead of on the plot ground.
			StartX = 18.0,
			BackX = 26.0,
			HalfZ = 6.5,
			WallThickness = 1.0,
			FloorTopY = 1.0,
			CapBottomY = 7.0,
			CapThickness = 0.6,
		}),

		-- Bright cap so the end of the line is obvious at a glance.
		TopColor = Color3.fromRGB(255, 190, 70),
		TopMaterial = Enum.Material.Neon,
		TopSize = Vector3.new(8.0, 0.7, 13.0),
		TopOffsetY = 7.95,
	}),

	-- Where an ore appears, in plot-local space. Must be above the belt, between the rails,
	-- and clear of the Dropper head. MiningService validates all of this on startup and
	-- refuses to initialize if the layout would not work.
	DropPointOffset = Vector3.new(-21.0, 5.5, 0.0),
})
