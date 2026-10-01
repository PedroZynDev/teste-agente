--!strict

return table.freeze({
	-- Cash every player starts each session with (there is no persistence yet).
	StartingCash = 0,

	-- Hard ceiling for a player's Cash. Must be a positive integer <= 2^53 - 1
	-- (9,007,199,254,740,991), the largest range where Luau numbers (doubles) and
	-- JSON/DataStore values stay exact integers.
	--
	-- 1_000_000_000_000 (one trillion) is far beyond any planned normal progression, yet
	-- ~9000x below that limit, which leaves ample headroom for future multipliers and
	-- persistence. It also fits comfortably in an IntValue (leaderstats).
	--
	-- AddCash saturates at this value instead of overflowing or failing.
	MaxCash = 1_000_000_000_000,
})
