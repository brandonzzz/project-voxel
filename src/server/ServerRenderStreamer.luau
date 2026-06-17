--!strict
--[[
	ServerRenderStreamer — server-authoritative, PER-PLAYER terrain render delivery + capture.

	The server bakes each character's render-distance chunks (chosen from the character's position)
	and delivers them to ONLY that player via player.PlayerGui/<deliveryFolderName> -- PlayerGui
	replicates per-player, so no other client receives them. The client clones each delivered chunk
	into its own workspace render folder (a captured copy that survives the server freeing its own)
	and fires a capture ack; on the ack the server destroys its delivery copy, reclaiming the
	200 MB/server static-content budget. The server's resident set therefore stays tiny (only
	in-flight / un-acked chunks) regardless of player count or render distance -- the persistent
	render lives on each client's (disk-limited) side. (See the server-render architecture findings
	in memory: capture survives the server destroy; PlayerGui delivery renders.)

	Server-authoritative: the client NEVER requests chunks. The server picks each player's set from
	position; the client only confirms receipt (onAck) -- a state sync, not a load request.

	Pacing: the same distance-adaptive credit gate as the client ChunkManager (near chunks fast, far
	chunks < 1 op/frame), so server bakes never stack into a replication-stalling stutter; one chunk
	builds at a time. StorageLimitExceeded -> free the oldest un-acked delivery and requeue.

	Streams ONLY render meshes; collision + loose parts keep their existing distance-streamed logic
	(ServerChunkStreamer / LoosePartManager).

	FIRST VERSION: the client keeps every captured chunk for the session (no eviction yet), so the
	server never re-delivers a captured chunk. Client-side LRU eviction (with a resync so the server
	re-delivers a pruned chunk that re-enters range) and bake-sharing across overlapping players are
	planned follow-ups.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Lib = game:GetService("ReplicatedStorage"):WaitForChild("LegacyVoxelTerrain")
local Constants = require(Lib:WaitForChild("Constants"))
local Mesher = require(Lib:WaitForChild("Mesher"))

local CHUNK_STUDS = Constants.CHUNK_STUDS

local ServerRenderStreamer = {}
ServerRenderStreamer.__index = ServerRenderStreamer

local function chunkKey(cx: number, cz: number): string
	return cx .. "_" .. cz
end

-- Distance-adaptive heavy-op rate (ops/frame), mirrored from ChunkManager so server + client pace
-- identically: near chunks fast (accept brief server-frame dips), far chunks < 1 op/frame.
local function opsPerFrameFor(self, dchunks: number): number
	local far = math.max(self.nearDist + 1, self.farDist)
	local t = math.clamp((dchunks - self.nearDist) / (far - self.nearDist), 0, 1)
	return self.nearOpsPerFrame + (self.farOpsPerFrame - self.nearOpsPerFrame) * t
end

-- Each chunk is delivered as a sub-folder named "C_cx_cy_cz" holding its MeshPart(s); freeing a
-- delivery = destroying that whole sub-folder.
local function removeChunkFolder(delivery: Instance, cx: number, cy: number, cz: number)
	local sub = delivery:FindFirstChild(string.format("C_%d_%d_%d", cx, cy, cz))
	if sub then
		sub:Destroy()
	end
end

export type Opts = {
	store: any,
	ensureWorld: (number, number, number) -> (), -- base + autowedge + saved edits for a chunk
	cy: number?,
	radius: number?, -- render distance in chunks
	deliveryFolderName: string?,
	ackTimeout: number?, -- seconds before re-attempting a delivery that was never acked
	nearDist: number?,
	farDist: number?,
	nearOpsPerFrame: number?,
	farOpsPerFrame: number?,
}

type PlayerState = {
	delivered: { [string]: number }, -- chunkKey -> os.clock() it was delivered (in PlayerGui, awaiting ack)
	captured: { [string]: boolean }, -- chunkKey -> true: client has its own clone; do not re-deliver
	folder: Instance?, -- the player's PlayerGui delivery folder
}

function ServerRenderStreamer.new(opts: Opts)
	local self = setmetatable({}, ServerRenderStreamer)
	self.store = opts.store
	self.ensureWorld = opts.ensureWorld
	self.cy = opts.cy or 0
	self.radius = opts.radius or 6
	self.deliveryFolderName = opts.deliveryFolderName or "VoxelDelivery"
	self.ackTimeout = opts.ackTimeout or 10
	self.nearDist = opts.nearDist or 2
	self.farDist = opts.farDist or 4
	self.nearOpsPerFrame = opts.nearOpsPerFrame or 2
	self.farOpsPerFrame = opts.farOpsPerFrame or 0.34

	self.players = {} :: { [Player]: PlayerState }
	self.queue = {} :: { { plr: Player, key: string, cx: number, cz: number, dist: number } }
	self.inQueue = {} :: { [string]: boolean } -- "userId|chunkKey"
	self.building = false
	self._opCredits = 1
	self._active = nil :: { cx: number, cz: number, plr: Player }?
	self._lastScan = 0
	self._conn = nil

	local mgr = self
	self._yielder = function()
		RunService.Heartbeat:Wait()
	end
	-- one credit per heavy AssetService op (bake + CreateMeshPartAsync); refilled by update()
	self._assetGate = function()
		while mgr._opCredits < 1 do
			RunService.Heartbeat:Wait()
		end
		mgr._opCredits -= 1
	end

	Players.PlayerRemoving:Connect(function(plr)
		mgr.players[plr] = nil -- PlayerGui (and the delivery folder under it) is destroyed with the player
	end)
	return self
end

function ServerRenderStreamer:_state(plr: Player): PlayerState
	local s = self.players[plr]
	if not s then
		s = { delivered = {}, captured = {}, folder = nil }
		self.players[plr] = s
	end
	return s
end

-- Player's chunk coords, or nil if no character yet.
function ServerRenderStreamer:_playerChunk(plr: Player): (number?, number?)
	local char = plr.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil, nil
	end
	local p = hrp.Position
	return math.floor(p.X / CHUNK_STUDS), math.floor(p.Z / CHUNK_STUDS)
end

-- Ensure + return the player's PlayerGui delivery folder (nil if PlayerGui isn't ready yet).
function ServerRenderStreamer:_folder(plr: Player): Instance?
	local s = self:_state(plr)
	if s.folder and s.folder.Parent then
		return s.folder
	end
	local pg = plr:FindFirstChild("PlayerGui")
	if not pg then
		return nil
	end
	local f = pg:FindFirstChild(self.deliveryFolderName)
	if not f then
		f = Instance.new("Folder")
		f.Name = self.deliveryFolderName
		f.Parent = pg
	end
	s.folder = f
	return f
end

-- The client cloned `key` into its own render set: free our delivery copy + mark captured.
function ServerRenderStreamer:onAck(plr: Player, key: string)
	local s = self.players[plr]
	if not s then
		return
	end
	if s.delivered[key] ~= nil then
		s.delivered[key] = nil
		local cx, cz = string.match(key, "(-?%d+)_(-?%d+)")
		if cx and s.folder then
			removeChunkFolder(s.folder, tonumber(cx) :: number, self.cy, tonumber(cz) :: number)
		end
	end
	s.captured[key] = true
end

-- A chunk's cells changed (edit/explosion): clear it everywhere so the scan re-delivers the new
-- version to every player who has it in range.
function ServerRenderStreamer:markDirty(cx: number, cz: number)
	local key = chunkKey(cx, cz)
	for _, s in self.players do
		s.captured[key] = nil
		if s.delivered[key] ~= nil then
			s.delivered[key] = nil
			if s.folder then
				removeChunkFolder(s.folder, cx, self.cy, cz)
			end
		end
	end
end

function ServerRenderStreamer:_enqueue(plr: Player, cx: number, cz: number)
	local q = plr.UserId .. "|" .. chunkKey(cx, cz)
	if self.inQueue[q] then
		return
	end
	self.inQueue[q] = true
	self.queue[#self.queue + 1] = { plr = plr, key = chunkKey(cx, cz), cx = cx, cz = cz, dist = 0 }
end

-- StorageLimitExceeded backstop: free the single oldest un-acked delivery across all players.
function ServerRenderStreamer:_freeOldest()
	local oldestS, oldestKey, oldestAt = nil, nil, math.huge
	for _, s in self.players do
		for key, at in s.delivered do
			if at < oldestAt then
				oldestAt, oldestKey, oldestS = at, key, s
			end
		end
	end
	if oldestKey and oldestS then
		oldestS.delivered[oldestKey] = nil
		local cx, cz = string.match(oldestKey, "(-?%d+)_(-?%d+)")
		if cx and oldestS.folder then
			removeChunkFolder(oldestS.folder, tonumber(cx) :: number, self.cy, tonumber(cz) :: number)
		end
	end
end

function ServerRenderStreamer:_buildOne(plr: Player, cx: number, cz: number)
	if not plr.Parent then
		return -- player left
	end
	local delivery = self:_folder(plr)
	if not delivery then
		return -- PlayerGui not ready; the scan will retry
	end
	self.ensureWorld(cx, self.cy, cz)
	-- Bake into an UNPARENTED per-chunk folder so the client never sees partial parts, then parent
	-- the complete folder in (atomic per-chunk replication -> the client clones it whole + acks once).
	local sub = Instance.new("Folder")
	sub.Name = string.format("C_%d_%d_%d", cx, self.cy, cz)
	local stats = Mesher.rebuildChunk(self.store, cx, self.cy, cz, sub, self._yielder, self._assetGate)
	if not plr.Parent then
		sub:Destroy()
		return -- player left mid-bake
	end
	if stats.storageLimited then
		sub:Destroy()
		self:_freeOldest()
		self:_enqueue(plr, cx, cz)
		return
	end
	if stats.parts == 0 then
		-- empty chunk (all air / fully buried): nothing to render. Mark captured so the scan does not
		-- keep re-baking it; no delivery + no ack needed.
		sub:Destroy()
		self:_state(plr).captured[chunkKey(cx, cz)] = true
		return
	end
	removeChunkFolder(delivery, cx, self.cy, cz) -- drop any stale delivery of this chunk
	sub.Parent = delivery
	self:_state(plr).delivered[chunkKey(cx, cz)] = os.clock()
end

function ServerRenderStreamer:_dispatch()
	if self.building or #self.queue == 0 or self._opCredits < 1 then
		return
	end
	-- nearest-first by each item's distance to ITS player
	for _, it in self.queue do
		local pcx, pcz = self:_playerChunk(it.plr)
		if pcx then
			local dx, dz = it.cx - pcx, it.cz - pcz
			it.dist = math.sqrt(dx * dx + dz * dz)
		else
			it.dist = math.huge
		end
	end
	table.sort(self.queue, function(a, b)
		return a.dist > b.dist -- nearest last, popped first
	end)
	local it = self.queue[#self.queue]
	self.queue[#self.queue] = nil
	self.inQueue[it.plr.UserId .. "|" .. it.key] = nil
	-- skip if no longer needed (player gone, or already captured / in flight)
	local s = self.players[it.plr]
	if not it.plr.Parent or (s and (s.captured[it.key] or s.delivered[it.key] ~= nil)) then
		return
	end
	self.building = true
	self._active = { cx = it.cx, cz = it.cz, plr = it.plr }
	task.spawn(function()
		local ok, err = pcall(function()
			self:_buildOne(it.plr, it.cx, it.cz)
		end)
		if not ok then
			warn("[ServerRenderStreamer] build error " .. it.key .. ": " .. tostring(err))
		end
		self.building = false
		self._active = nil
	end)
end

function ServerRenderStreamer:_update()
	-- refill the distance-adaptive credit bucket by the building chunk's distance to its player
	local a = self._active
	if a and a.plr.Parent then
		local pcx, pcz = self:_playerChunk(a.plr)
		if pcx then
			local dx, dz = a.cx - pcx, a.cz - pcz
			local rate = opsPerFrameFor(self, math.sqrt(dx * dx + dz * dz))
			self._opCredits = math.min(self._opCredits + rate, math.max(1, math.ceil(rate)))
		else
			self._opCredits = 1
		end
	else
		self._opCredits = 1
	end

	local now = os.clock()
	if now - self._lastScan >= 0.2 then -- ~5 Hz scan
		self._lastScan = now
		local r = self.radius
		for _, plr in Players:GetPlayers() do
			local pcx, pcz = self:_playerChunk(plr)
			if pcx then
				local s = self:_state(plr)
				-- re-attempt deliveries that were never acked within the timeout (laggy/dropped)
				for key, at in s.delivered do
					if now - at > self.ackTimeout then
						s.delivered[key] = nil
						local cx, cz = string.match(key, "(-?%d+)_(-?%d+)")
						if cx and s.folder then
							removeChunkFolder(s.folder, tonumber(cx) :: number, self.cy, tonumber(cz) :: number)
						end
					end
				end
				-- enqueue render-set chunks the client doesn't have and aren't in flight
				for dx = -r, r do
					for dz = -r, r do
						if dx * dx + dz * dz <= r * r then
							local cx, cz = pcx + dx, pcz + dz
							local key = chunkKey(cx, cz)
							if not s.captured[key] and s.delivered[key] == nil then
								self:_enqueue(plr, cx, cz)
							end
						end
					end
				end
			end
		end
	end

	self:_dispatch()
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
