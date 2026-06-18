--!strict
--[[
	CollectPool — a fixed pool of worker Actors that run the chunk cull (Mesher.collectToBuffer) in
	parallel, off the main thread, so the ~21 ms/chunk face-extraction no longer blocks Heartbeat.

	Each worker is an Actor holding a clone of the CollectWorkerScript LocalScript (see that file for
	why we clone rather than write Script.Source). Workers are parented under a Folder inside the
	caller's container (PlayerScripts) so the LocalScripts actually run.

	Usage (main thread / a coroutine):
		local pool = CollectPool.new(4, playerScripts)        -- yields until all workers are bound
		local tris, count = pool:collect(cx, cy, cz, paddedStr) -- yields until a worker returns

	`collect` waits for a free worker, ships the padded-chunk snapshot, yields until the result is
	published, then deserializes on the main thread (~0.25 ms). Run several `collect`s concurrently
	(one per build coroutine) with numWorkers >= concurrency and the culls overlap each other AND the
	main-thread fill/bake/apply of already-collected chunks.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

local Mesher = require(script.Parent.Mesher)
local CollectWorker = require(script.Parent.CollectWorker)

local CollectPool = {}
CollectPool.__index = CollectPool

export type Pool = typeof(setmetatable(
	{} :: {
		workers: { Actor },
		busy: { boolean },
		results: SharedTable,
		folder: Folder,
		jobCounter: number,
	},
	CollectPool
))

-- Create `numWorkers` worker Actors under a Folder parented into `parent` (PlayerScripts). YIELDS
-- until every worker has bound its handler, so the first collect can't be dropped. --
function CollectPool.new(numWorkers: number, parent: Instance): Pool
	local results = SharedTableRegistry:GetSharedTable(CollectWorker.RESULT_TABLE)
	results["__ready"] = 0 -- reset before the workers start incrementing

	local template = ReplicatedStorage.LegacyVoxelTerrain:FindFirstChild("CollectWorkerScript")
	assert(template, "CollectPool: CollectWorkerScript template missing from ReplicatedStorage")

	local folder = Instance.new("Folder")
	folder.Name = "CollectPool"

	local workers: { Actor } = {}
	local busy: { boolean } = {}
	for i = 1, numWorkers do
		local actor = Instance.new("Actor")
		actor.Name = "CollectWorker" .. i
		local ls = (template :: LocalScript):Clone()
		ls.Disabled = false
		ls.Parent = actor
		actor.Parent = folder
		workers[i] = actor
		busy[i] = false
	end
	folder.Parent = parent -- subtree enters PlayerScripts here -> the cloned LocalScripts start

	-- Wait for all workers to announce they've bound the "collect" handler.
	while ((results["__ready"] :: number?) or 0) < numWorkers do
		RunService.Heartbeat:Wait()
	end

	return setmetatable({
		workers = workers,
		busy = busy,
		results = results,
		folder = folder,
		jobCounter = 0,
	}, CollectPool)
end

-- Index of a free worker, or nil if all are busy. --
local function freeWorker(self: Pool): number?
	for i, b in self.busy do
		if not b then
			return i
		end
	end
	return nil
end

-- True if a worker is available right now (lets a dispatcher decide whether to start another job
-- without yielding). --
function CollectPool.hasFree(self: Pool): boolean
	return freeWorker(self) ~= nil
end

-- Run the cull for chunk (cx,cy,cz) on a worker. YIELDS until a worker is free, ships `paddedStr`
-- (Mesher.buildPaddedChunk), yields until the worker publishes the result, then deserializes on the
-- main thread. Returns (triangles, count). --
function CollectPool.collect(
	self: Pool,
	cx: number,
	cy: number,
	cz: number,
	paddedStr: string
): ({ Mesher.Tri }, number)
	local wi = freeWorker(self)
	while not wi do
		RunService.Heartbeat:Wait()
		wi = freeWorker(self)
	end
	self.busy[wi] = true

	self.jobCounter += 1
	local jobId = "j" .. self.jobCounter
	self.workers[wi]:SendMessage("collect", jobId, paddedStr, cx, cy, cz)

	local results = self.results
	while not results[jobId .. "_done"] do
		RunService.Heartbeat:Wait()
	end

	local bufStr = results[jobId] :: string
	local count = results[jobId .. "_n"] :: number
	results[jobId] = nil
	results[jobId .. "_n"] = nil
	results[jobId .. "_done"] = nil
	self.busy[wi] = false

	return Mesher.deserializeTris(bufStr, count), count
end

function CollectPool.destroy(self: Pool)
	self.folder:Destroy()
end

return CollectPool
