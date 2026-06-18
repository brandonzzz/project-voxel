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

local function keyOf(cx: number, cy: number, cz: number): string
	return cx .. "_" .. cy .. "_" .. cz
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
	collectPool: any?, -- optional CollectPool: offloads the render cull to worker Actors
	onBuilt: ((number, number, number, number) -> ())?, -- (cx, cy, cz, renderTriCount)
	onUnloaded: ((number, number, number) -> ())?,
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
	self.collectPool = opts.collectPool
	self.onBuilt = opts.onBuilt
	self.onUnloaded = opts.onUnloaded

	self.loaded = {} :: { [string]: { cx: number, cy: number, cz: number } }
	self.based = {} :: { [string]: boolean } -- base terrain generated
	self.wedged = {} :: { [string]: boolean } -- autowedge pass applied
	self.inQueue = {} :: { [string]: boolean }
	self.queue = {} :: { { key: string, cx: number, cy: number, cz: number, dist: number } }
	self.building = {} :: { [string]: boolean }
	self.buildingCount = 0
	self.dirty = {} :: { [string]: { cx: number, cy: number, cz: number } } -- chunks needing a rebuild after edits
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
	self._activeChunk = nil :: { cx: number, cy: number, cz: number }?

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

function ChunkManager:focusChunk(): (number, number, number)
	local p = self.focusFn()
	return math.floor(p.X / CHUNK_STUDS), math.floor(p.Y / CHUNK_STUDS), math.floor(p.Z / CHUNK_STUDS)
end

function ChunkManager:_enqueueMissing(fcx: number, fcy: number, fcz: number)
	local r = self.radius
	for dy = -r, r do
		for dx = -r, r do
			for dz = -r, r do
				if dx * dx + dy * dy + dz * dz <= r * r then
					local cx, cy, cz = fcx + dx, fcy + dy, fcz + dz
					local k = keyOf(cx, cy, cz)
					if not self.loaded[k] and not self.building[k] and not self.inQueue[k] then
						self.inQueue[k] = true
						self.queue[#self.queue + 1] = { key = k, cx = cx, cy = cy, cz = cz, dist = 0 }
					end
				end
			end
		end
	end
end

function ChunkManager:_removeChunkParts(cx: number, cy: number, cz: number)
	local base = string.format("C_%d_%d_%d", cx, cy, cz)
	for _, ch in self.container:GetChildren() do
		if ch.Name == base or string.match(ch.Name, "^" .. base .. "_oct%d$") then
			ch:Destroy()
		end
	end
	if self.onUnloaded then
		self.onUnloaded(cx, cy, cz)
	end
end

function ChunkManager:_unloadFar(fcx: number, fcy: number, fcz: number)
	local limit = self.radius + self.unloadMargin
	for k, pos in self.loaded do
		local dx, dy, dz = pos.cx - fcx, pos.cy - fcy, pos.cz - fcz
		if dx * dx + dy * dy + dz * dz > limit * limit then
			self:_removeChunkParts(pos.cx, pos.cy, pos.cz)
			self.loaded[k] = nil
		end
	end
end

function ChunkManager:_sortQueue(fcx: number, fcy: number, fcz: number)
	for _, it in self.queue do
		local dx, dy, dz = it.cx - fcx, it.cy - fcy, it.cz - fcz
		it.dist = dx * dx + dy * dy + dz * dz
	end
	table.sort(self.queue, function(a, b)
		return a.dist > b.dist -- nearest last, popped first
	end)
end

-- Mark a loaded chunk for rebuild after an edit (debounced: many edits to one
-- chunk in a frame collapse to a single rebuild that reads the current store). --
function ChunkManager:markDirty(cx: number, cy: number, cz: number)
	self.dirty[keyOf(cx, cy, cz)] = { cx = cx, cy = cy, cz = cz }
end

-- Re-enqueue dirty chunks that aren't currently building (deferred otherwise). --
function ChunkManager:_processDirty()
	for k, pos in self.dirty do
		if not self.building[k] then
			self.loaded[k] = nil
			self.dirty[k] = nil
			if not self.inQueue[k] then
				self.inQueue[k] = true
				self.queue[#self.queue + 1] = { key = k, cx = pos.cx, cy = pos.cy, cz = pos.cz, dist = 0 }
			end
		end
	end
end

-- Base terrain only (f(seed)). --
function ChunkManager:ensureBase(cx: number, cy: number, cz: number)
	local k = keyOf(cx, cy, cz)
	if not self.based[k] then
		self.gen:fillChunk(self.store, cx, cy, cz)
		self.based[k] = true
	end
end

-- Base + Autowedge for ONE chunk. Its own 3x3x3 neighbour bases are ensured first so border cells
-- re-wedge correctly (never treat out-of-chunk as Empty) -- including the chunk ABOVE, since the
-- "open above" surface test at the top layer reads into cy+1. --
function ChunkManager:_wedgeOne(cx: number, cy: number, cz: number)
	self:ensureBase(cx, cy, cz)
	local k = keyOf(cx, cy, cz)
	if self.wedged[k] then
		return
	end
	if Autowedge.ENABLED then
		-- all 26 neighbours: inside-corner reads diagonals; the "open above" read crosses into cy+1
		for dy = -1, 1 do
			for dx = -1, 1 do
				for dz = -1, 1 do
					self:ensureBase(cx + dx, cy + dy, cz + dz)
				end
			end
		end
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

-- Generation pipeline BEFORE the first bake / water render. The chunk AND all 26 neighbours are
-- fully autowedged here so cross-chunk face detection (render border culling + WaterRender reading
-- neighbour cells) sees each neighbour's FINAL slope/water state on the first build -- across all six
-- faces, including the vertical neighbours now that streaming is 3D. Net generation work is unchanged
-- (each chunk is still based + wedged exactly once, cached by flags) -- only the order is pulled
-- earlier. Edit deltas also call this before applying edits so lazy generation can't clobber edits. --
function ChunkManager:ensureGenerated(cx: number, cy: number, cz: number)
	for dy = -1, 1 do
		for dx = -1, 1 do
			for dz = -1, 1 do
				self:_wedgeOne(cx + dx, cy + dy, cz + dz)
			end
		end
	end
end

function ChunkManager:_buildOne(cx: number, cy: number, cz: number)
	self:ensureGenerated(cx, cy, cz)
	local stats
	if self.collectPool then
		-- Offload the cull to a worker Actor: snapshot the chunk (+1-cell shell) on the main thread,
		-- collect in parallel (main yields, no Heartbeat block), then fill/bake/apply the returned
		-- triangles on the main thread (AssetService isn't parallel-safe). buildPaddedChunk (~1-3 ms)
		-- + deserialize (~0.25 ms) replace the ~21 ms main-thread cull.
		local paddedStr = Mesher.buildPaddedChunk(self.store, cx, cy, cz)
		local tris, count = self.collectPool:collect(cx, cy, cz, paddedStr)
		stats = Mesher.rebuildFromTris(tris, count, cx, cy, cz, self.container, self._yielder, self._bakeGate)
	else
		stats = Mesher.rebuildChunk(self.store, cx, cy, cz, self.container, self._yielder, self._bakeGate)
	end
	self.lastBuildMs = stats.buildMs
	if self.onBuilt then
		self.onBuilt(cx, cy, cz, stats.tris)
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
			self._activeChunk = { cx = it.cx, cy = it.cy, cz = it.cz }
			local ok, err = pcall(function()
				self:_buildOne(it.cx, it.cy, it.cz)
			end)
			if not ok then
				warn("[ChunkManager] build error at " .. it.key .. ": " .. tostring(err))
			end
			self.building[it.key] = nil
			self.buildingCount -= 1
			self.loaded[it.key] = { cx = it.cx, cy = it.cy, cz = it.cz }
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
	local fcx, fcy, fcz = self:focusChunk()

	-- Refill the distance-adaptive heavy-op credit bucket (see _bakeGate). Rate depends on how close
	-- the chunk currently being built is to the player NOW, so as the player moves the in-flight
	-- chunk speeds up (got closer) or slows down (got farther). Cap = ceil(rate) so near chunks can
	-- bank up to a few ops for one frame; idle resets to 1 (next build's first op is prompt, no burst).
	local ac = self._activeChunk
	if ac then
		local d = math.sqrt((ac.cx - fcx) ^ 2 + (ac.cy - fcy) ^ 2 + (ac.cz - fcz) ^ 2)
		local r = opsPerFrameFor(self, d)
		self._opCredits = math.min(self._opCredits + r, math.max(1, math.ceil(r)))
	else
		self._opCredits = 1
	end

	-- The enqueue + unload scans are O(radius^3) over the whole 3D sphere (and allocate a key string
	-- per cell). New work only appears when the focus chunk moves or the radius changes, so skip both
	-- scans on frames where neither did -- which is most frames once the player is standing still. This
	-- keeps the per-frame cost of a large invisible sphere near zero (it was ~0.2 ms/frame at idle and
	-- grows cubically). _processDirty / _sortQueue / _dispatch still run every frame (O(queue), empty at
	-- idle) so edits and the in-flight build queue keep draining.
	local lf = self._lastFocus
	if not lf or lf.cx ~= fcx or lf.cy ~= fcy or lf.cz ~= fcz or self._lastRadius ~= self.radius then
		self:_enqueueMissing(fcx, fcy, fcz)
		self:_unloadFar(fcx, fcy, fcz)
		self._lastFocus = { cx = fcx, cy = fcy, cz = fcz }
		self._lastRadius = self.radius
	end
	self:_processDirty()
	self:_sortQueue(fcx, fcy, fcz)
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
