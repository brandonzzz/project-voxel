--!strict
--[[
	ServerRenderStreamer — the server bakes terrain render meshes and DELIVERS them for clients to
	capture (clone) and keep, then frees its own copy. This removes the 200 MB/server static-content
	ceiling: the server only ever holds the small in-flight / recently-delivered window, while each
	client holds the persistent render on its own (disk-limited) side. Verified basis: a client-cloned
	mesh survives the server destroying its copy with geometry intact (see the server-render
	architecture findings).

	Pipeline (server-authoritative):
	  1. Each Heartbeat the union of all players' render-distance chunk disks is the "wanted" set.
	  2. Wanted chunks not currently delivered are queued (nearest-first) and baked via
	     Mesher.rebuildChunk into `delivery` -- a NON-rendered replicated container (ReplicatedStorage)
	     so the delivery copy never double-renders against the client's workspace clone.
	  3. Baking is paced by the SAME distance-adaptive credit gate as the client ChunkManager (near
	     chunks fast, far chunks < 1 op/frame), so server bakes never stack into a replication-
	     stalling stutter. One chunk builds at a time (server has no render budget to spare either).
	  4. A delivered chunk is FREED once it has been resident longer than `captureWindow` AND is no
	     longer wanted (ample time for replication + the client clone). Clients that miss the window
	     (lag / late join) re-request via requestChunk.
	  5. On StorageLimitExceeded the oldest delivered chunk is freed and the chunk requeued, so a
	     bake never hard-fails.

	The "leave loaded, LRU-prune oldest, protect in-render-distance" policy lives on the CLIENT
	(cheap disk), not here. This streams ONLY render meshes; collision + loose parts keep their own
	existing distance-streamed logic (ServerChunkStreamer / LoosePartManager).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Lib = game:GetService("ReplicatedStorage"):WaitForChild("LegacyVoxelTerrain")
local Constants = require(Lib:WaitForChild("Constants"))
local Mesher = require(Lib:WaitForChild("Mesher"))

local CHUNK_STUDS = Constants.CHUNK_STUDS

local ServerRenderStreamer = {}
ServerRenderStreamer.__index = ServerRenderStreamer

local function keyOf(cx: number, cz: number): string
	return cx .. "_" .. cz
end

-- Distance-adaptive heavy-op rate (ops/frame), mirrored from ChunkManager so the server and client
-- pace identically: near chunks fast (accept brief server-frame dips), far chunks < 1 op/frame.
local function opsPerFrameFor(self, dchunks: number): number
	local far = math.max(self.nearDist + 1, self.farDist)
	local t = math.clamp((dchunks - self.nearDist) / (far - self.nearDist), 0, 1)
	return self.nearOpsPerFrame + (self.farOpsPerFrame - self.nearOpsPerFrame) * t
end

export type Opts = {
	store: any,
	ensureWorld: (number, number, number) -> (), -- base + autowedge + saved edits for a chunk
	delivery: Instance, -- a NON-rendered replicated container (e.g. a folder under ReplicatedStorage)
	cy: number?,
	radius: number?, -- render distance in chunks
	captureWindow: number?, -- seconds to keep a delivered chunk before freeing it
	nearDist: number?,
	farDist: number?,
	nearOpsPerFrame: number?,
	farOpsPerFrame: number?,
}

function ServerRenderStreamer.new(opts: Opts)
	local self = setmetatable({}, ServerRenderStreamer)
	self.store = opts.store
	self.ensureWorld = opts.ensureWorld
	self.delivery = opts.delivery
	self.cy = opts.cy or 0
	self.radius = opts.radius or 6
	self.captureWindow = opts.captureWindow or 4
	self.nearDist = opts.nearDist or 2
	self.farDist = opts.farDist or 4
	self.nearOpsPerFrame = opts.nearOpsPerFrame or 2
	self.farOpsPerFrame = opts.farOpsPerFrame or 0.34

	self.delivered = {} :: { [string]: { cx: number, cz: number, at: number } }
	self.queue = {} :: { { key: string, cx: number, cz: number, dist: number } }
	self.inQueue = {} :: { [string]: boolean }
	self.building = false
	self._opCredits = 1
	self._activeChunk = nil :: { cx: number, cz: number }?
	self._lastScan = 0
	self._conn = nil

	local mgr = self
	self._yielder = function()
		-- the build's synchronous fill is time-sliced; the bakes block but are credit-gated
		RunService.Heartbeat:Wait()
	end
	-- Heavy-op credit gate (mirrors ChunkManager._bakeGate): one credit per AssetService op
	-- (bake + CreateMeshPartAsync), refilled per frame by update() at a distance-dependent rate.
	self._assetGate = function()
		while mgr._opCredits < 1 do
			RunService.Heartbeat:Wait()
		end
		mgr._opCredits -= 1
	end
	return self
end

-- Player chunk-positions (one floor'd chunk coord per player with a character).
function ServerRenderStreamer:_playerFoci(): { { cx: number, cz: number } }
	local foci = {}
	for _, plr in Players:GetPlayers() do
		local char = plr.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			local p = hrp.Position
			foci[#foci + 1] = { cx = math.floor(p.X / CHUNK_STUDS), cz = math.floor(p.Z / CHUNK_STUDS) }
		end
	end
	return foci
end

-- Min distance (in chunks) from chunk (cx,cz) to any player; math.huge if no players.
function ServerRenderStreamer:_minDistToPlayers(cx: number, cz: number, foci: { { cx: number, cz: number } }): number
	local best = math.huge
	for _, f in foci do
		local dx, dz = cx - f.cx, cz - f.cz
		local d = math.sqrt(dx * dx + dz * dz)
		if d < best then
			best = d
		end
	end
	return best
end

-- Union of every player's render disk = the chunks that should currently be delivered/available.
function ServerRenderStreamer:_wanted(foci: { { cx: number, cz: number } }): { [string]: { cx: number, cz: number } }
	local want = {}
	local r = self.radius
	for _, f in foci do
		for dx = -r, r do
			for dz = -r, r do
				if dx * dx + dz * dz <= r * r then
					local cx, cz = f.cx + dx, f.cz + dz
					want[keyOf(cx, cz)] = { cx = cx, cz = cz }
				end
			end
		end
	end
	return want
end

function ServerRenderStreamer:_enqueue(cx: number, cz: number)
	local key = keyOf(cx, cz)
	if self.delivered[key] or self.inQueue[key] then
		return
	end
	self.inQueue[key] = true
	self.queue[#self.queue + 1] = { key = key, cx = cx, cz = cz, dist = 0 }
end

-- Public: a client needs a chunk that isn't currently delivered (cache miss) -- re-bake it.
function ServerRenderStreamer:requestChunk(cx: number, cz: number)
	self:_enqueue(cx, cz)
end

-- Re-deliver a chunk after its cells changed (edit/explosion). No-op if not currently delivered.
function ServerRenderStreamer:markDirty(cx: number, cz: number)
	local key = keyOf(cx, cz)
	if self.delivered[key] then
		self.delivered[key] = nil
		self:_removeParts(cx, cz)
		self:_enqueue(cx, cz)
	end
end

function ServerRenderStreamer:_removeParts(cx: number, cz: number)
	local base = string.format("C_%d_%d_%d", cx, self.cy, cz)
	for _, ch in self.delivery:GetChildren() do
		if ch.Name == base or string.match(ch.Name, "^" .. base .. "_oct%d$") then
			ch:Destroy()
		end
	end
end

-- Free the single oldest delivered chunk (used as the StorageLimitExceeded backstop).
function ServerRenderStreamer:_freeOldest(): boolean
	local oldestKey, oldestAt = nil, math.huge
	for key, info in self.delivered do
		if info.at < oldestAt then
			oldestAt, oldestKey = info.at, key
		end
	end
	if oldestKey then
		local info = self.delivered[oldestKey]
		self.delivered[oldestKey] = nil
		self:_removeParts(info.cx, info.cz)
		return true
	end
	return false
end

function ServerRenderStreamer:_buildOne(cx: number, cz: number)
	self.ensureWorld(cx, self.cy, cz)
	local stats = Mesher.rebuildChunk(self.store, cx, self.cy, cz, self.delivery, self._yielder, self._assetGate)
	if stats.storageLimited then
		-- budget momentarily full: free the oldest delivered chunk and requeue this one
		self:_removeParts(cx, cz) -- drop any partial parts we just made
		if self:_freeOldest() then
			self:_enqueue(cx, cz)
		end
		return
	end
	-- Mark delivered even if empty (0 parts) so we don't re-queue an air/buried chunk every tick.
	self.delivered[keyOf(cx, cz)] = { cx = cx, cz = cz, at = os.clock() }
end

function ServerRenderStreamer:_dispatch(foci: { { cx: number, cz: number } })
	if self.building or #self.queue == 0 or self._opCredits < 1 then
		return
	end
	-- nearest-first: re-score by current nearest player, pop the closest
	for _, it in self.queue do
		it.dist = self:_minDistToPlayers(it.cx, it.cz, foci)
	end
	table.sort(self.queue, function(a, b)
		return a.dist > b.dist -- nearest last, popped first
	end)
	local it = self.queue[#self.queue]
	self.queue[#self.queue] = nil
	self.inQueue[it.key] = nil
	self.building = true
	self._activeChunk = { cx = it.cx, cz = it.cz }
	task.spawn(function()
		local ok, err = pcall(function()
			self:_buildOne(it.cx, it.cz)
		end)
		if not ok then
			warn("[ServerRenderStreamer] build error at " .. it.key .. ": " .. tostring(err))
		end
		self.building = false
		self._activeChunk = nil
	end)
end

function ServerRenderStreamer:_update()
	local foci = self:_playerFoci()

	-- refill the distance-adaptive credit bucket by the building chunk's current distance
	local ac = self._activeChunk
	if ac and #foci > 0 then
		local r = opsPerFrameFor(self, self:_minDistToPlayers(ac.cx, ac.cz, foci))
		self._opCredits = math.min(self._opCredits + r, math.max(1, math.ceil(r)))
	else
		self._opCredits = 1
	end

	-- ~5 Hz: refresh the wanted set, enqueue missing, free expired-and-unwanted deliveries
	local now = os.clock()
	if now - self._lastScan >= 0.2 then
		self._lastScan = now
		local want = self:_wanted(foci)
		for key, pos in want do
			if not self.delivered[key] and not self.inQueue[key] then
				self:_enqueue(pos.cx, pos.cz)
			end
		end
		for key, info in self.delivered do
			if (now - info.at) > self.captureWindow and not want[key] then
				self.delivered[key] = nil
				self:_removeParts(info.cx, info.cz)
			end
		end
	end

	self:_dispatch(foci)
end

function ServerRenderStreamer:start()
	if self._conn then
		return
	end
	self._conn = RunService.Heartbeat:Connect(function()
		local ok, err = pcall(function()
			self:_update()
		end)
		if not ok then
			warn("[ServerRenderStreamer] update error: " .. tostring(err))
		end
	end)
end

function ServerRenderStreamer:stop()
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
end

return ServerRenderStreamer
