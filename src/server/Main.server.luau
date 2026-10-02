--!strict

local serverFolder = script.Parent
assert(serverFolder ~= nil, "[Main] Main.server.luau must be parented under Server")

local servicesFolder = serverFolder:WaitForChild("Services")
local plotServiceModule = servicesFolder:WaitForChild("PlotService") :: ModuleScript
local PlotService = require(plotServiceModule)
local economyServiceModule = servicesFolder:WaitForChild("EconomyService") :: ModuleScript
local EconomyService = require(economyServiceModule)
local miningServiceModule = servicesFolder:WaitForChild("MiningService") :: ModuleScript
local MiningService = require(miningServiceModule)

-- Collectors must not be able to credit Cash before the economy owns player state.
EconomyService.Initialize()
-- Generate ownership state and plots before mining builds their per-plot structures.
PlotService.Initialize()
-- PlotService.Initialize() does not yield, so lifecycle hooks are in place before physics can claim a pad.
MiningService.Initialize()
