--!strict
--[[
	CollectWorker — the parallel cull worker that runs inside each pool Actor.

	`run(actor)` is called once by the cloned worker LocalScript (CollectWorkerScript) when it starts
	under its Actor. It binds the "collect" message to run in PARALLEL: rebuild a sampler from the
	padded-chunk string, run the cull to a flat f32 buffer (Mesher.collectToBuffer — pure Lua, so it
	is safe in the parallel phase), and publish the result string + triangle count into a SharedTable
	keyed by jobId. The main-thread pool (CollectPool) polls that table and deserializes.

	A SharedTable CANNOT hold a `buffer`, so the cull buffer is transferred as a string
	(buffer.tostring / buffer.fromstring are ~free). The data keys are written BEFORE the "_done"
	flag so a poller that sees "_done" always sees a complete result.
]]

local SharedTableRegistry = game:GetService("SharedTableRegistry")

local Mesher = require(script.Parent.Mesher)

local CollectWorker = {}

-- Name of the cross-Actor SharedTable used for results + the readiness counter. Shared with
-- CollectPool (which reads it) via this constant so the two never drift.
CollectWorker.RESULT_TABLE = "LegacyVoxelCollectResults"

function CollectWorker.run(actor: Actor)
	local results = SharedTableRegistry:GetSharedTable(CollectWorker.RESULT_TABLE)

	actor:BindToMessageParallel(
		"collect",
		function(jobId: string, paddedStr: string, cx: number, cy: number, cz: number)
			local sample = Mesher.makePaddedSampler(paddedStr)
			local bufStr, count = Mesher.collectToBuffer(sample, cx, cy, cz)
			results[jobId] = bufStr
			results[jobId .. "_n"] = count
			results[jobId .. "_done"] = true -- written last: presence => the data keys are ready
		end
	)

	-- Announce readiness so the pool only starts dispatching once every worker has bound (a message
	-- sent before BindToMessageParallel runs would be dropped). Serial phase; atomic increment.
	SharedTable.increment(results, "__ready", 1)
end

return CollectWorker
