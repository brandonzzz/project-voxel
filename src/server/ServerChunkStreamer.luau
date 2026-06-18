--!strict
--[[
	ServerChunkStreamer — server-side collision streaming.

	The server owns no render meshes, but it must have terrain collision so that
	server-simulated parts (loose debris before a client takes ownership, scripted
	objects, etc.) rest on the voxel terrain instead of falling through it.

	This streams INVISIBLE, collision-only chunks ("soft-loaded": collision present, no
	visual render) around the union of player character positions, reusing the same
	Collision builder the client uses (greedy boxes + baked-Hull wedge colliders), so
	the server's collision is geometrically identical to each client's own. Built parts
	are tagged into a CollisionGroup so VoxelServer can tune what they interact with.

	chunkReasons lets other systems pin a chunk loaded regardless of player proximity
	(loose parts spanning a boundary, RBLXClassic_ChunkSoftLoader tags). onChunkLoaded /
	onChunkUnloaded fire so the loose-part streamer can swap assemblies in/out.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Lib = game:GetService("ReplicatedStorage"):WaitForChild("LegacyVoxelTerrain")
local Constants = require(Lib:WaitForChild("Constants"))
local Collision = require(Lib:WaitForChild("Collision"))

local CHUNK = Constants.CHUNK
local CELL = Constants.CELL
local CHUNK_STUDS = CHUNK * CELL

local ServerChunkStreamer = {}
ServerChunkStreamer.__index = ServerChunkStreamer

local function keyOf(cx: number, cy: number, cz: number): string
	return cx .. "_" .. cy .. "_" .. cz
end

export type Opts = {
	store: any,
	ensureWorld: (number, number, number) -> (), -- base + autowedge for a chunk
	container: Instance, -- workspace folder for the collision parts
	collisionGroup: string?,
	cy: number?,
	radius: number?, -- chunk radius around each player
	onChunkLoaded: ((number, number) -> ())?,
	onChunkUnloaded: ((number, number) -> ())?,
	-- Mutates the desired set each tick to add extra chunks (e.g. neighbours a loose assembly
	-- spans into, while its home chunk is loaded). Receives the player-radius set so it can
	-- expand only around already-wanted chunks -- keeping unattended chunks free to unload.
	expandFn: (({ [string]: { cx: number, cz: number } }) -> ())?,
}

function ServerChunkStreamer.new(opts: Opts)
	local self = setmetatable({}, ServerChunkStreamer)
	self.store = opts.store
	self.ensureWorld = opts.ensureWorld
	self.container = opts.container
	self.collisionGroup = opts.collisionGroup
	self.cy = opts.cy or 0
	self.radius = opts.radius or 4
	self.onChunkLoaded = opts.onChunkLoaded
	self.onChunkUnloaded = opts.onChunkUnloaded
	self.expandFn = opts.expandFn
	self.loaded = {} :: { [string]: { cx: number, cy: number, cz: number } }
	-- extra keep-loaded reasons keyed by chunk: chunkReasons[key][reasonId] = true
	self.chunkReasons = {} :: { [string]: { [string]: boolean } }
	return self
end

-- Pin a chunk loaded for `reason` regardless of player proximity (SC4/SC5). --
function ServerChunkStreamer:addReason(cx: number, cy: number, cz: number, reason: string)
	local key = keyOf(cx, cy, cz)
	local set = self.chunkReasons[key]
	if not set then
		set = {}
		self.chunkReasons[key] = set
	end
	set[reason] = true
end

function ServerChunkStreamer:removeReason(cx: number, cy: number, cz: number, reason: string)
	local key = keyOf(cx, cy, cz)
	local set = self.chunkReasons[key]
	if set then
		set[reason] = nil
		if not next(set) then
			self.chunkReasons[key] = nil
		end
	end
end

function ServerChunkStreamer:isLoaded(cx: number, cy: number, cz: number): boolean
	return self.loaded[keyOf(cx, cy, cz)] ~= nil
end

local function setGroup(folder: Instance, group: string?)
	if not group then
		return
	end
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = group
		end
	end
end

function ServerChunkStreamer:_load(cx: number, cy: number, cz: number)
	local key = keyOf(cx, cy, cz)
	if self.loaded[key] then
		return
	end
	self.ensureWorld(cx, cy, cz)
	Collision.rebuildChunk(self.store, cx, cy, cz, self.container)
	local folder = self.container:FindFirstChild(string.format("Col_%d_%d_%d", cx, cy, cz))
	if folder then
		setGroup(folder, self.collisionGroup)
	end
	self.loaded[key] = { cx = cx, cy = cy, cz = cz }
	if self.onChunkLoaded then
		self.onChunkLoaded(cx, cy, cz)
	end
end

function ServerChunkStreamer:_unload(cx: number, cy: number, cz: number)
	local key = keyOf(cx, cy, cz)
	if not self.loaded[key] then
		return
	end
	Collision.removeChunk(cx, cy, cz, self.container)
	self.loaded[key] = nil
	if self.onChunkUnloaded then
		self.onChunkUnloaded(cx, cy, cz)
	end
end

-- Rebuild a loaded chunk's collision (after an edit/explosion changed its cells). No-op if
-- the chunk isn't currently loaded. The store is assumed already mutated by the caller. --
function ServerChunkStreamer:markDirty(cx: number, cy: number, cz: number)
	if not self.loaded[keyOf(cx, cy, cz)] then
		return
	end
	Collision.rebuildChunk(self.store, cx, cy, cz, self.container)
	local folder = self.container:FindFirstChild(string.format("Col_%d_%d_%d", cx, cy, cz))
	if folder then
		setGroup(folder, self.collisionGroup)
	end
end

-- Desired set = union of a 3D chunk sphere around every player + all pinned reasons. --
function ServerChunkStreamer:_desired(): { [string]: { cx: number, cy: number, cz: number } }
	local want: { [string]: { cx: number, cy: number, cz: number } } = {}
	local r = self.radius
	for _, plr in Players:GetPlayers() do
		local char = plr.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			local p = hrp.Position
			local fcx = math.floor(p.X / CHUNK_STUDS)
			local fcy = math.floor(p.Y / CHUNK_STUDS)
			local fcz = math.floor(p.Z / CHUNK_STUDS)
			for dy = -r, r do
				for dx = -r, r do
					for dz = -r, r do
						if dx * dx + dy * dy + dz * dz <= r * r then
							local cx, cy, cz = fcx + dx, fcy + dy, fcz + dz
							want[keyOf(cx, cy, cz)] = { cx = cx, cy = cy, cz = cz }
						end
					end
				end
			end
		end
	end
	-- Loose assemblies rest on the cy=0 surface; let them pull in the neighbour chunks they span
	-- into. expandFn works in 2D (cy=0), so give it a 2D view of the wanted cy=0 chunks and merge
	-- whatever it adds back as cy=0 3D entries.
	if self.expandFn then
		local view: { [string]: { cx: number, cz: number } } = {}
		for _, pos in want do
			if pos.cy == 0 then
				view[pos.cx .. "_" .. pos.cz] = { cx = pos.cx, cz = pos.cz }
			end
		end
		self.expandFn(view)
		for _, pos in view do
			want[keyOf(pos.cx, 0, pos.cz)] = { cx = pos.cx, cy = 0, cz = pos.cz }
		end
	end
	for key, reasons in self.chunkReasons do
		if next(reasons) then
			local sx, sy, sz = string.match(key, "(-?%d+)_(-?%d+)_(-?%d+)")
			want[key] =
				{ cx = tonumber(sx) :: number, cy = tonumber(sy) :: number, cz = tonumber(sz) :: number }
		end
	end
	return want
end

function ServerChunkStreamer:_update()
	-- Simulation distance (chunks) around each player -- how far server collision + loose-part
	-- streaming reach. Configurable live via a container attribute; visible on clients only by
	-- the distance at which loose parts pop in.
	local sd = self.container:GetAttribute("SimulationDistance")
	if typeof(sd) == "number" then
		self.radius = math.clamp(math.floor(sd), 1, 24)
	end
	local want = self:_desired()
	for key, pos in want do
		if not self.loaded[key] then
			self:_load(pos.cx, pos.cy, pos.cz)
			task.wait() -- spread bursts across frames so big loads don't spike the server
		end
	end
	for key, pos in self.loaded do
		if not want[key] then
			self:_unload(pos.cx, pos.cy, pos.cz)
		end
	end
end

function ServerChunkStreamer:start()
	task.spawn(function()
		Collision.prewarmTemplates() -- bake wedge templates once, before any chunk load
		while true do
			local ok, err = pcall(function()
				self:_update()
			end)
			if not ok then
				warn("[ServerChunkStreamer] update error: " .. tostring(err))
			end
			task.wait(0.2) -- ~5 Hz streaming tick
		end
	end)
end

return ServerChunkStreamer
