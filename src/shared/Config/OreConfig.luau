--!strict

-- OreConfig is the single source of truth for what an ore is and, above all, what it is
-- worth.
--
-- MiningService looks the reward up HERE, by the ore id that the server registered when it
-- created the part. The ore Part in Workspace carries no authoritative value: reading a
-- value from the physical object (an attribute, a child ValueBase, its name, ...) would let
-- a client that can touch or replicate an instance decide how much Cash it receives.
--
-- Only the ores listed below exist. The game design plans Coal, Copper, Iron, Silver, Gold,
-- Diamond, Emerald and special ores later; they are intentionally NOT defined yet. Adding
-- one is a matter of adding an entry here (plus the visuals), because every consumer goes
-- through OreTypes/OreConfig.GetOreType instead of hardcoding ids.

export type OreType = {
	-- Stable identifier. Used as the key of OreConfig.OreTypes and as the value of the
	-- server-side ore registry. Must never be reused for a different ore.
	Id: string,

	-- Player facing name (the project's UI language is Brazilian Portuguese).
	DisplayName: string,

	-- Cash granted per ore, decided by the server when a valid collection happens.
	-- Must be a positive whole number: EconomyService.AddCash rejects anything else.
	Value: number,

	-- Placeholder visuals. Ores are simple Parts for now; final models/materials come later.
	Color: Color3,
	Material: Enum.Material,
	Size: Vector3,
}

local OreTypes: { [string]: OreType } = {
	-- The cast goes OUTSIDE table.freeze: a frozen table has a read-only type, so freezing an
	-- already-cast literal would not satisfy the read-write OreType annotation above. Written
	-- this way every entry is frozen, the fields are still checked against OreType, and the
	-- analyzer stays happy under --!strict.
	Stone = table.freeze({
		Id = "Stone",
		DisplayName = "Pedra",

		-- Starting value chosen so the first mining loop is easy to read while testing:
		-- 10 legitimately collected stones are exactly $10. Balance lives here, not in code.
		Value = 1,

		Color = Color3.fromRGB(140, 140, 140),
		Material = Enum.Material.Slate,
		Size = Vector3.new(1.7, 1.7, 1.7),
	}) :: OreType,
}

-- Freezing the map as well means no consumer can add, remove or replace an ore definition at
-- runtime: OreConfig.GetOreType can only ever return what is written above.
table.freeze(OreTypes)

return table.freeze({
	OreTypes = OreTypes,

	-- The ore the first Dropper produces. MiningConfig/plot upgrades will select different
	-- ids later; until then every drop is this one.
	DefaultOreId = "Stone",

	-- Returns nil for unknown ids, so callers must treat a missing definition as "no reward"
	-- rather than falling back to a default value.
	GetOreType = function(oreId: string): OreType?
		return OreTypes[oreId]
	end,
})
