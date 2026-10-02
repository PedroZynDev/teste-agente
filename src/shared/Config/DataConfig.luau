--!strict

-- Basic persistence configuration (consumed by DataService, which is the ONLY module
-- allowed to touch DataStoreService in this project).
--
-- Deliberately scoped to "persistência básica" (GAME_DESIGN priority 6): the only
-- progression that currently exists is Cash. Rubis, rebirth counts, persistent upgrades
-- and permanent purchases are documented future DataStore fields and must extend the
-- record schema below via DataVersion migrations — not by adding a second store.

return table.freeze({
	-- DataStore name for this game's session data.
	StoreName = "MiningTycoon_v1",

	-- Keys are "Player_<UserId>", derived server-side from Player.UserId only.
	-- Clients never see or control the key.
	KeyPrefix = "Player_",

	-- Record schema: { Version = DataVersion, Cash = <whole number> }.
	-- Readers only accept the current version (an incompatible future format must
	-- migrate old records instead of misreading them).
	DataVersion = 1,

	-- Bounded retry policy for GetAsync/UpdateAsync. Retries use linear backoff
	-- (RetryBackoffSeconds * attempt). A store outage must degrade to warnings, never
	-- break the server or wipe data (see DataService).
	MaxRetries = 3,
	RetryBackoffSeconds = 1,

	-- Autosave period. Only players whose Cash differs from their last saved value are
	-- written, so an idle server does no DataStore traffic. Kept deliberately high:
	-- Roblox throttles DataStore bandwidth, and saving every small change is exactly
	-- what AGENTS.md forbids.
	SaveIntervalSeconds = 60,

	-- Upper bound for how long a save waits for its player's unresolved load before it
	-- gives up (load itself is bounded by MaxRetries, so this is a safety cap). Skipping
	-- the save keeps the previously persisted record intact — never overwriting with a
	-- half-loaded view is more important than persisting a few last seconds.
	SaveWaitForLoadSeconds = 10,
})
