--!strict
--[[
	LegacyVoxelTerrain — parent module + classic-terrain-API facade over the voxel engine.

	`require(ReplicatedStorage.LegacyVoxelTerrain)` returns this table. It re-exports the internal
	modules (Mesher, VoxelStore, Collision, ...) and recreates the legacy Roblox blocky terrain API,
	driven by the legacy Enums (Enum.CellMaterial / CellBlock / CellOrientation / WaterForce /
	WaterDirection) -- which map 1:1 to this project's internal material / shape / orientation ids.

	The API operates on a single BOUND terrain: the running context attaches the store it owns plus how
	to (re)generate + rebuild affected chunks and (optionally) replicate deltas, via T.bind. VoxelClient
	binds the client replica; VoxelServer binds the authoritative store + replication. An edit runs:
	ensure base terrain -> write the store -> mark affected chunks dirty -> (optional) emit deltas.

	Non-applicable enum fields are always the value-0 item (per the legacy API): water + solid cubes
	report CellBlock.Solid / CellOrientation.NegZ; non-water reports WaterForce.None / WaterDirection.NegX.

	Helpers: rayMarch (voxel-grid DDA pick, no physics raycast); sampleVoxel / ghostVoxel (one voxel as
	a MeshPart -- solid+collidable, or a translucent non-collidable preview).
]]

local function child(name: string): ModuleScript
	return script:WaitForChild(name) :: ModuleScript
end

local Constants = require(child("Constants"))
local VoxelStore = require(child("VoxelStore"))
local Mesher = require(child("Mesher"))
local Collision = require(child("Collision"))
local EditService = require(child("EditService"))
local Autowedge = require(child("Autowedge"))
local WaterRender = require(child("WaterRender"))
local WorldGen = require(child("WorldGen"))
local ChunkManager = require(child("ChunkManager"))

local CELL = Constants.CELL
local WATER = Constants.Material.Water
local SOLID = Constants.Shape.Solid

local T = {}

-- Internal modules (re-exported for callers that want the lower layers) -----------------------------
T.Constants = Constants
T.VoxelStore = VoxelStore
T.Mesher = Mesher
T.Collision = Collision
T.EditService = EditService
T.Autowedge = Autowedge
T.WaterRender = WaterRender
T.WorldGen = WorldGen
T.ChunkManager = ChunkManager

-- Legacy-enum value -> EnumItem lookups (the project's numeric ids equal these enum values) ---------
local function valueMap(enum: any): { [number]: EnumItem }
	local m = {}
	for _, item in enum:GetEnumItems() do
		m[item.Value] = item
	end
	return m
end
local MATERIAL_ITEM = valueMap(Enum.CellMaterial)
local BLOCK_ITEM = valueMap(Enum.CellBlock)
local ORIENT_ITEM = valueMap(Enum.CellOrientation)
local WFORCE_ITEM = valueMap(Enum.WaterForce)
local WDIR_ITEM = valueMap(Enum.WaterDirection)

-- Accept either a legacy EnumItem or a raw numeric id at any API boundary. --
local function val(v: any): number
	if typeof(v) == "EnumItem" then
		return v.Value
	end
	return v
end

-- Bound terrain ------------------------------------------------------------------------------------
type Hooks = {
	store: any,
	ensureGenerated: ((number, number, number) -> ())?, -- gen base terrain for a chunk before editing
	markDirty: ((number, number, number) -> ())?, -- queue a chunk rebuild after editing
	onDeltas: (({ { number } }) -> ())?, -- replicate/record {wx,wy,wz,packedValue} deltas
}
local bound: Hooks = { store = nil }

function T.bind(hooks: Hooks)
	bound = hooks
end

function T.getStore(): any
	return bound.store
end

local function store(): any
	assert(bound.store, "LegacyVoxelTerrain: no terrain bound -- call LegacyVoxelTerrain.bind{ store = ... } first")
	return bound.store
end

-- Affected-chunk bookkeeping (a set keyed "cx_cy_cz" -> {cx,cy,cz}) --------------------------------
local function addCellChunks(set: { [string]: any }, x: number, y: number, z: number)
	for _, c in EditService.affectedChunks(x, y, z) do
		set[c.cx .. "_" .. c.cy .. "_" .. c.cz] = c
	end
end

-- Chunk span covering a cell box + a 1-chunk border ring (cheaper than per-cell for big regions). --
local function regionChunks(minX, minY, minZ, maxX, maxY, maxZ): { [string]: any }
	local set = {}
	local c0x, c1x = VoxelStore.worldToChunk(minX) - 1, VoxelStore.worldToChunk(maxX) + 1
	local c0y, c1y = VoxelStore.worldToChunk(minY) - 1, VoxelStore.worldToChunk(maxY) + 1
	local c0z, c1z = VoxelStore.worldToChunk(minZ) - 1, VoxelStore.worldToChunk(maxZ) + 1
	for cy = c0y, c1y do
		for cz = c0z, c1z do
			for cx = c0x, c1x do
				set[cx .. "_" .. cy .. "_" .. cz] = { cx = cx, cy = cy, cz = cz }
			end
		end
	end
	return set
end

local function ensureChunks(set: { [string]: any })
	if bound.ensureGenerated then
		for _, c in set do
			bound.ensureGenerated(c.cx, c.cy, c.cz)
		end
	end
end

local function rebuildChunks(set: { [string]: any }, deltas: { { number } }?)
	if bound.markDirty then
		for _, c in set do
			bound.markDirty(c.cx, c.cy, c.cz)
		end
	end
	if deltas and bound.onDeltas then
		bound.onDeltas(deltas)
	end
end

-- Region3 (studs) -> inclusive cell box. --
local function regionToCells(region: Region3): (number, number, number, number, number, number)
	local centre = region.CFrame.Position
	local half = region.Size / 2
	return math.floor((centre.X - half.X) / CELL),
		math.floor((centre.Y - half.Y) / CELL),
		math.floor((centre.Z - half.Z) / CELL),
		math.ceil((centre.X + half.X) / CELL) - 1,
		math.ceil((centre.Y + half.Y) / CELL) - 1,
		math.ceil((centre.Z + half.Z) / CELL) - 1
end

-- ===== Classic terrain API ========================================================================

-- GetCell(x,y,z) -> Enum.CellMaterial, Enum.CellBlock, Enum.CellOrientation. --
function T.GetCell(x: number, y: number, z: number): (EnumItem, EnumItem, EnumItem)
	local mat, byte1 = store():getCell(x, y, z)
	if mat == WATER then
		return MATERIAL_ITEM[WATER], BLOCK_ITEM[SOLID], ORIENT_ITEM[0] -- water: Solid / NegZ
	end
	local shape, orient = Constants.unpackByte1(byte1)
	if shape == SOLID then
		orient = 0 -- a cube has no meaningful orientation -> NegZ
	end
	return MATERIAL_ITEM[mat] or MATERIAL_ITEM[0], BLOCK_ITEM[shape] or BLOCK_ITEM[0], ORIENT_ITEM[orient] or ORIENT_ITEM[0]
end

-- GetWaterCell(x,y,z) -> isWater, Enum.WaterForce, Enum.WaterDirection. Non-water -> false/None/NegX. --
function T.GetWaterCell(x: number, y: number, z: number): (boolean, EnumItem, EnumItem)
	local mat, byte1 = store():getCell(x, y, z)
	if mat ~= WATER then
		return false, WFORCE_ITEM[0], WDIR_ITEM[0]
	end
	local force, dir = Constants.unpackWater(byte1)
	return true, WFORCE_ITEM[force] or WFORCE_ITEM[0], WDIR_ITEM[dir] or WDIR_ITEM[0]
end

function T.SetCell(x: number, y: number, z: number, material: any, block: any, orientation: any)
	local s = store()
	local mat = val(material)
	local byte1 = (mat == WATER) and 0 or Constants.packByte1(val(block), val(orientation))
	local set = {}
	addCellChunks(set, x, y, z)
	ensureChunks(set) -- gen base BEFORE the write so lazy gen can't clobber the edit
	s:setCell(x, y, z, mat, byte1)
	rebuildChunks(set, { { x, y, z, Constants.packCell(mat, byte1) } })
end

function T.SetWaterCell(x: number, y: number, z: number, force: any, direction: any)
	local s = store()
	local byte1 = Constants.packWater(val(force), val(direction))
	local set = {}
	addCellChunks(set, x, y, z)
	ensureChunks(set)
	s:setCell(x, y, z, WATER, byte1)
	rebuildChunks(set, { { x, y, z, Constants.packCell(WATER, byte1) } })
end

function T.SetCells(region: Region3, material: any, block: any, orientation: any)
	local s = store()
	local mat = val(material)
	local byte1 = (mat == WATER) and 0 or Constants.packByte1(val(block), val(orientation))
	local value = Constants.packCell(mat, byte1)
	local minX, minY, minZ, maxX, maxY, maxZ = regionToCells(region)
	local set = regionChunks(minX, minY, minZ, maxX, maxY, maxZ)
	ensureChunks(set)
	local deltas: { { number } } = {}
	for y = minY, maxY do
		for z = minZ, maxZ do
			for x = minX, maxX do
				s:setCell(x, y, z, mat, byte1)
				deltas[#deltas + 1] = { x, y, z, value }
			end
		end
	end
	rebuildChunks(set, deltas)
end

-- Re-decide a single cell's wedge from its (already-generated) neighbours, then rebuild. --
function T.AutowedgeCell(x: number, y: number, z: number)
	local deltas, set = EditService.autowedgeCell(store(), x, y, z)
	rebuildChunks(set, deltas)
end

function T.AutowedgeCells(region: Region3)
	local minX, minY, minZ, maxX, maxY, maxZ = regionToCells(region)
	local deltas, set = EditService.autowedgeRegion(store(), minX, minY, minZ, maxX, maxY, maxZ)
	rebuildChunks(set, deltas)
end

-- ===== Helpers ====================================================================================

-- Collision ray-march: DDA through the voxel grid (no physics raycast). origin/direction in studs;
-- returns the first non-empty cell hit { cellX, cellY, cellZ, face, pos } or nil. --
function T.rayMarch(origin: Vector3, direction: Vector3, maxDistance: number?): Collision.Hit?
	return Collision.rayMarch(store(), origin, direction, maxDistance or 512)
end

-- sampleVoxel(block, material) -> a solid, collidable, UNPARENTED MeshPart of one voxel (cached). --
function T.sampleVoxel(block: any, material: any): MeshPart
	return Mesher.sampleVoxel(val(block), val(material))
end

-- ghostVoxel(block, material) -> a translucent, non-collidable preview MeshPart of one voxel. --
function T.ghostVoxel(block: any, material: any): MeshPart
	local part = Mesher.sampleVoxel(val(block), val(material))
	part.Name = "GhostVoxel"
	part.Transparency = 0.5
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	return part
end

return T
