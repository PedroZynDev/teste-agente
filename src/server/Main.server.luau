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

PlotService.Initialize()
EconomyService.Initialize()

-- MiningService needs both services above: it subscribes to PlotService's server-side
-- claim/release notifications to install/remove a plot's mining setup and pays collected
-- ores through EconomyService.AddCash. Initialized last so its listeners are connected
-- before any player can touch a claim platform. If the ServerStorage mining asset or its
-- configuration is invalid, this call raises a clear startup error; plots and economy
-- above remain fully functional.
MiningService.Initialize()
