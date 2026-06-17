--!strict
--[[
	Rle — per-chunk palette + run-length codec for serialization (DataStore / network).

	We never store full raw chunks. A chunk compresses to:
	  u16 paletteCount
	  paletteCount x u16  value            (distinct 16-bit cell values, first-seen order)
	  u16 runCount
	  runCount x [ paletteIndex , u16 runLength ]
	      paletteIndex is u8 when paletteCount <= 256, else u16

	The pure buffer codec (encode/decode) round-trips an 8192-byte cell buffer.
	The chunk helpers additionally collapse a single-value palette back into the
	flag-only ALL_EMPTY / ALL_SOLID representation.
]]

local Constants = require(script.Parent.Constants)
local VoxelStore = require(script.Parent.VoxelStore)

local CHUNK_CELLS = Constants.CHUNK_CELLS
local CHUNK_BYTES = Constants.CHUNK_BYTES

local Rle = {}

-- Pure codec: 8192-byte raw cell buffer -> compact buffer. --
function Rle.encode(raw: buffer): buffer
	local valueToIndex: { [number]: number } = {}
	local palette: { number } = {}
	local runValues: { number } = {}
	local runLengths: { number } = {}
	local runCount = 0
	local prevValue: number? = nil

	for i = 0, CHUNK_CELLS - 1 do
		local v = buffer.readu16(raw, i * 2)
		if valueToIndex[v] == nil then
			valueToIndex[v] = #palette -- 0-based palette index
			palette[#palette + 1] = v
		end
		if v == prevValue then
			runLengths[runCount] += 1
		else
			runCount += 1
			runValues[runCount] = valueToIndex[v]
			runLengths[runCount] = 1
			prevValue = v
		end
	end

	local paletteCount = #palette
	local idxBytes = (paletteCount <= 256) and 1 or 2
	local size = 2 + paletteCount * 2 + 2 + runCount * (idxBytes + 2)
	local out = buffer.create(size)

	local off = 0
	buffer.writeu16(out, off, paletteCount)
	off += 2
	for i = 1, paletteCount do
		buffer.writeu16(out, off, palette[i])
		off += 2
	end
	buffer.writeu16(out, off, runCount)
	off += 2
	for r = 1, runCount do
		if idxBytes == 1 then
			buffer.writeu8(out, off, runValues[r])
			off += 1
		else
			buffer.writeu16(out, off, runValues[r])
			off += 2
		end
		buffer.writeu16(out, off, runLengths[r])
		off += 2
	end
	return out
end

-- Pure codec: compact buffer -> 8192-byte raw cell buffer. --
function Rle.decode(compact: buffer): buffer
	local off = 0
	local paletteCount = buffer.readu16(compact, off)
	off += 2
	local palette = table.create(paletteCount)
	for i = 1, paletteCount do
		palette[i] = buffer.readu16(compact, off)
		off += 2
	end
	local idxBytes = (paletteCount <= 256) and 1 or 2
	local runCount = buffer.readu16(compact, off)
	off += 2

	local raw = buffer.create(CHUNK_BYTES)
	local cell = 0
	for _ = 1, runCount do
		local idx
		if idxBytes == 1 then
			idx = buffer.readu8(compact, off)
			off += 1
		else
			idx = buffer.readu16(compact, off)
			off += 2
		end
		local len = buffer.readu16(compact, off)
		off += 2
		local v = palette[idx + 1]
		for _ = 1, len do
			buffer.writeu16(raw, cell * 2, v)
			cell += 1
		end
	end
	return raw
end

-- Chunk -> compact buffer (reads through flag-only chunks without materialising
-- them permanently). --
function Rle.encodeChunk(chunk: VoxelStore.Chunk): buffer
	return Rle.encode(VoxelStore.chunkToRawBuffer(chunk))
end

-- compact buffer -> Chunk. A single-value palette decodes straight back into the
-- flag-only ALL_EMPTY / ALL_SOLID form (no buffer allocated). --
function Rle.decodeChunk(compact: buffer, cx: number, cy: number, cz: number): VoxelStore.Chunk
	local paletteCount = buffer.readu16(compact, 0)
	if paletteCount == 1 then
		local v = buffer.readu16(compact, 2)
		local state = (v == 0) and Constants.FillState.Empty or Constants.FillState.Solid
		return VoxelStore.newChunk(cx, cy, cz, state, v)
	end
	local chunk = VoxelStore.newChunk(cx, cy, cz, Constants.FillState.Mixed, 0)
	chunk.buf = Rle.decode(compact)
	return chunk
end

return Rle
