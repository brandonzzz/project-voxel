--!strict
--[[
	VoxelServer — authoritative edit owner.

	The base terrain is deterministic f(seed) (the client computes the same), so
	the server only owns + replicates the sparse EDIT overlay. It validates edit /
	explosion requests (reach check), applies them to its authoritative store
	(lazily generating base terrain for touched chunks), and broadcasts the
	resulting deltas to all clients. Clients apply the deltas and dirty-rebuild.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local Lib = ReplicatedStorage:WaitForChild("LegacyVoxelTerrain")
local VoxelStore = require(Lib:WaitForChild("VoxelStore"))
local WorldGen = require(Lib:WaitForChild("WorldGen"))
local EditService = require(Lib:WaitForChild("EditService"))
local Constants = require(Lib:WaitForChild("Constants"))
local PersistenceService = require(Lib:WaitForChild("PersistenceService"))

local CELL = Constants.CELL
local REACH = 90 -- studs; max distance a player may edit from

-- Remotes ------------------------------------------------------------------
local remotes = Instance.new("Folder")
remotes.Name = "VoxelRemotes"
local EditDeltas = Instance.new("RemoteEvent")
EditDeltas.Name = "EditDeltas"
EditDeltas.Parent = remotes
local RequestEdit = Instance.new("RemoteEvent")
RequestEdit.Name = "RequestEdit"
RequestEdit.Parent = remotes
local RequestExplode = Instance.new("RemoteEvent")
RequestExplode.Name = "RequestExplode"
RequestExplode.Parent = remotes
-- Pull the full edit overlay synchronously at join, BEFORE the client streams, so each chunk's
-- first render already includes edits (no base-then-edit pop-in).
local GetOverlay = Instance.new("RemoteFunction")
GetOverlay.Name = "GetOverlay"
GetOverlay.Parent = remotes
remotes.Parent = ReplicatedStorage

-- Authoritative state -------------------------------------------------------
local store = VoxelStore.new()
local gen = WorldGen.new(Constants.WORLD_SEED)
local generated: { [string]: boolean } = {}
local function ensureGen(cx: number, cy: number, cz: number)
	local k = string.format("%d_%d_%d", cx, cy, cz)
	if not generated[k] then
		gen:fillChunk(store, cx, cy, cz)
		generated[k] = true
	end
end

-- Edit overlay (sparse): { [chunkKey "cx_cy_cz"] = { [cellIndex] = value } }. This is what
-- gets persisted; the base is f(seed). Declared here so ensureWorld can re-apply it.
local overlay: { [string]: { [number]: number } } = {}

-- A chunk's FINAL authoritative state = base -> deterministic autowedge -> saved edits.
-- The autowedge is material-based and matches every client, so it is NOT recorded as an
-- edit. Saved/edited voxels are re-applied AFTER autowedge, so a modified voxel always keeps
-- its exact stored shape -- autowedge can never reshape it, and lazy base-gen can never
-- clobber it. Neighbour bases are ensured first so border cells wedge correctly. Run this
-- BEFORE applying any new edit, so the autowedge only ever sees base terrain. --
local wedged: { [string]: boolean } = {}
local function ensureWorld(cx: number, cy: number, cz: number)
	ensureGen(cx, cy, cz)
	local k = string.format("%d_%d_%d", cx, cy, cz)
	if wedged[k] then
		return
	end
	for dx = -1, 1 do
		for dz = -1, 1 do
			ensureGen(cx + dx, cy, cz + dz)
		end
	end
	local C = Constants.CHUNK
	EditService.autowedgeRegion(store, cx * C, cy * C, cz * C, cx * C + C - 1, cy * C + C - 1, cz * C + C - 1)
	local edits = overlay[k]
	if edits then
		for idx, value in edits do
			local lx = idx % C
			local lz = math.floor(idx / C) % C
			local ly = math.floor(idx / (C * C))
			store:setCell(cx * C + lx, cy * C + ly, cz * C + lz, Constants.unpackCell(value))
		end
	end
	wedged[k] = true
end

-- Server-side collision streamer (assigned near the bottom once its module + deps exist).
-- Forward-declared here so the edit / explosion handlers can mark its chunks dirty.
local streamer: any = nil

local function recordEdit(wx: number, wy: number, wz: number, value: number)
	local cx, lx = VoxelStore.worldToChunk(wx)
	local cy, ly = VoxelStore.worldToChunk(wy)
	local cz, lz = VoxelStore.worldToChunk(wz)
	local key = string.format("%d_%d_%d", cx, cy, cz)
	local chunkEdits = overlay[key]
	if not chunkEdits then
		chunkEdits = {}
		overlay[key] = chunkEdits
	end
	chunkEdits[VoxelStore.localIndex(lx, ly, lz)] = value
end

local function withinReach(player: Player, wx: number, wy: number, wz: number): boolean
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return false
	end
	local center = Vector3.new((wx + 0.5) * CELL, (wy + 0.5) * CELL, (wz + 0.5) * CELL)
	return (center - hrp.Position).Magnitude <= REACH
end

local function asInt(v: any): number?
	return typeof(v) == "number" and math.floor(v) or nil
end

RequestEdit.OnServerEvent:Connect(function(player, wx, wy, wz, material, byte1)
	wx, wy, wz = asInt(wx), asInt(wy), asInt(wz)
	material, byte1 = asInt(material), asInt(byte1)
	if not (wx and wy and wz and material and byte1) then
		return
	end
	material = math.clamp(material, 0, Constants.MAX_MATERIAL)
	byte1 = math.clamp(byte1, 0, 255)
	if not withinReach(player, wx, wy, wz) then
		return
	end
	local cx = VoxelStore.worldToChunk(wx)
	local cy = VoxelStore.worldToChunk(wy)
	local cz = VoxelStore.worldToChunk(wz)
	ensureWorld(cx, cy, cz) -- base+autowedge+existing edits first, so this edit lands on top
	local delta = EditService.applyEdit(store, wx, wy, wz, material, byte1)
	recordEdit(delta[1], delta[2], delta[3], delta[4])
	EditDeltas:FireAllClients({ delta })
	if streamer then
		for _, c in EditService.affectedChunks(delta[1], delta[2], delta[3]) do
			streamer:markDirty(c.cx, c.cy, c.cz)
		end
	end
end)

-- Carve a crater, re-autowedge its rim, and broadcast the deltas. Shared by the player
-- explode tool and by auto-detected Explosion instances; callers do their own validation.
local function detonate(wx: number, wy: number, wz: number, radius: number)
	radius = math.clamp(radius, 1, 8)
	-- Prepare the whole crater region FIRST (base + deterministic autowedge + existing saved
	-- edits), expanded by 1 + a chunk ring so border neighbour reads are valid. Doing this
	-- before the carve means the general autowedge only ever sees base terrain (never the
	-- fresh crater), so it stays identical to what clients compute.
	local r = math.ceil(radius)
	local minX, minY, minZ = wx - r - 1, wy - r - 1, wz - r - 1
	local maxX, maxY, maxZ = wx + r + 1, wy + r + 1, wz + r + 1
	local c0x = VoxelStore.worldToChunk(minX - 1)
	local c1x = VoxelStore.worldToChunk(maxX + 1)
	local c0y = VoxelStore.worldToChunk(minY - 1)
	local c1y = VoxelStore.worldToChunk(maxY + 1)
	local c0z = VoxelStore.worldToChunk(minZ - 1)
	local c1z = VoxelStore.worldToChunk(maxZ + 1)
	for ccx = c0x, c1x do
		for ccy = c0y, c1y do
			for ccz = c0z, c1z do
				ensureWorld(ccx, ccy, ccz)
			end
		end
	end

	-- Carve, then re-autowedge the blasted rim so edges slope. The rim slope cells become
	-- RECORDED edits that replicate with the carve, so clients apply them directly.
	local deltas = EditService.explode(store, ensureGen, wx, wy, wz, radius)
	for _, d in deltas do
		recordEdit(d[1], d[2], d[3], d[4])
	end
	local wedgeDeltas = EditService.autowedgeRegion(store, minX, minY, minZ, maxX, maxY, maxZ)
	for _, d in wedgeDeltas do
		recordEdit(d[1], d[2], d[3], d[4])
		deltas[#deltas + 1] = d
	end

	EditDeltas:FireAllClients(deltas)
	if streamer then
		for ccx = c0x, c1x do
			for ccy = c0y, c1y do
				for ccz = c0z, c1z do
					streamer:markDirty(ccx, ccy, ccz)
				end
			end
		end
	end
end

RequestExplode.OnServerEvent:Connect(function(player, wx, wy, wz, radius)
	wx, wy, wz = asInt(wx), asInt(wy), asInt(wz)
	if not (wx and wy and wz) then
		return
	end
	radius = math.clamp(typeof(radius) == "number" and radius or 3, 1, 8)
	if not withinReach(player, wx, wy, wz) then
		return
	end
	detonate(wx, wy, wz, radius)
end)

-- Auto-detect Roblox Explosion instances and carve a matching crater. An Explosion
-- detonates the instant it is parented into the workspace, so a DescendantAdded hook
-- catches it (and exposes its Position + BlastRadius immediately). Per-instance control:
-- set the Explosion's "TerrainDamage" attribute (a bool) -- absent attribute defaults to
-- damaging terrain (legacy destructible feel); set it to false to spare the terrain.
local EXPLOSION_DAMAGES_TERRAIN_DEFAULT = true
local function onExplosion(exp: Explosion)
	local flag = exp:GetAttribute("TerrainDamage")
	local damages = if flag == nil then EXPLOSION_DAMAGES_TERRAIN_DEFAULT else flag == true
	if not damages then
		return
	end
	local pos = exp.Position
	detonate(
		math.floor(pos.X / CELL),
		math.floor(pos.Y / CELL),
		math.floor(pos.Z / CELL),
		math.max(1, math.round(exp.BlastRadius / CELL))
	)
end
workspace.DescendantAdded:Connect(function(inst)
	if inst:IsA("Explosion") then
		onExplosion(inst)
	end
end)

-- Data-driven no-clip ---------------------------------------------------------
-- The voxel data is authoritative even where collision parts have not streamed in yet, so a
-- character can pass straight through solid terrain. This catches that purely from voxel OCCUPANCY:
-- if the character's centre cell is a FULL solid cube -- a cell it could only be inside by clipping --
-- lift it out onto the top of that solid stack. It makes NO world-space surface assumption (no "below
-- y = surface", no void plane), so every empty-cell state -- standing on terrain, resting in a carved
-- hole, swimming, or falling down a hole dug clean through to the void -- is left untouched. Only
-- moving THROUGH solid voxels triggers it, in ANY direction, at ANY chunk height (cy-agnostic, so it
-- already works once vertical chunks stream in). Water + slopes/wedges are not "solid" (a swimmer or a
-- body resting against a ramp must never read as embedded).
local RunService = game:GetService("RunService")
local WATER = Constants.Material.Water
local SOLID_SHAPE = Constants.Shape.Solid

-- Is world cell (wx,wy,wz) a FULL solid cube in the CURRENT world data? Reads the live server store
-- (the streamer + edit handlers keep the player's region final: base + autowedge + saved edits). It
-- does NOT generate: an ungenerated cell -- the void below the world, the sky above, terrain not yet
-- streamed -- reads Empty, so it is never "solid". That is exactly what lets a player fall through a
-- hole dug clean to the void instead of being yanked back, with no world-space surface/void-plane
-- assumption anywhere (cy-agnostic; once vertical chunks stream in their solid cells just read solid).
local function cellIsSolid(wx: number, wy: number, wz: number): boolean
	local m, b = store:getCell(wx, wy, wz)
	return m ~= 0 and m ~= WATER and Constants.unpackByte1(b) == SOLID_SHAPE
end

local MAX_PUSH = 64 -- cells: safety bound on the "scan up to the solid's top" resolve
local clipAccum = 0
-- 2 consecutive embedded reads before acting, so a 1-frame physics overshoot into a cube does not
-- yank a character that the engine would have resolved on its own.
local clipStreak: { [Player]: number } = {}
RunService.Heartbeat:Connect(function(dt)
	clipAccum += dt
	if clipAccum < 0.1 then -- ~10 Hz
		return
	end
	clipAccum = 0
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hrp and hum and hum.Health > 0 then
			local p = hrp.Position
			local cellX = math.floor(p.X / CELL)
			local cellY = math.floor(p.Y / CELL)
			local cellZ = math.floor(p.Z / CELL)
			if cellIsSolid(cellX, cellY, cellZ) then -- centre inside a solid cube => clipped through terrain
				clipStreak[player] = (clipStreak[player] or 0) + 1
				if clipStreak[player] >= 2 then
					-- resolve upward: stand the character on top of the solid stack it is inside
					local topY, n = cellY, 0
					while n < MAX_PUSH and cellIsSolid(cellX, topY + 1, cellZ) do
						topY += 1
						n += 1
					end
					hrp.CFrame = CFrame.new(p.X, (topY + 1) * CELL + 3.5, p.Z)
					hrp.AssemblyLinearVelocity = Vector3.zero
					clipStreak[player] = 0
				end
			else
				clipStreak[player] = 0 -- in air / water / a hole / the void => never touched
			end
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	clipStreak[player] = nil
end)

-- Persistence: region-sharded edit overlay in a DataStore --------------------
local editDS: any = nil
local dsReady = false
do
	local ok, ds = pcall(function()
		return DataStoreService:GetDataStore("VoxelEdits_v1")
	end)
	editDS = ok and ds or nil
end

local function save(): number
	if not editDS then
		return 0
	end
	local regions: { [string]: { rx: number, rz: number } } = {}
	for chunkKey in overlay do
		local cx, _, cz = string.match(chunkKey, "(-?%d+)_(-?%d+)_(-?%d+)")
		local rx, rz = PersistenceService.regionOf(tonumber(cx) :: number, tonumber(cz) :: number)
		regions[PersistenceService.regionKey(rx, rz)] = { rx = rx, rz = rz }
	end
	local saved = 0
	local index = {}
	for rkey, r in regions do
		index[#index + 1] = rkey
		local data = PersistenceService.serializeRegion(overlay, r.rx, r.rz)
		if pcall(function()
			editDS:SetAsync(rkey, data)
		end) then
			saved += 1
		end
	end
	pcall(function()
		editDS:SetAsync("regions_index", index)
	end)
	dsReady = true
	return saved
end

local function load()
	if not editDS then
		return
	end
	local ok, index = pcall(function()
		return editDS:GetAsync("regions_index")
	end)
	if not ok or type(index) ~= "table" then
		dsReady = true
		return
	end
	for _, rkey in index do
		local ok2, data = pcall(function()
			return editDS:GetAsync(rkey)
		end)
		if ok2 and type(data) == "table" then
			-- populate the overlay ONLY (no store write): ensureWorld re-applies these AFTER
			-- autowedge, so loaded edits never feed into the autowedge pass.
			for _, d in PersistenceService.decodeRegion(data) do
				recordEdit(d[1], d[2], d[3], d[4])
			end
		end
	end
	dsReady = true
end

-- Flatten the overlay into a delta list for replicating existing edits to joiners.
local function overlayDeltas(): { { number } }
	local out: { { number } } = {}
	for chunkKey, edits in overlay do
		local cx, cy, cz = string.match(chunkKey, "(-?%d+)_(-?%d+)_(-?%d+)")
		local cxi, cyi, czi = tonumber(cx) :: number, tonumber(cy) :: number, tonumber(cz) :: number
		for idx, val in edits do
			local lx = idx % Constants.CHUNK
			local lz = math.floor(idx / Constants.CHUNK) % Constants.CHUNK
			local ly = math.floor(idx / (Constants.CHUNK * Constants.CHUNK))
			out[#out + 1] = { cxi * Constants.CHUNK + lx, cyi * Constants.CHUNK + ly, czi * Constants.CHUNK + lz, val }
		end
	end
	return out
end

-- Client calls this once at startup (before it streams) to get all existing edits up front,
-- so the first render of each chunk includes them. Waits (bounded) for the datastore load.
GetOverlay.OnServerInvoke = function(_player)
	local t0 = os.clock()
	while not dsReady and os.clock() - t0 < 5 do
		task.wait(0.1)
	end
	return overlayDeltas()
end

-- Backup for any edits made during the join window (also covers an old client that doesn't
-- call GetOverlay): re-broadcast the overlay shortly after join; the client applies + rebuilds.
Players.PlayerAdded:Connect(function(player)
	task.wait(2) -- let the client's EditDeltas listener come up
	local d = overlayDeltas()
	if #d > 0 then
		EditDeltas:FireClient(player, d)
	end
end)

task.spawn(function()
	while true do
		task.wait(60)
		save()
	end
end)
game:BindToClose(function()
	save()
end)

load()
remotes:SetAttribute("ready", true)

-- Server-side terrain collision -------------------------------------------------
-- The server has no render meshes, so without this server-simulated parts (loose debris
-- before a client takes ownership, scripted objects) would fall through the terrain. Stream
-- the same boxes+wedges collision the client builds, around the players, into its own group.
local PhysicsService = game:GetService("PhysicsService")
local SERVER_TERRAIN_GROUP = "VoxelServerTerrain"
pcall(function()
	PhysicsService:RegisterCollisionGroup(SERVER_TERRAIN_GROUP)
end)
-- Ownership-aware loose-part collision: a CLIENT-owned loose assembly goes in "LooseClient",
-- which is made NON-collidable with the server terrain, so on the owning client it rests on
-- that client's own collision and ignores the coincident replicated server collision. Server-
-- owned assemblies stay in Default and collide with the server terrain. (See LoosePartManager.)
pcall(function()
	PhysicsService:RegisterCollisionGroup("LooseClient")
	PhysicsService:CollisionGroupSetCollidable("LooseClient", SERVER_TERRAIN_GROUP, false)
end)

-- SavePlaceAsync safety: a saved place can carry a stale VoxelServerCollision folder. Streamed
-- terrain collision is transient -- it's regenerated from the seed + datastore overlay and is
-- never authoritative -- so clear it on startup and let the streamer rebuild from a clean
-- loaded set. Only this terrain-collision folder is cleared; loose + anchored game parts live
-- elsewhere and are deliberately left untouched (terrain itself defers to datastore/seed).
do
	local stale = workspace:FindFirstChild("VoxelServerCollision")
	while stale do
		stale:Destroy()
		stale = workspace:FindFirstChild("VoxelServerCollision")
	end
end

local serverCollision = Instance.new("Folder")
serverCollision.Name = "VoxelServerCollision"
serverCollision.Parent = workspace

-- Loose-part streaming: park loose assemblies in ServerStorage (indexed by chunk directory)
-- when their chunk's collision unloads; return them when it loads. At startup, park ALL loose
-- objects so nothing rests over un-collided terrain -- the streamer restores each as its chunk
-- loads. This also "respects" loose parts carried in by a saved place.
local LoosePartManager = require(script.Parent:WaitForChild("LoosePartManager"))
LoosePartManager.stowAll()

local ServerChunkStreamer = require(script.Parent:WaitForChild("ServerChunkStreamer"))
streamer = ServerChunkStreamer.new({
	store = store,
	ensureWorld = ensureWorld,
	container = serverCollision,
	collisionGroup = SERVER_TERRAIN_GROUP,
	cy = 0,
	radius = 4,
	-- Loose parts rest on the cy=0 surface, so only swap them for the cy=0 band of the 3D stream.
	onChunkLoaded = function(cx: number, cy: number, cz: number)
		if cy == 0 then
			LoosePartManager.restoreChunk(cx, cz)
		end
	end,
	onChunkUnloaded = function(cx: number, cy: number, cz: number)
		if cy == 0 then
			LoosePartManager.stowChunk(cx, cz)
		end
	end,
	expandFn = LoosePartManager.expandLoaded, -- SC4: pull in cy=0 chunks loose assemblies span into
})
streamer:start()

-- Periodic loose-part upkeep: park orphans (no collision under them) and keep each assembly's
-- collision group in step with its network owner (client vs server).
task.spawn(function()
	while true do
		task.wait(0.5)
		LoosePartManager.stowOrphans(function(cx: number, cz: number): boolean
			return streamer:isLoaded(cx, 0, cz) -- loose-part home chunks are on the cy=0 surface
		end)
		LoosePartManager.updateOwnershipGroups()
	end
end)
