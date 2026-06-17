--!strict
--[[
	EditService — applies cell edits and explosions to a VoxelStore and reports
	which chunks must be re-meshed. The voxel buffer is the source of truth; this
	just mutates it and returns deltas + affected chunks. Server validates and
	calls these; clients apply the broadcast deltas and dirty-rebuild.

	A delta is { wx, wy, wz, value } where value is the packed 16-bit cell
	(0 = carved/empty). An edit on a chunk border also affects the neighbour chunk
	across that border, because border face-culling depends on the edited cell.
]]

local Constants = require(script.Parent.Constants)
local VoxelStore = require(script.Parent.VoxelStore)
local Autowedge = require(script.Parent.Autowedge)

local CHUNK = Constants.CHUNK
local worldToChunk = VoxelStore.worldToChunk
local packCell = Constants.packCell

local EditService = {}

export type ChunkCoord = { cx: number, cy: number, cz: number }

-- Chunk(s) whose mesh depends on world cell (wx,wy,wz): its own chunk plus any
-- neighbour across a border the cell sits on. --
function EditService.affectedChunks(wx: number, wy: number, wz: number): { ChunkCoord }
	local cx, lx = worldToChunk(wx)
	local cy, ly = worldToChunk(wy)
	local cz, lz = worldToChunk(wz)
	local out: { ChunkCoord } = { { cx = cx, cy = cy, cz = cz } }
	if lx == 0 then
		out[#out + 1] = { cx = cx - 1, cy = cy, cz = cz }
	elseif lx == CHUNK - 1 then
		out[#out + 1] = { cx = cx + 1, cy = cy, cz = cz }
	end
	if ly == 0 then
		out[#out + 1] = { cx = cx, cy = cy - 1, cz = cz }
	elseif ly == CHUNK - 1 then
		out[#out + 1] = { cx = cx, cy = cy + 1, cz = cz }
	end
	if lz == 0 then
		out[#out + 1] = { cx = cx, cy = cy, cz = cz - 1 }
	elseif lz == CHUNK - 1 then
		out[#out + 1] = { cx = cx, cy = cy, cz = cz + 1 }
	end
	return out
end

local function addAffected(set: { [string]: ChunkCoord }, wx: number, wy: number, wz: number)
	for _, c in EditService.affectedChunks(wx, wy, wz) do
		set[string.format("%d_%d_%d", c.cx, c.cy, c.cz)] = c
	end
end

-- Set a single cell. Returns (delta, affectedSet). --
function EditService.applyEdit(
	store: VoxelStore.Store,
	wx: number,
	wy: number,
	wz: number,
	material: number,
	byte1: number
): ({ number }, { [string]: ChunkCoord })
	store:setCell(wx, wy, wz, material, byte1)
	local affected: { [string]: ChunkCoord } = {}
	addAffected(affected, wx, wy, wz)
	return { wx, wy, wz, packCell(material, byte1) }, affected
end

-- Carve a sphere (radius in cells) centred on a cell. `ensureGenerated(cx,cy,cz)`
-- must lazily generate base terrain so carved values are correct. Returns
-- (deltas, affectedSet). Only previously non-empty cells become deltas. --
function EditService.explode(
	store: VoxelStore.Store,
	ensureGenerated: (number, number, number) -> (),
	cwx: number,
	cwy: number,
	cwz: number,
	radius: number
): ({ { number } }, { [string]: ChunkCoord })
	local deltas: { { number } } = {}
	local affected: { [string]: ChunkCoord } = {}
	local r2 = radius * radius
	local ri = math.ceil(radius)
	for dy = -ri, ri do
		for dz = -ri, ri do
			for dx = -ri, ri do
				if dx * dx + dy * dy + dz * dz <= r2 then
					local wx, wy, wz = cwx + dx, cwy + dy, cwz + dz
					local cx = worldToChunk(wx)
					local cy = worldToChunk(wy)
					local cz = worldToChunk(wz)
					ensureGenerated(cx, cy, cz)
					local mat = store:getCell(wx, wy, wz)
					if mat ~= 0 then
						store:setCell(wx, wy, wz, 0, 0)
						deltas[#deltas + 1] = { wx, wy, wz, 0 }
						addAffected(affected, wx, wy, wz)
					end
				end
			end
		end
	end
	return deltas, affected
end

-- Autowedge a cell box. Returns (deltas, affectedSet) exactly like the edit ops.
-- Generation runs this client-side (deterministic, no replication); explosions
-- run it server-side and replicate the deltas. Autowedge.decide is material-based
-- so server (cube store) and client (already-wedged store) agree. --
function EditService.autowedgeRegion(
	store: VoxelStore.Store,
	minX: number,
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number
): ({ { number } }, { [string]: ChunkCoord })
	local deltas = Autowedge.region(store, minX, minY, minZ, maxX, maxY, maxZ)
	local affected: { [string]: ChunkCoord } = {}
	for _, d in deltas do
		addAffected(affected, d[1], d[2], d[3])
	end
	return deltas, affected
end

function EditService.autowedgeCell(
	store: VoxelStore.Store,
	wx: number,
	wy: number,
	wz: number
): ({ { number } }, { [string]: ChunkCoord })
	return EditService.autowedgeRegion(store, wx, wy, wz, wx, wy, wz)
end

return EditService
