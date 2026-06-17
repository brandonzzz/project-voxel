--!strict
--[[
	ChunkManager — streams chunk render meshes around a moving focus point.

	Per Heartbeat it: enqueues missing chunks within a circular radius, unloads
	chunks past the radius + margin, re-sorts the queue by distance to the focus,
	and dispatches up to `maxConcurrent` build coroutines. Each build runs the
	Mesher with a yielder bound to a per-frame time budget, so the synchronous
	fill is time-sliced; the bake calls yield naturally, letting the <=4 builds
	overlap. A debug HUD reports live editables, queue depth and timings.

	Single-context (client) for M4: it owns the store + generator + meshing. The
	server-authoritative split (server owns buffers, replicates deltas) arrives
	in M6 behind the same module boundary.
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Constants = require(script.Parent.Constants)
local Mesher = require(script.Parent.Mesher)
local EditService = require(script.Parent.EditService)
local Autowedge = require(script.Parent.Autowedge)

local CHUNK = Constants.CHUNK
local CHUNK_STUDS = Constants.CHUNK_STUDS

local ChunkManager = {}
ChunkManager.__index = ChunkManager

local function keyOf(cx: number, cz: number): string
	return cx .. "_" .. cz
end

export type Options = {
	store: any,
	gen: any,
	container: Instance,
	focusFn: () -> Vector3,
	radius: number?,
	unloadMargin: number?,
	maxConcurrent: number?,
	frameBudgetMs: number?,
	nearDist: number?, -- chunks: at/under this, build at nearOpsPerFrame
	farDist: number?, -- chunks: at/over this, build at farOpsPerFrame (fixed, inside the radius)
	nearOpsPerFrame: number?, -- heavy ops/frame for the nearest chunks (fast, may dip fps)
	farOpsPerFrame: number?, -- heavy ops/frame at/beyond farDist (< 1 = idle frames, fps-safe)
	cy: number?,
	hud: boolean?,
	renderEnabled: boolean?, -- false => skip the terrain bake (render comes from the server), keep onBuilt
	onBuilt: ((number, number) -> ())?,
	onUnloaded: ((number, number) -> ())?,
}

-- Heavy-op refill rate (ops/frame) for a chunk `dchunks` chunks from the player. Near chunks load
-- fast (>= 1 op/frame, accepting brief fps dips); far chunks slowly (< 1 op/frame, leaving idle
-- frames at full fps). Linear from nearOpsPerFrame at nearDist to farOpsPerFrame at farDist (a fixed
-- distance well INSIDE the render radius, so normal frontier chunks at distance ~= radius are in the
-- slow zone; only chunks the player is right on top of -- e.g. after fast movement -- build fast).
local function opsPerFrameFor(mgr, dchunks: number): number
	local far = math.max(mgr.nearDist + 1, mgr.farDist)
	local t = math.clamp((dchunks - mgr.nearDist) / (far - mgr.nearDist), 0, 1)
	return mgr.nearOpsPerFrame + (mgr.farOpsPerFrame - mgr.nearOpsPerFrame) * t
end

function ChunkManager.new(opts: Options)
	local self = setmetatable({}, ChunkManager)
	self.store = opts.store
	self.gen = opts.gen
	self.container = opts.container
	self.focusFn = opts.focusFn
	self.radius = opts.radius or 6
	self.unloadMargin = opts.unloadMargin or 2
	self.maxConcurrent = opts.maxConcurrent or 4
	self.frameBudget = (opts.frameBudgetMs or 5) / 1000
	self.cy = opts.cy or 0
	self.wantHud = opts.hud ~= false
	self.renderEnabled = opts.renderEnabled ~= false -- default true; false when the server renders
	self.onBuilt = opts.onBuilt
	self.onUnloaded = opts.onUnloaded

	self.loaded = {} :: { [string]: { cx: number, cz: number } }
	self.based = {} :: { [string]: boolean } -- base terrain generated
	self.wedged = {} :: { [string]: boolean } -- autowedge pass applied
	self.inQueue = {} :: { [string]: boolean }
	self.queue = {} :: { { key: string, cx: number, cz: number, dist: number } }
	self.building = {} :: { [string]: boolean }
	self.buildingCount = 0
	self.dirty = {} :: { [string]: { cx: number, cz: number } } -- chunks needing a rebuild after edits
	self.frameDeadline = 0
	self.lastBuildMs = 0
	self.maxFrameMs = 0
	self._conn = nil
	self.hud = nil

	-- Distance-adaptive heavy-op pacing (see opsPerFrameFor + update + _bakeGate). A credit bucket is
	-- refilled each frame at a rate set by how close the chunk being built is to the player; one
	-- heavy op costs one credit.
	self.nearDist = opts.nearDist or 2 -- chunks: at/under this, build at full nearOpsPerFrame
	self.farDist = opts.farDist or 4 -- chunks: at/over this, build at farOpsPerFrame (fixed, < radius)
	self.nearOpsPerFrame = opts.nearOpsPerFrame or 2 -- urgent near chunks: up to N heavy ops/frame
	self.farOpsPerFrame = opts.farOpsPerFrame or 0.34 -- far chunks: ~1 op every 3 frames (fps-safe)
	self._opCredits = 1
	self._activeChunk = nil :: { cx: number, cz: number }?

	local mgr = self
	self._yielder = function()
		if os.clock() > mgr.frameDeadline then
			RunService.Heartbeat:Wait()
		end
	end
	-- Heavy per-chunk ops -- CreateDataModelContentAsync (bake), CreateMeshPartAsync, and the
	-- collision+water rebuild -- each block the main thread ~8-24 ms and can't be time-sliced or
	-- parallelized (AssetService is main-thread-only). Each spends one op credit; the bucket refills
	-- per frame at a distance-dependent rate (update -> opsPerFrameFor), so near chunks run several
	-- ops/frame (load fast, brief fps dip) and far chunks run < 1 op/frame (idle frames stay 60fps).
	-- Robust to the AssetService calls' mid-op yields: update() keeps refilling while an op is
	-- mid-flight, so spacing is governed by real frames rather than a counter that resets mid-op.
	self._bakeGate = function()
		while mgr._opCredits < 1 do
			RunService.Heartbeat:Wait()
		end
		mgr._opCredits -= 1
	end
	return self
end

-- Pace one heavy main-thread op onto a gated frame. Used by the build path (via the assetGate
-- passed to Mesher.rebuildChunk) and by the render container's onBuilt collision+water rebuild,
-- so all the heavy work shares the same one-op-per-frame budget. --
function ChunkManager:waitAssetSlot()
	self._bakeGate()
end

function ChunkManager:focusChunk(): (number, number)
	local p = self.focusFn()
	return math.floor(p.X / CHUNK_STUDS), math.floor(p.Z / CHUNK_STUDS)
end

function ChunkManager:_enqueueMissing(fcx: number, fcz: number)
	local r = self.radius
	for dx = -r, r do
		for dz = -r, r do
			if dx * dx + dz * dz <= r * r then
				local cx, cz = fcx + dx, fcz + dz
				local k = keyOf(cx, cz)
				if not self.loaded[k] and not self.building[k] and not self.inQueue[k] then
					self.inQueue[k] = true
					self.queue[#self.queue + 1] = { key = k, cx = cx, cz = cz, dist = 0 }
				end
			end
		end
	end
end

function ChunkManager:_removeChunkParts(cx: number, cz: number)
	local base = string.format("C_%d_%d_%d", cx, self.cy, cz)
	for _, ch in self.container:GetChildren() do
		if ch.Name == base or string.match(ch.Name, "^" .. base .. "_oct%d$") then
			ch:Destroy()
		end
	end
	if self.onUnloaded then
		self.onUnloaded(cx, cz)
	end
end

function ChunkManager:_unloadFar(fcx: number, fcz: number)
	local limit = self.radius + self.unloadMargin
	for k, pos in self.loaded do
		local dx, dz = pos.cx - fcx, pos.cz - fcz
		if dx * dx + dz * dz > limit * limit then
			self:_removeChunkParts(pos.cx, pos.cz)
			self.loaded[k] = nil
		end
	end
end

function ChunkManager:_sortQueue(fcx: number, fcz: number)
	for _, it in self.queue do
		local dx, dz = it.cx - fcx, it.cz - fcz
		it.dist = dx * dx + dz * dz
	end
	table.sort(self.queue, function(a, b)
		return a.dist > b.dist -- nearest last, popped first
	end)
end

-- Mark a loaded chunk for rebuild after an edit (debounced: many edits to one
-- chunk in a frame collapse to a single rebuild that reads the current store). --
function ChunkManager:markDirty(cx: number, cz: number)
	self.dirty[keyOf(cx, cz)] = { cx = cx, cz = cz }
end

-- Re-enqueue dirty chunks that aren't currently building (deferred otherwise). --
function ChunkManager:_processDirty()
	for k, pos in self.dirty do
		if not self.building[k] then
			self.loaded[k] = nil
			self.dirty[k] = nil
			if not self.inQueue[k] then
				self.inQueue[k] = true
				self.queue[#self.queue + 1] = { key = k, cx = pos.cx, cz = pos.cz, dist = 0 }
			end
		end
	end
end

-- Base terrain only (f(seed)). --
function ChunkManager:ensureBase(cx: number, cz: number)
	local k = keyOf(cx, cz)
	if not self.based[k] then
		self.gen:fillChunk(self.store, cx, self.cy, cz)
		self.based[k] = true
	end
end

-- Base + Autowedge for ONE chunk. Its own 8-neighbour bases are ensured first so
-- border cells re-wedge correctly (never treat out-of-chunk as Empty). --
function ChunkManager:_wedgeOne(cx: number, cz: number)
	self:ensureBase(cx, cz)
	local k = keyOf(cx, cz)
	if self.wedged[k] then
		return
	end
	if Autowedge.ENABLED then
		-- all 8 neighbours: inside-corner reads diagonal cells at chunk corners
		for dx = -1, 1 do
			for dz = -1, 1 do
				self:ensureBase(cx + dx, cz + dz)
			end
		end
		local cy = self.cy
		EditService.autowedgeRegion(
			self.store,
			cx * CHUNK,
			cy * CHUNK,
			cz * CHUNK,
			cx * CHUNK + CHUNK - 1,
			cy * CHUNK + CHUNK - 1,
			cz * CHUNK + CHUNK - 1
		)
	end
	self.wedged[k] = true
end

-- Generation pipeline BEFORE the first bake / water render. The chunk AND all 8
-- neighbours are fully autowedged here so cross-chunk water-face detection
-- (WaterRender.faceAllWater reads neighbour cells) sees each neighbour's FINAL
-- slope/water state on the first build. Otherwise the chunk that bakes first reads
-- un-wedged neighbour base cells, mis-classifies the shared border as land, insets
-- that water face, and leaves a 0.02 seam at the chunk edge that never re-evaluates.
-- Net generation work is unchanged (each chunk is still based + wedged exactly once,
-- cached by flags) -- only the order is pulled earlier. Edit deltas also call this
-- before applying edits so lazy generation can't clobber edited cells. --
function ChunkManager:ensureGenerated(cx: number, cz: number)
	self:_wedgeOne(cx, cz)
	for dx = -1, 1 do
		for dz = -1, 1 do
			if dx ~= 0 or dz ~= 0 then
				self:_wedgeOne(cx + dx, cz + dz)
			end
		end
	end
end

function ChunkManager:_buildOne(cx: number, cz: number)
	self:ensureGenerated(cx, cz)
	-- When render is server-authoritative (Constants.SERVER_RENDER), the client skips its own terrain
	-- bake (the heavy op -- meshes arrive from the server) but still streams the chunk so onBuilt can
	-- build local collision + water.
	if self.renderEnabled then
		local stats = Mesher.rebuildChunk(self.store, cx, self.cy, cz, self.container, self._yielder, self._bakeGate)
		self.lastBuildMs = stats.buildMs
	end
	if self.onBuilt then
		self.onBuilt(cx, cz)
	end
end

function ChunkManager:_dispatch()
	while self.buildingCount < self.maxConcurrent and #self.queue > 0 do
		local it = self.queue[#self.queue]
		self.queue[#self.queue] = nil
		self.inQueue[it.key] = nil
		self.building[it.key] = true
		self.buildingCount += 1
		task.spawn(function()
			-- the chunk now building, so update()'s credit refill paces by ITS distance to the player
			-- (assumes maxConcurrent == 1, the default; with more, the last-dispatched chunk wins).
			self._activeChunk = { cx = it.cx, cz = it.cz }
			local ok, err = pcall(function()
				self:_buildOne(it.cx, it.cz)
			end)
			if not ok then
				warn("[ChunkManager] build error at " .. it.key .. ": " .. tostring(err))
			end
			self.building[it.key] = nil
			self.buildingCount -= 1
			self.loaded[it.key] = { cx = it.cx, cz = it.cz }
			self._activeChunk = nil
		end)
	end
end

function ChunkManager:_ensureHud()
	if self.hud or not self.wantHud then
		return
	end
	local player = Players.LocalPlayer
	if not player then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "VoxelHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(0, 320, 0, 120)
	lbl.Position = UDim2.new(0, 8, 0, 8)
	lbl.BackgroundColor3 = Color3.new(0, 0, 0)
	lbl.BackgroundTransparency = 0.35
	lbl.TextColor3 = Color3.fromRGB(120, 255, 140)
	lbl.Font = Enum.Font.Code
	lbl.TextSize = 15
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextYAlignment = Enum.TextYAlignment.Top
	lbl.Text = ""
	lbl.Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui")
	self.hud = lbl
end

function ChunkManager:_updateHud(loadedCount: number)
	self:_ensureHud()
	if not self.hud then
		return
	end
	self.hud.Text = string.format(
		"Legacy Voxel Terrain  [debug]\nlive editables : %d  (max %d)\nqueue depth    : %d\nbuilding       : %d\nloaded chunks  : %d\nlast build     : %.1f ms\nmax frame      : %.1f ms",
		Mesher.liveEditables,
		Mesher.maxLiveEditables,
		#self.queue,
		self.buildingCount,
		loadedCount,
		self.lastBuildMs,
		self.maxFrameMs
	)
end

function ChunkManager:update(dt: number)
	-- live-tunable overrides (set as attributes on the container for experiments)
	local mc = self.container:GetAttribute("cfgMaxConcurrent")
	if mc then
		self.maxConcurrent = mc
	end
	local fb = self.container:GetAttribute("cfgFrameBudgetMs")
	if fb then
		self.frameBudget = fb / 1000
	end
	local nopf = self.container:GetAttribute("cfgNearOpsPerFrame")
	if typeof(nopf) == "number" then
		self.nearOpsPerFrame = nopf
	end
	local fopf = self.container:GetAttribute("cfgFarOpsPerFrame")
	if typeof(fopf) == "number" then
		self.farOpsPerFrame = fopf
	end
	local nd = self.container:GetAttribute("cfgNearDist")
	if typeof(nd) == "number" then
		self.nearDist = nd
	end
	local fd = self.container:GetAttribute("cfgFarDist")
	if typeof(fd) == "number" then
		self.farDist = fd
	end
	-- Render distance (chunks) around the character, configurable live via a container
	-- attribute. Shrinking it unloads far chunks next pass; growing it enqueues new ones.
	local rd = self.container:GetAttribute("RenderDistance")
	if typeof(rd) == "number" then
		self.radius = math.clamp(math.floor(rd), 1, 24)
	end

	self.frameDeadline = os.clock() + self.frameBudget
	local ms = dt * 1000
	self.maxFrameMs = math.max(ms, self.maxFrameMs * 0.95) -- decaying recent max
	local fcx, fcz = self:focusChunk()

	-- Refill the distance-adaptive heavy-op credit bucket (see _bakeGate). Rate depends on how close
	-- the chunk currently being built is to the player NOW, so as the player moves the in-flight
	-- chunk speeds up (got closer) or slows down (got farther). Cap = ceil(rate) so near chunks can
	-- bank up to a few ops for one frame; idle resets to 1 (next build's first op is prompt, no burst).
	local ac = self._activeChunk
	if ac then
		local d = math.sqrt((ac.cx - fcx) ^ 2 + (ac.cz - fcz) ^ 2)
		local r = opsPerFrameFor(self, d)
		self._opCredits = math.min(self._opCredits + r, math.max(1, math.ceil(r)))
	else
		self._opCredits = 1
	end

	self:_enqueueMissing(fcx, fcz)
	self:_processDirty()
	self:_unloadFar(fcx, fcz)
	self:_sortQueue(fcx, fcz)
	self:_dispatch()

	local loadedCount = 0
	for _ in self.loaded do
		loadedCount += 1
	end
	-- Expose stats as attributes (readable from other Luau contexts / MCP). --
	local c = self.container
	c:SetAttribute("liveEditables", Mesher.liveEditables)
	c:SetAttribute("maxLiveEditables", Mesher.maxLiveEditables)
	c:SetAttribute("queueDepth", #self.queue)
	c:SetAttribute("building", self.buildingCount)
	c:SetAttribute("loadedChunks", loadedCount)
	c:SetAttribute("lastBuildMs", self.lastBuildMs)
	c:SetAttribute("maxFrameMs", self.maxFrameMs)

	self:_updateHud(loadedCount)
end

function ChunkManager:start()
	if self._conn then
		return
	end
	self._conn = RunService.Heartbeat:Connect(function(dt)
		self:update(dt)
	end)
end

function ChunkManager:stop()
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
end

return ChunkManager
