--!strict
-- Legacy Voxel Terrain -- Copyright (c) 2026 RBLX Classic. All rights reserved. Proprietary.
-- No copying, redistribution, or derivative works without written permission. Unauthorized use
-- is copyright infringement and will be reported to Roblox under the DMCA.
-- [RECOVERED 2026-09-17 after the Studio place file was lost. Save-options + boot sections are
--  verbatim from the session transcript; the untouched middle is the pre-refactor src VoxelServer
--  body. See RECOVERY.md for fidelity tiers and known gaps (notably the explosion `reshape` flag,
--  which is NOT recovered here because it spanned shared modules held only as prose in memory).]

--[==[
	TerrainServer -- the terrain server runtime. Its body was moved VERBATIM out of VoxelServer into
	Load() (double-load guarded). Initialize() runs universal boot safety at server start; Load()
	resolves saveType + persistence and streams the terrain. ManualLoader calls Initialize() at server
	start and Load() on a /load or /preview command.
]==]

local TerrainServer = {}
local booted = false -- TerrainServer.Initialize() has run (universal boot safety)
local loaded = false -- TerrainServer.Load() completed its resolve (terrain load)

-- Universal boot safety -- call this immediately at server start, regardless of whether/how/when the
-- terrain loads. A saved/built place can boot with loose parts (saved into the place) and a stale
-- terrain-collision folder physically present that the module doesn't track. This stows the loose
-- parts off the workspace and clears the stale collision so nothing falls into the void before Load()
-- streams real collision. It runs inside the FIRST RunService.PreSimulation callback, which fires
-- before the first physics step (verified: loose parts still read zero velocity at that point), so
-- parts are parked before gravity is ever applied.
function TerrainServer.Initialize()
	if booted then
		return
	end
	booted = true

	local RunService = game:GetService("RunService")
	local LoosePartManager = require(script.Parent:WaitForChild("LoosePartManager"))
	local conn
	conn = RunService.PreSimulation:Connect(function()
		conn:Disconnect()
		-- Park every loose part into ServerStorage keyed by chunk (off the workspace). Load()'s streamer
		-- restores each as its chunk loads. This also "adopts" loose parts carried in by a save.
		LoosePartManager.stowAll()
		-- Discard any stale VoxelServerCollision a saved place carried in; it's transient (regenerated
		-- from seed + overlay, never authoritative) and Load() rebuilds it from a clean loaded set. Guard
		-- on `loaded`: only clear while the terrain is still unloaded. If Load() already ran (a caller
		-- invoked it in the same frame, before this callback), that folder is live collision, not stale --
		-- leave it alone. In the normal flow Load() happens seconds later, so `loaded` is false here.
		if not loaded then
			local stale = workspace:FindFirstChild("VoxelServerCollision")
			while stale do
				stale:Destroy()
				stale = workspace:FindFirstChild("VoxelServerCollision")
			end
		end
	end)
end

-- Terrain load -- resolves saveType/persistence and streams the terrain. Called by ManualLoader on a
-- /load or /preview command (gated by saveType). Initialize() must have run first, at server start.
function TerrainServer.Load()
	if loaded then
		return
	end

	-- [saveType] Resolve persistence BEFORE any side effects, so a misconfigured world refuses cleanly
	-- (and can be retried). saveType/customKey are server-only in ServerStorage.WorldConstants. dsKey==""
	-- selects the Null backend (generates + streams, never persists); a non-empty dsKey scopes a DataStore.
	local WorldConstants = game.ServerStorage:WaitForChild("WorldConstants")
	local saveType = WorldConstants.saveType.Value
	local customKey = WorldConstants.customKey.Value
	local shouldInit, dsKey, readOnly, backendKind = false, "", false, "auto" -- backendKind "place" => SavePlaceAsync
	if saveType == "None" then
		shouldInit = true -- generates + streams, never persists
	elseif saveType == "PrivateServer" then
		shouldInit, dsKey = true, game.PrivateServerId -- "" in a public server => Null (loads, no save)
	elseif saveType == "Custom" then
		if customKey ~= "" then shouldInit, dsKey = true, customKey end -- else refuse: Custom needs a key
	elseif saveType == "Preview" then
		if customKey ~= "" then shouldInit, dsKey, readOnly = true, customKey, true end -- loads read-only
	elseif saveType == "SavePlaceAsync" then
		shouldInit, backendKind = true, "place" -- persists the edit overlay into the place via SavePlaceAsync
	end
	if not shouldInit then
		warn(string.format("[TerrainServer] refusing to load -- saveType=%q customKey=%q", saveType, customKey))
		return -- loaded stays false: fix the config and call Load again
	end
	loaded = true

--!strict
--[[
	Legacy Voxel Terrain
	Copyright (c) 2026 RBLX Classic. All rights reserved.

	Proprietary and confidential. This source, and the system it implements, are the original
	work of the copyright holder. No permission is granted to copy, redistribute, republish,
	sublicense, or create derivative works from it, in whole or in part, without prior written
	permission. Unauthorized use is copyright infringement and will be reported to Roblox under
	the DMCA. Ownership enquiries: contact the RBLX Classic group owner on Roblox.
]]

--[[
	VoxelServer — authoritative store owner: persistence, collision streaming, data-driven no-clip.

	The base terrain is deterministic f(seed) (every client computes the same). The server owns the
	sparse EDIT overlay (persisted only in private servers), carves craters under Explosion instances,
	streams terrain collision around players for server-simulated parts, and resolves no-clip from voxel
	occupancy. Edits are applied through the LegacyVoxelTerrain API (which updates the store + overlay).

	Replication is server -> client ONLY (the client has no authority -- it cannot request edits):
	  EditDeltas (RemoteEvent)   - server pushes edit deltas to clients, which apply + dirty-rebuild.
	  GetOverlay (RemoteFunction) - read-only: a joining client pulls the full overlay before it streams
	                                so its first render already includes edits (race-free vs a push).
	There are no client->server EDIT remotes: edits originate only on the server (the API + explosions).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local Lib = ReplicatedStorage:WaitForChild("LegacyVoxelTerrain")
local VoxelStore = require(Lib:WaitForChild("VoxelStore"))
local WorldGen = require(Lib:WaitForChild("WorldGen"))
local EditService = require(Lib:WaitForChild("EditService"))
local Constants = require(Lib:WaitForChild("Constants"))
local PersistenceService = require(script.Parent:WaitForChild("PersistenceService")) -- server-only (moved out of ReplicatedStorage)

local CELL = Constants.CELL

-- Sync remotes (server -> client only) --------------------------------------
-- The ONLY remotes the system creates, and both are purely for syncing clients to the server's
-- authoritative state -- no client->server edit path exists. Children are parented first, then the
-- folder, so a client's WaitForChild("VoxelRemotes") sees a complete folder.
local remotes = Instance.new("Folder")
remotes.Name = "VoxelRemotes"
remotes.Archivable = false -- runtime infra: excluded from SavePlaceAsync so it isn't duplicated on reload
local EditDeltas = Instance.new("RemoteEvent") -- server broadcasts edit deltas; clients apply + rebuild
EditDeltas.Name = "EditDeltas"
EditDeltas.Parent = remotes
local GetOverlay = Instance.new("RemoteFunction") -- read-only: client pulls the full overlay at join
GetOverlay.Name = "GetOverlay"
GetOverlay.Parent = remotes
remotes.Parent = ReplicatedStorage

-- Authoritative state -------------------------------------------------------
local store = VoxelStore.new()
-- Generation authority: ReplicatedStorage.TerrainConfig (client-readable so both sides agree on
-- deterministic f(seed)). saveType/customKey stay server-only in ServerStorage.WorldConstants.
local TerrainConfig = ReplicatedStorage:WaitForChild("TerrainConfig")
local gen = WorldGen.new(TerrainConfig.seed.Value, {
	type = TerrainConfig.type.Value,
	period = TerrainConfig.period.Value,
	amplitude = TerrainConfig.amplitude.Value,
	flatHeight = TerrainConfig.flatHeight.Value,
})
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

-- Carve a crater and re-autowedge its rim, applying it to the authoritative store + overlay.
-- Triggered by auto-detected Explosion instances. (No client broadcast: there are no remotes.)
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
	-- RECOVERY GAP (Tier 3): the live Studio build passed a trailing `reshape=true` here (2026-07-25,
	-- Studio-only) so crater-RIM cells that were ALREADY wedges get re-derived from current neighbours.
	-- That change threaded a `reshape` param through EditService.autowedgeRegion -> Autowedge.region ->
	-- Autowedge.decide, none of which are in this src snapshot. This call is the pre-reshape src version;
	-- re-apply the reshape flag AND its shared-module plumbing per RECOVERY.md before trusting explosions.
	local wedgeDeltas = EditService.autowedgeRegion(store, minX, minY, minZ, maxX, maxY, maxZ)
	for _, d in wedgeDeltas do
		recordEdit(d[1], d[2], d[3], d[4])
		deltas[#deltas + 1] = d
	end

	EditDeltas:FireAllClients(deltas) -- replicate the crater + rim so clients render it
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

-- Persistence: swappable backend (DataStore / Null / SavePlaceAsync) ----------
local dsReady = false -- set once the initial load finishes, so GetOverlay can wait for it

local function makeDataStoreBackend(key: string, ro: boolean)
	local ds: any = nil
	local ok, res = pcall(function()
		return DataStoreService:GetDataStore("VoxelEdits_v1", key) -- scope = this save key
	end)
	ds = ok and res or nil
	local b = {}
	function b.load()
		if not ds then
			return
		end
		local ok2, index = pcall(function()
			return ds:GetAsync("regions_index")
		end)
		if not ok2 or type(index) ~= "table" then
			return
		end
		for _, rkey in index do
			local ok3, data = pcall(function()
				return ds:GetAsync(rkey)
			end)
			if ok3 and type(data) == "table" then
				-- populate the overlay ONLY (no store write): ensureWorld re-applies these AFTER
				-- autowedge, so loaded edits never feed into the autowedge pass.
				for _, d in PersistenceService.decodeRegion(data) do
					recordEdit(d[1], d[2], d[3], d[4])
				end
			end
		end
	end
	function b.save(): number
		if not ds or ro then
			return 0 -- Preview (read-only) loads its world but never writes
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
				ds:SetAsync(rkey, data)
			end) then
				saved += 1
			end
		end
		pcall(function()
			ds:SetAsync("regions_index", index)
		end)
		return saved
	end
	function b.close()
		b.save() -- close = final flush to the DataStore
	end
	b.saveInterval = if ro then 0 else 60 -- Preview (ro) never autosaves; others flush every 60s
	return b
end

local function makeNullBackend()
	local b = {}
	function b.load() end
	function b.save(): number
		return 0
	end
	function b.close() end
	b.saveInterval = 0 -- nothing to persist; skip the autosave loop
	return b
end

-- SavePlaceAsync backend: base terrain is f(seed), so only the sparse EDIT overlay is persisted -- but
-- into the PLACE itself, not a DataStore. It's serialized (region-sharded, same encoding as the
-- DataStore backend) into StringValues under ServerStorage.VoxelPlaceSave, then AssetService:
-- SavePlaceAsync() snapshots the whole DataModel (incl. those StringValues + placed loose parts) back
-- to the place. On the next boot those StringValues are already present, so load() reads them directly
-- -- no DataStore. Transient runtime instances (VoxelServerCollision, VoxelRemotes) are Archivable=false
-- so they're excluded from the snapshot; player character models are Archivable=false by default.
-- NOTE: SavePlaceAsync only works on a published server with the place setting enabled (or a
-- CreatePlaceAsync-owned place); it errors in Studio, which the pcall in b.save tolerates.
local function makePlaceBackend()
	local AssetService = game:GetService("AssetService")
	local HttpService = game:GetService("HttpService")
	local ServerStorage = game:GetService("ServerStorage")
	local SAVE_FOLDER = "VoxelPlaceSave"

	local function saveFolder(): Folder
		local f = ServerStorage:FindFirstChild(SAVE_FOLDER)
		if not f then
			f = Instance.new("Folder")
			f.Name = SAVE_FOLDER
			f.Parent = ServerStorage
		end
		return f :: Folder
	end

	local b = {}

	function b.load()
		local f = ServerStorage:FindFirstChild(SAVE_FOLDER)
		if not f then
			return
		end
		for _, sv in f:GetChildren() do
			if sv:IsA("StringValue") and sv.Value ~= "" then
				local ok, data = pcall(function()
					return HttpService:JSONDecode(sv.Value)
				end)
				if ok and type(data) == "table" then
					-- overlay only (no store write): ensureWorld re-applies these AFTER autowedge.
					for _, d in PersistenceService.decodeRegion(data) do
						recordEdit(d[1], d[2], d[3], d[4])
					end
				end
			end
		end
	end

	-- Sync the StringValue container to the current overlay (one StringValue per region). --
	local function writeRegions(): number
		local f = saveFolder()
		local regions: { [string]: { rx: number, rz: number } } = {}
		for chunkKey in overlay do
			local cx, _, cz = string.match(chunkKey, "(-?%d+)_(-?%d+)_(-?%d+)")
			local rx, rz = PersistenceService.regionOf(tonumber(cx) :: number, tonumber(cz) :: number)
			regions[PersistenceService.regionKey(rx, rz)] = { rx = rx, rz = rz }
		end
		-- prune StringValues for regions that no longer carry edits
		for _, sv in f:GetChildren() do
			if sv:IsA("StringValue") and not regions[sv.Name] then
				sv:Destroy()
			end
		end
		local n = 0
		for rkey, r in regions do
			local data = PersistenceService.serializeRegion(overlay, r.rx, r.rz)
			local sv = f:FindFirstChild(rkey)
			if not (sv and sv:IsA("StringValue")) then
				sv = Instance.new("StringValue")
				sv.Name = rkey
				sv.Parent = f
			end
			local svv = sv :: StringValue
			svv.Value = HttpService:JSONEncode(data)
			n += 1
		end
		return n
	end

	function b.save(): number
		local n = writeRegions()
		-- The saved place must boot UN-initialized so clients wait for the server's Load() to finish
		-- (isInitialized is live-true now). Flip it false just for the snapshot, then restore live state.
		local wasInit = TerrainConfig.isInitialized.Value
		TerrainConfig.isInitialized.Value = false
		local ok, err = pcall(function()
			AssetService:SavePlaceAsync()
		end)
		TerrainConfig.isInitialized.Value = wasInit
		if not ok then
			warn("[TerrainServer] SavePlaceAsync failed (needs a published server + the place setting enabled): " .. tostring(err))
		end
		return n
	end

	function b.close()
		b.save()
	end

	b.saveInterval = 300 -- SavePlaceAsync is rate-limited + heavy; autosave every 5 min
	return b
end

local backend = if backendKind == "place" then makePlaceBackend()
	elseif dsKey ~= "" then makeDataStoreBackend(dsKey, readOnly)
	else makeNullBackend()

local function save(): number
	return backend.save()
end

local function load()
	backend.load()
	dsReady = true -- signal GetOverlay regardless of whether there was anything to load
end

-- Flatten the overlay into a delta list {wx,wy,wz,value} for replicating existing edits to joiners.
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

-- READ-ONLY pull: a joining client calls this once at startup (before it streams) to get all existing
-- edits up front, so the first render of each chunk already includes them. Waits (bounded) for the
-- datastore load. It returns server state only -- it grants the client no authority.
GetOverlay.OnServerInvoke = function(_player)
	local t0 = os.clock()
	while not dsReady and os.clock() - t0 < 5 do
		task.wait(0.1)
	end
	return overlayDeltas()
end

-- Backup for edits made during the join window (and any client whose GetOverlay pull raced the
-- listener): push the current overlay to the joiner shortly after join; applying it is idempotent.
Players.PlayerAdded:Connect(function(player)
	task.wait(2) -- let the client's EditDeltas listener come up
	local d = overlayDeltas()
	if #d > 0 then
		EditDeltas:FireClient(player, d)
	end
end)

if backend.saveInterval and backend.saveInterval > 0 then
	task.spawn(function()
		while true do
			task.wait(backend.saveInterval)
			save()
		end
	end)
end
game:BindToClose(function()
	backend.close()
end)

load()

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

-- Loose-part stowing and stale-collision clearing moved to TerrainServer.Initialize() (run at server
-- start, before the first physics step) so a saved place's parts are parked before they can fall.
-- Here we only need the manager for the streamer's per-chunk restore/stow below, plus a fresh, empty
-- collision folder for the streamer to fill (Initialize already cleared any stale one).
local LoosePartManager = require(script.Parent:WaitForChild("LoosePartManager"))

local serverCollision = Instance.new("Folder")
serverCollision.Name = "VoxelServerCollision"
serverCollision.Archivable = false -- transient collision: a non-archivable folder excludes its whole subtree from SavePlaceAsync
serverCollision.Parent = workspace

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

-- Expose the classic-terrain API (LegacyVoxelTerrain.GetCell/SetCell/...) on the AUTHORITATIVE server
-- store: an edit generates base terrain for touched chunks, rebuilds the server collision for the
-- affected chunks, records the edit into the (persisted) overlay, and BROADCASTS the deltas to every
-- client (EditDeltas) so they apply + dirty-rebuild. This is the only edit path -- clients cannot
-- initiate edits. Note: a very large SetCells fans out one delta per cell -- prefer modest regions.
local LegacyVoxelTerrain = require(Lib)
LegacyVoxelTerrain.bind({
	store = store,
	ensureGenerated = ensureWorld,
	markDirty = function(cx: number, cy: number, cz: number)
		if streamer then
			streamer:markDirty(cx, cy, cz)
		end
	end,
	onDeltas = function(deltas)
		for _, d in deltas do
			recordEdit(d[1], d[2], d[3], d[4])
		end
		EditDeltas:FireAllClients(deltas)
	end,
})

TerrainConfig.isInitialized.Value = true -- init handshake: clients gate on this (was ReplicatedStorage.Loaded)
end

return TerrainServer
