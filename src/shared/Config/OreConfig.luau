--!strict

-- Ore definitions for the mining loop.
--
-- * One frozen entry per ore type. MiningService indexes every entry by `Id` at startup,
--   so registering a future ore (Coal, Iron, ...) only requires adding an entry here.
-- * `Value` is the Cash reward per collected ore and is read ONLY by server code
--   (MiningService). The client may read this module for display purposes, but it must
--   never be the authority for rewards: the server always re-resolves the value from this
--   config, never from attributes or names on the physical ore part.
-- * This phase intentionally ships with a single ore (Stone). Do not add more ores until
--   progression actually needs them.

return table.freeze({
	Stone = table.freeze({
		Id = "Stone",
		DisplayName = "Pedra",
		-- Reward per collected ore, in Cash. Must be a whole number > 0.
		Value = 1,
		-- The ore is a plain server-created physical Part with this size.
		Size = Vector3.new(2, 2, 2),
		Color = Color3.fromRGB(138, 136, 132),
		Material = Enum.Material.Slate,
	}),
})
