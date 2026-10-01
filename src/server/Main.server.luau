--!strict

local serverFolder = script.Parent
assert(serverFolder ~= nil, "[Main] Main.server.luau must be parented under Server")

local servicesFolder = serverFolder:WaitForChild("Services")
local plotServiceModule = servicesFolder:WaitForChild("PlotService") :: ModuleScript
local PlotService = require(plotServiceModule)

PlotService.Initialize()
