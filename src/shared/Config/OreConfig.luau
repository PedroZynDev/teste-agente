--!strict

export type OreDefinition = {
	Id: string,
	DisplayName: string,
	Value: number,
	Color: Color3,
	Material: Enum.Material,
	Size: Vector3,
}

-- Keep every ore's presentation and server-authoritative payout together here.
-- Add future ore definitions as new entries keyed by their stable Id.
local OreDefinitions: { [string]: OreDefinition } = {
	Stone = table.freeze({
		Id = "Stone",
		DisplayName = "Pedra",
		Value = 1, -- $1 per legitimately collected Stone.
		Color = Color3.fromRGB(116, 119, 124),
		Material = Enum.Material.Rock,
		Size = Vector3.new(1.8, 1.8, 1.8),
	}),
}

return table.freeze(OreDefinitions)
