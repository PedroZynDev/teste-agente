--!strict

-- Tuning values for the first functional mining cycle
-- (Dropper -> physical Stone -> Conveyor -> Collector -> +$1 Cash).
--
-- All numbers the mining loop depends on live here; MiningService should not contain
-- magic numbers. This module is shared (ReplicatedStorage) so the client can later
-- mirror timings/values for display, but only the server acts on it.

return table.freeze({
	-- The ore the starter dropper produces. Must be a key in OreConfig. Future dropper
	-- upgrades will select other ore ids; for now production is fixed to Stone.
	DropperOreId = "Stone",

	-- Seconds between drop attempts on an occupied plot. When the per-plot ore cap is
	-- reached the tick is skipped and production resumes automatically on the next tick
	-- that finds free space.
	DropInterval = 2,

	-- Seconds before an uncollected ore is removed (belt jam, weird bounce, ...).
	-- Guarantees the plot can never accumulate parts forever.
	OreLifetime = 30,

	-- Hard cap of simultaneously alive ores per plot (shared by ALL lines of the plot),
	-- enforced with the service's authoritative counter (not a Workspace scan).
	MaxActiveOresPerPlot = 20,

	-- Constant belt speed in studs/second. Applied by the centralized conveyor update as
	-- a horizontal velocity injection on each ore, so movement stays smooth and physics
	-- (falling onto the belt, collisions) is preserved. No teleporting to the collector.
	BeltSpeed = 8,

	-- Extra studs past the CollectorTrigger along the belt's local +Z where ores are
	-- still pushed. Guarantees an ore entering the trigger is actually touched; beyond
	-- this distance injection stops so stray parts cannot fly out of the setup (they
	-- are cleaned up by OreLifetime).
	BeltOvershoot = 4,

	-- Studs the ore is dropped above the OreSpawn CFrame, so a fresh Stone lands on the
	-- belt instead of spawning intersecting its surface.
	DropClearance = 0.5,

	-- Pivot offsets, in the template's LOCAL space, from the top-center of the plot's
	-- ground to each production line's StarterMiningSetup clone, applied with
	-- Model:PivotTo(). Index 1 is the free starter line installed on claim; higher
	-- indices are extra lines purchasable through the purchase flow, so
	-- #LinePivotOffsets - 1 is the purchasable capacity per plot.
	--
	-- The template spans roughly local z = -16 (back of the dropper) to z ~= +26
	-- (collector at z = 23.6), so:
	-- * z = -12 centers the ~40 studs of machinery on the 120x120 plot: away from the
	--   claim platform at local z = -44, inside the ground bounds, and far enough that
	--   setups of neighbouring plots (24 studs apart) can never overlap.
	-- * x = +40 for line 2 places the purchasable line parallel to the starter line,
	--   fully inside the plot (machinery stays within x in [-20, +60] of the plot
	--   center) and clear of the purchase pad at x = 40, z = -38 (see PurchaseConfig).
	-- Orientation stays identity for every line: all flows run along world +Z.
	LinePivotOffsets = table.freeze({
		Vector3.new(0, 0, -12),
		Vector3.new(40, 0, -12),
	}),
})
