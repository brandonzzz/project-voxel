--!strict
--[[
	VoxelStore — the single source of truth for cell data.

	Chunks are keyed by integer chunk coordinate (cx, cy, cz). A chunk is one of:
	  Empty  — uniform Empty (value 0), no buffer allocated
	  Solid  — uniform non-empty value, no buffer allocated
	  Mixed  — backed by an 8192-byte `buffer`

	Writing a value that differs from a uniform chunk's fill "materialises" it
	(allocates the buffer, fills with the prior uniform value, flips to Mixed).
	This keeps flat regions (sky / bedrock) free of buffer allocations.

	World cell coordinates (wx, wy, wz) are integer cell indices, NOT studs.
	Convert to studs only at the final CFrame:  studs = cell * Constants.CELL.
]]

local Constants = require(script.Parent.Constants)

local CHUNK = Constants.CHUNK
local CHUNK_BYTES = Constants.CHUNK_BYTES
local CHUNK_CELLS = Constants.CHUNK_CELLS
local FillState = Constants.FillState
local PAD = Constants.PAD

export type Chunk = {
	cx: number,
	cy: number,
	cz: number,
	state: number,
	fillValue: number, -- meaningful when state ~= Mixed
	buf: buffer?, -- present iff state == Mixed
}

local VoxelStore = {}
VoxelStore.__index = VoxelStore

export type Store = typeof(setmetatable(
	{} :: { chunks: { [string]: Chunk }, count: number },
	VoxelStore
))

-- Index helpers --------------------------------------------------------------

-- Local cell index within a chunk: x + z*16 + y*256  (x, z, y each 0..15).
local function localIndex(x: number, y: number, z: number): number
	return x + z * CHUNK + y * (CHUNK * CHUNK)
end
VoxelStore.localIndex = localIndex

-- Floor-divide a world cell coord into (chunkCoord, localCoord 0..15).
local function worldToChunk(w: number): (number, number)
	local l = w % CHUNK -- non-negative for the positive divisor
	return (w - l) // CHUNK, l
end
VoxelStore.worldToChunk = worldToChunk

local function chunkKey(cx: number, cy: number, cz: number): string
	return string.format("%d_%d_%d", cx, cy, cz)
end
VoxelStore.chunkKey = chunkKey

-- Chunk-level primitives -----------------------------------------------------

local function newChunk(cx: number, cy: number, cz: number, state: number?, fillValue: number?): Chunk
	return {
		cx = cx,
		cy = cy,
		cz = cz,
		state = state or FillState.Empty,
		fillValue = fillValue or 0,
		buf = nil,
	}
end
VoxelStore.newChunk = newChunk

local function materialize(chunk: Chunk)
	if chunk.state == FillState.Mixed then
		return
	end
	local buf = buffer.create(CHUNK_BYTES)
	local fill = chunk.fillValue
	if fill ~= 0 then
		for i = 0, CHUNK_CELLS - 1 do
			buffer.writeu16(buf, i * 2, fill)
		end
	end
	chunk.buf = buf
	chunk.state = FillState.Mixed
end

local function chunkGetRaw(chunk: Chunk, idx: number): number
	if chunk.state == FillState.Mixed then
		return buffer.readu16(chunk.buf :: buffer, idx * 2)
	end
	return chunk.fillValue
end
VoxelStore.chunkGetRaw = chunkGetRaw

local function chunkSetRaw(chunk: Chunk, idx: number, value: number)
	if chunk.state ~= FillState.Mixed then
		if value == chunk.fillValue then
			return -- no change vs the uniform fill; stay flag-only
		end
		materialize(chunk)
	end
	buffer.writeu16(chunk.buf :: buffer, idx * 2, value)
end
VoxelStore.chunkSetRaw = chunkSetRaw

-- Materialised 8192-byte copy of a chunk's cells (for serialization). --
local function chunkToRawBuffer(chunk: Chunk): buffer
	local raw = buffer.create(CHUNK_BYTES)
	if chunk.state == FillState.Mixed then
		buffer.copy(raw, 0, chunk.buf :: buffer, 0, CHUNK_BYTES)
	else
		local fill = chunk.fillValue
		if fill ~= 0 then
			for i = 0, CHUNK_CELLS - 1 do
				buffer.writeu16(raw, i * 2, fill)
			end
		end
	end
	return raw
end
VoxelStore.chunkToRawBuffer = chunkToRawBuffer

-- Store API ------------------------------------------------------------------

function VoxelStore.new(): Store
	return setmetatable({ chunks = {}, count = 0 }, VoxelStore)
end

function VoxelStore.getChunk(self: Store, cx: number, cy: number, cz: number): Chunk?
	return self.chunks[chunkKey(cx, cy, cz)]
end

function VoxelStore.ensureChunk(self: Store, cx: number, cy: number, cz: number): Chunk
	local key = chunkKey(cx, cy, cz)
	local chunk = self.chunks[key]
	if not chunk then
		chunk = newChunk(cx, cy, cz)
		self.chunks[key] = chunk
		self.count += 1
	end
	return chunk
end

-- Insert / replace a whole chunk (used by the RLE decoder). --
function VoxelStore.setChunk(self: Store, chunk: Chunk)
	local key = chunkKey(chunk.cx, chunk.cy, chunk.cz)
	if self.chunks[key] == nil then
		self.count += 1
	end
	self.chunks[key] = chunk
end

-- If a Mixed chunk's buffer holds a single value throughout, collapse it back to a flag-only uniform
-- chunk and free the 8 KB buffer. Transparent to every reader (uniform chunks return fillValue). This
-- is what keeps the 3D streaming sphere cheap: deep bedrock (cy <= -2) fills as uniform granite, and
-- sky as uniform Empty, so most off-surface chunks carry no buffer. Returns true if collapsed. --
function VoxelStore.compactChunk(self: Store, cx: number, cy: number, cz: number): boolean
	local chunk = self.chunks[chunkKey(cx, cy, cz)]
	if not chunk or chunk.state ~= FillState.Mixed then
		return false
	end
	local buf = chunk.buf :: buffer
	local v0 = buffer.readu16(buf, 0)
	for i = 1, CHUNK_CELLS - 1 do
		if buffer.readu16(buf, i * 2) ~= v0 then
			return false -- genuinely mixed; keep the buffer
		end
	end
	chunk.fillValue = v0
	chunk.state = (v0 == 0) and FillState.Empty or FillState.Solid
	chunk.buf = nil
	return true
end

-- World-space cell access ----------------------------------------------------

function VoxelStore.getCell(self: Store, wx: number, wy: number, wz: number): (number, number)
	local cx, lx = worldToChunk(wx)
	local cy, ly = worldToChunk(wy)
	local cz, lz = worldToChunk(wz)
	local chunk = self.chunks[chunkKey(cx, cy, cz)]
	if not chunk then
		return 0, 0
	end
	return Constants.unpackCell(chunkGetRaw(chunk, localIndex(lx, ly, lz)))
end

function VoxelStore.setCell(self: Store, wx: number, wy: number, wz: number, material: number, byte1: number)
	local cx, lx = worldToChunk(wx)
	local cy, ly = worldToChunk(wy)
	local cz, lz = worldToChunk(wz)
	local chunk = self:ensureChunk(cx, cy, cz)
	chunkSetRaw(chunk, localIndex(lx, ly, lz), Constants.packCell(material, byte1))
end

-- Raw 16-bit value at a world cell; 0 (Empty) when the chunk is absent. --
function VoxelStore.sampleValue(self: Store, wx: number, wy: number, wz: number): number
	local cx, lx = worldToChunk(wx)
	local cy, ly = worldToChunk(wy)
	local cz, lz = worldToChunk(wz)
	local chunk = self.chunks[chunkKey(cx, cy, cz)]
	if not chunk then
		return 0
	end
	return chunkGetRaw(chunk, localIndex(lx, ly, lz))
end

-- Fast reader for ONE chunk's own cells: pre-resolves the chunk (no per-cell worldToChunk, string
-- chunkKey, or table lookup), returning (lx, ly, lz in 0..15) -> raw 16-bit value (0 if the chunk is
-- absent). For chunk-local 16^3 scans (collision/water masks) this is far cheaper than getCell per
-- cell. Uniform chunks return their fill directly; Mixed chunks read the buffer inline. --
function VoxelStore.makeChunkReader(self: Store, cx: number, cy: number, cz: number): (number, number, number) -> number
	local chunk = self.chunks[chunkKey(cx, cy, cz)]
	if not chunk then
		return function(): number
			return 0
		end
	end
	if chunk.state ~= FillState.Mixed then
		local fill = chunk.fillValue
		return function(): number
			return fill
		end
	end
	local buf = chunk.buf :: buffer
	return function(lx: number, ly: number, lz: number): number
		return buffer.readu16(buf, (lx + lz * CHUNK + ly * (CHUNK * CHUNK)) * 2)
	end
end

-- Neighbour sampling ---------------------------------------------------------

-- Map a local coord in -16..31 to (neighbourOffset -1..1, inChunkLocal 0..15).
local function ncoord(l: number): (number, number)
	if l < 0 then
		return -1, l + CHUNK
	elseif l >= CHUNK then
		return 1, l - CHUNK
	end
	return 0, l
end

-- Returns a closure sampling cell VALUES at local coords lx,ly,lz in -1..16,
-- transparently reading neighbour chunks at the borders. Out-of-world -> 0.
-- NEVER treats out-of-chunk as empty unless the neighbour chunk truly is absent.
function VoxelStore.makeNeighborSampler(self: Store, cx: number, cy: number, cz: number)
	-- Pre-resolve the 3x3x3 block of neighbour chunks once.
	local chunks: { Chunk? } = {}
	for dy = -1, 1 do
		for dz = -1, 1 do
			for dx = -1, 1 do
				chunks[(dx + 1) + (dz + 1) * 3 + (dy + 1) * 9] = self.chunks[chunkKey(cx + dx, cy + dy, cz + dz)]
			end
		end
	end
	return function(lx: number, ly: number, lz: number): number
		local nx, ix = ncoord(lx)
		local ny, iy = ncoord(ly)
		local nz, iz = ncoord(lz)
		local chunk = chunks[(nx + 1) + (nz + 1) * 3 + (ny + 1) * 9]
		if not chunk then
			return 0
		end
		return chunkGetRaw(chunk, ix + iz * CHUNK + iy * (CHUNK * CHUNK))
	end
end

-- Padded index within an 18^3 view: px,py,pz in 0..17 (local coord = p - 1). --
local function paddedIndex(px: number, py: number, pz: number): number
	return px + pz * PAD + py * (PAD * PAD)
end
VoxelStore.paddedIndex = paddedIndex

-- Build a flat 18^3 buffer of cell values for the mesher's hot loop. Cell at
-- local (lx,ly,lz) in -1..16 lives at paddedIndex(lx+1, ly+1, lz+1).
function VoxelStore.buildPaddedView(self: Store, cx: number, cy: number, cz: number): buffer
	local sampler = self:makeNeighborSampler(cx, cy, cz)
	local buf = buffer.create(Constants.PAD_CELLS * 2)
	for py = 0, PAD - 1 do
		for pz = 0, PAD - 1 do
			for px = 0, PAD - 1 do
				buffer.writeu16(buf, paddedIndex(px, py, pz) * 2, sampler(px - 1, py - 1, pz - 1))
			end
		end
	end
	return buf
end

return VoxelStore
