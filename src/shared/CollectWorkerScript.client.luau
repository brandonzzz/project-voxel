--[[
	CollectWorkerScript — template LocalScript that CollectPool clones into each worker Actor.

	Inert where Rojo places it: a LocalScript does NOT run inside ReplicatedStorage, so this sits as a
	dormant template. CollectPool:Clone()s it under an Actor parented into PlayerScripts, where the
	clone then runs. Cloning carries the source with it, so the pool never has to write Script.Source
	(which a normal client script lacks the capability to do). Logic lives in the CollectWorker module
	so it stays version-controlled rather than embedded as a string.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectWorker = require(ReplicatedStorage.LegacyVoxelTerrain.CollectWorker)

CollectWorker.run(script:GetActor())
