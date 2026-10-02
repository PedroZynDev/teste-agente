--!strict

-- First purchasable tycoon item ("primeira compra" in GAME_DESIGN.md's priority list).
--
-- Purchases use the classic Roblox tycoon mechanism: a touch pad inside the plot, the
-- same way claiming works. The client never sends a purchase request (there are NO
-- RemoteEvents/RemoteFunctions); touching the pad is a server-side physics event and
-- PurchaseService validates everything below server-side:
-- plot ownership, once-per-occupancy rule, price from this config only, and the atomic
-- balance check inside EconomyService.SpendCash.

return table.freeze({
	ExtraDropper = table.freeze({
		Id = "ExtraDropper",
		DisplayName = "Segundo Dropper",

		-- One-time price in Cash per plot occupancy (persistence does not exist yet, so
		-- re-claiming a plot starts unpurchased on purpose, like the setup itself).
		-- Income on the starter line is ~$0.5/s (one $1 stone every 2s), so this first
		-- upgrade costs roughly 50 seconds of idling and then doubles production.
		Price = 25,

		-- Pad placement relative to the plot's Ground center (X/Z; the pad rests on the
		-- ground surface, so Y is computed from the ground, like the claim platform).
		-- x = 40 keeps it beside the purchasable line (MiningConfig.LinePivotOffsets[2]);
		-- z = -38 keeps it clear of the claim platform (z = -44, x = 0) and of the
		-- machinery, which starts at z ~= -28.
		PadOffset = Vector3.new(40, 0, -38),
		PadSize = Vector3.new(14, 1, 14),
		PadAvailableColor = Color3.fromRGB(52, 190, 93),
		PadSoldColor = Color3.fromRGB(110, 110, 110),

		-- Billboard text (same presentation style as the claim platform label).
		LabelAvailableFormat = "Comprar: %s  |  $%d",
		LabelSoldText = "Comprado",
		LabelTextColor = Color3.fromRGB(255, 255, 255),
		LabelSize = Vector2.new(240, 56),
	}),
})
