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

-- Initialization order follows the dependency chain, lowest level first:
--
--   1. EconomyService - Cash is the foundation every other service pays into, so player
--      economy state exists before anything can grant money.
--   2. PlotService    - builds Workspace.TycoonPlots and owns plot claim/release.
--   3. MiningService  - consumes both: it subscribes to PlotService's claim/release
--      notifications (so PlotService must already exist) and pays through EconomyService.
--      Its Initialize() also requires the plots to already be built, and errors with a clear
--      message if they are not.
EconomyService.Initialize()
PlotService.Initialize()
MiningService.Initialize()
