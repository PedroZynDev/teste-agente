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
local purchaseServiceModule = servicesFolder:WaitForChild("PurchaseService") :: ModuleScript
local PurchaseService = require(purchaseServiceModule)
local dataServiceModule = servicesFolder:WaitForChild("DataService") :: ModuleScript
local DataService = require(dataServiceModule)

PlotService.Initialize()
EconomyService.Initialize()

-- MiningService needs both services above: it subscribes to PlotService's server-side
-- claim/release notifications to install/remove a plot's mining setup and pays collected
-- ores through EconomyService.AddCash. Its listeners must be connected before any player
-- can touch a claim platform. If the ServerStorage mining asset or its configuration is
-- invalid, this call raises a clear startup error; plots and economy above remain fully
-- functional.
MiningService.Initialize()

-- PurchaseService sits on top of all three: it listens to PlotService claim/release to
-- show/hide purchase pads, charges through EconomyService.SpendCash and grants the item
-- through MiningService.AddExtraDropperLine. Initialized after all of them, so by the
-- time any pad exists, mining validation has already run (if mining is disabled, this
-- line is never reached and no pads are created).
PurchaseService.Initialize()

-- DataService is the only DataStore caller and wraps the whole flow: it needs
-- EconomyService initialized first (restore applies once the player has economy state;
-- the exit save reads EconomyService.SnapshotCash), and it must come after every service
-- that produces or spends Cash so nothing can earn against an un-restored balance.
-- A store outage degrades to "no persistence" with warnings; the game keeps running.
DataService.Initialize()
