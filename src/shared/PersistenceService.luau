--!strict
--[[
	PersistenceService — persist the sparse edit overlay (world = f(seed) + edits).

	Per edited chunk we build a "delta chunk": an 8192-byte cell buffer where every
	UNEDITED cell holds the sentinel 0xFFFF (never a real value, since max material
	is 17) and edited cells hold their packed value (0 = carved). The M1 Rle codec
	then compresses the long sentinel runs. Delta chunks are grouped into region
	shards (REGION_CHUNKS x REGION_CHUNKS) and stored under one DataStore key each,
	base64-encoded so the binary RLE is DataStore-safe.
]]

local Constants = require(script.Parent.Constants)
local Rle = require(script.Parent.Rle)
local VoxelStore = require(script.Parent.VoxelStore)

local CHUNK = Constants.CHUNK
local CHUNK_BYTES = Constants.CHUNK_BYTES
local CHUNK_CELLS = Constants.CHUNK_CELLS
local SENTINEL = 0xFFFF

local PersistenceService = {}

PersistenceService.REGION_CHUNKS = 8

-- base64 (binary buffer <-> ASCII string) -----------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64REV: { [number]: number } = {}
for i = 1, #B64 do
	B64REV[string.byte(B64, i)] = i - 1
end

function PersistenceService.base64encode(buf: buffer): string
	local n = buffer.len(buf)
	local out = {}
	local i = 0
	while i < n do
		local b0 = buffer.readu8(buf, i)
		local b1 = i + 1 < n and buffer.readu8(buf, i + 1) or 0
		local b2 = i + 2 < n and buffer.readu8(buf, i + 2) or 0
		local triple = b0 * 65536 + b1 * 256 + b2
		local c0 = math.floor(triple / 262144) % 64
		local c1 = math.floor(triple / 4096) % 64
		local c2 = math.floor(triple / 64) % 64
		local c3 = triple % 64
		out[#out + 1] = string.sub(B64, c0 + 1, c0 + 1)
		out[#out + 1] = string.sub(B64, c1 + 1, c1 + 1)
		out[#out + 1] = (i + 1 < n) and string.sub(B64, c2 + 1, c2 + 1) or "="
		out[#out + 1] = (i + 2 < n) and string.sub(B64, c3 + 1, c3 + 1) or "="
		i += 3
	end
	return table.concat(out)
end

function PersistenceService.base64decode(s: string): buffer
	-- strip padding
	local clean = string.gsub(s, "=", "")
	local outBytes = math.floor(#clean * 6 / 8)
	local buf = buffer.create(outBytes)
	local bitbuf, bits, oi = 0, 0, 0
	for i = 1, #clean do
		local v = B64REV[string.byte(clean, i)]
		bitbuf = bitbuf * 64 + v
		bits += 6
		if bits >= 8 then
			bits -= 8
			local byte = math.floor(bitbuf / (2 ^ bits)) % 256
			buffer.writeu8(buf, oi, byte)
			oi += 1
			bitbuf = bitbuf % (2 ^ bits) -- keep only the unconsumed low bits (avoid float overflow)
		end
	end
	return buf
end

-- delta chunk codec ---------------------------------------------------------
-- edits: { [cellIndex 0..4095] = value16 }. Returns an RLE buffer. --
function PersistenceService.encodeChunkDeltas(edits: { [number]: number }): buffer
	local raw = buffer.create(CHUNK_BYTES)
	for i = 0, CHUNK_CELLS - 1 do
		buffer.writeu16(raw, i * 2, SENTINEL)
	end
	for idx, val in edits do
		buffer.writeu16(raw, idx * 2, val)
	end
	return Rle.encode(raw)
end

function PersistenceService.decodeChunkDeltas(rle: buffer): { [number]: number }
	local raw = Rle.decode(rle)
	local edits: { [number]: number } = {}
	for i = 0, CHUNK_CELLS - 1 do
		local v = buffer.readu16(raw, i * 2)
		if v ~= SENTINEL then
			edits[i] = v
		end
	end
	return edits
end

function PersistenceService.regionOf(cx: number, cz: number): (number, number)
	local r = PersistenceService.REGION_CHUNKS
	return math.floor(cx / r), math.floor(cz / r)
end

function PersistenceService.regionKey(rx: number, rz: number): string
	return string.format("region_%d_%d", rx, rz)
end

-- overlay : { [chunkKey "cx_cy_cz"] = { cellIndex -> value } }
-- Build the DataStore table for one region: { [chunkKey] = base64(rleDeltas) }. --
function PersistenceService.serializeRegion(
	overlay: { [string]: { [number]: number } },
	rx: number,
	rz: number
): { [string]: string }
	local r = PersistenceService.REGION_CHUNKS
	local data: { [string]: string } = {}
	for chunkKey, edits in overlay do
		local cx, cy, cz = string.match(chunkKey, "(-?%d+)_(-?%d+)_(-?%d+)")
		local cxi = tonumber(cx) :: number
		local czi = tonumber(cz) :: number
		if math.floor(cxi / r) == rx and math.floor(czi / r) == rz then
			data[chunkKey] = PersistenceService.base64encode(PersistenceService.encodeChunkDeltas(edits))
		end
	end
	return data
end

-- Decode a region's stored data into a flat delta list {wx,wy,wz,value}. NO store side
-- effect -- callers that must keep autowedge seeing only BASE terrain use this to populate
-- their edit overlay, then re-apply the edits themselves AFTER autowedge. --
function PersistenceService.decodeRegion(data: { [string]: string }): { { number } }
	local deltas: { { number } } = {}
	for chunkKey, b64 in data do
		local cx, cy, cz = string.match(chunkKey, "(-?%d+)_(-?%d+)_(-?%d+)")
		local cxi = tonumber(cx) :: number
		local cyi = tonumber(cy) :: number
		local czi = tonumber(cz) :: number
		local edits = PersistenceService.decodeChunkDeltas(PersistenceService.base64decode(b64))
		for idx, val in edits do
			local lx = idx % CHUNK
			local lz = math.floor(idx / CHUNK) % CHUNK
			local ly = math.floor(idx / (CHUNK * CHUNK))
			deltas[#deltas + 1] = { cxi * CHUNK + lx, cyi * CHUNK + ly, czi * CHUNK + lz, val }
		end
	end
	return deltas
end

-- Decode + write a region's edits straight into a store; returns the same deltas. (Kept for
-- callers that want a populated store directly; the server load path uses decodeRegion so
-- that autowedge only ever sees base terrain.) --
function PersistenceService.applyRegion(store: VoxelStore.Store, data: { [string]: string }): { { number } }
	local deltas = PersistenceService.decodeRegion(data)
	for _, d in deltas do
		store:setCell(d[1], d[2], d[3], Constants.unpackCell(d[4]))
	end
	return deltas
end

return PersistenceService
