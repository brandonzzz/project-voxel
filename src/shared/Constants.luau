--!strict
--[[
	Constants — canonical definitions for the legacy blocky voxel format.

	The voxel buffer is the ONLY source of truth. Every numeric constant the rest
	of the system relies on lives here so the format is defined in exactly one place.

	CELL = 4 studs. CHUNK = 16x16x16 cells (a 64-stud cube). Chunk origins land on
	exact 64-stud multiples. All cell-space math is integer; floats appear only at
	the final CFrame.

	Cell layout (per chunk, Luau `buffer`, 2 bytes/cell, 8192 bytes/chunk):
	  index  = x + z*16 + y*256      (x, z, y each in 0..15)
	  offset = index * 2
	  byte 0 = material id
	  byte 1 = shape/orientation (solids) OR flow force/direction (water)

	As a packed little-endian u16:  value = material + byte1 * 256
]]

local Constants = {}

-- Cell / chunk geometry -----------------------------------------------------
Constants.CELL = 4 -- studs per cell edge
Constants.CHUNK = 16 -- cells per chunk edge
Constants.CHUNK_CELLS = 16 * 16 * 16 -- 4096 cells
Constants.CHUNK_BYTES = 16 * 16 * 16 * 2 -- 8192 bytes
Constants.CHUNK_STUDS = 16 * 4 -- 64 studs per chunk edge

-- Padded neighbour view is 18^3 (local range -1..16 inclusive on each axis).
Constants.PAD = 18
Constants.PAD_CELLS = 18 * 18 * 18

-- Shared world seed so server and client compute the same f(seed) base terrain;
-- only the sparse edit overlay is replicated.
Constants.WORLD_SEED = 2026

-- When true, the SERVER bakes terrain render meshes and delivers them per-player for the client to
-- capture (clone) and display; the client skips its own terrain baking (still builds collision +
-- water locally). When false, the client bakes its own render (the original path). Behind a flag so
-- the two render paths are an A/B with instant fallback. See the server-render architecture findings.
Constants.SERVER_RENDER = false

-- Generation config. Lives here (not per-call) so the server and every client read
-- the SAME parameters -> identical deterministic base terrain. Change here to retune.
--   type      "default" (noise) | "flat" (constant height) | "void" (empty world)
--   period    horizontal noise wavelength in studs (larger = broader hills)
--   amplitude vertical height spread in cells
--   flatHeight surface cell height used when type == "flat"
Constants.GEN = {
	type = "default",
	period = 48,
	amplitude = 3.5,
	flatHeight = 7,
}

-- Material ids (byte 0). 0 = Empty. 17 = Water (special: byte 1 is flow data). --
Constants.Material = {
	Empty = 0,
	Grass = 1,
	Sand = 2,
	Brick = 3,
	Granite = 4,
	Asphalt = 5,
	Iron = 6,
	Aluminum = 7,
	Gold = 8,
	WoodPlank = 9,
	WoodLog = 10,
	Gravel = 11,
	CinderBlock = 12,
	MossyStone = 13,
	Cement = 14,
	RedPlastic = 15,
	BluePlastic = 16,
	Water = 17,
}
Constants.MAX_MATERIAL = 17

-- Block shape (byte 1, bits 0-2 for solids). --
Constants.Shape = {
	Solid = 0,
	VerticalWedge = 1,
	CornerWedge = 2,
	InverseCornerWedge = 3,
	HorizontalWedge = 4,
}

-- Yaw orientation (byte 1, bits 3-4). One step = one -90 degree yaw.
-- Corner (sx, sz, sy) -> (-sz, sx, sy) per step.
Constants.Orientation = {
	NegZ = 0,
	X = 1,
	Z = 2,
	NegX = 3,
}

-- Chunk fill state. ALL_EMPTY / ALL_SOLID chunks carry no buffer. --
Constants.FillState = {
	Empty = 0, -- uniform Empty, no buffer
	Solid = 1, -- uniform non-empty value, no buffer
	Mixed = 2, -- backed by an 8192-byte buffer
}

-- Bit field helpers for byte 1 -------------------------------------------------
-- Solid layout: bits 0-2 shape, bits 3-4 orientation.
-- Water layout: bits 0-2 flow force, bits 3-4 flow direction (same bit math).

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift

function Constants.packByte1(lowBits: number, highBits: number): number
	-- lowBits = shape or flow-force (0..7), highBits = orientation or flow-dir (0..3)
	return bor(band(lowBits, 0x7), lshift(band(highBits, 0x3), 3))
end

function Constants.unpackByte1(byte1: number): (number, number)
	return band(byte1, 0x7), band(rshift(byte1, 3), 0x3)
end

-- Convenience: pack a full 16-bit cell value (material + byte1*256). --
function Constants.packCell(material: number, byte1: number): number
	return band(material, 0xFF) + band(byte1, 0xFF) * 256
end

function Constants.unpackCell(value: number): (number, number)
	return band(value, 0xFF), band(rshift(value, 8), 0xFF)
end

return Constants
