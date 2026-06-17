--!strict
--[[
	Autowedge — parity with legacy AutowedgeCell/AutowedgeCells. Converts surface
	Solid CUBES into wedge / corner / inverse-corner shapes so stepped terrain reads
	as ramps. Material is preserved; only shape + orientation change; only Solid
	cells with open (Empty OR water) directly above are candidates; water cells and
	already-wedged cells are themselves never reshaped.

	Water counts as OPEN (a drop-off) for every neighbour test, so cubes at the
	water's edge ramp down toward it -> sloped shorelines (the render layer then laps
	water onto those slopes).

	Decision (table-driven, tunable). A candidate's 4 horizontal orthogonal
	neighbours are each "OPEN" if Empty or water (a drop-off edge):
	  0 open                 -> stay Solid (flat top)
	  1 open                 -> VerticalWedge ramping down toward the open side
	  2 open ADJACENT        -> CornerWedge, top corner at the non-open corner
	  2 open OPPOSITE (ridge)-> RIDGE_MODE ("solid" default | "vwedge")
	  3 open (peninsula)     -> PENINSULA_MODE ("corner" default | "solid")
	  4 open (pillar)        -> PILLAR_MODE ("solid")
	Then an INSIDE-CORNER pass (after the convex pass, can override): if two
	ADJACENT neighbours are walls (solid + solid above), convert to
	InverseCornerWedge with the sliced top corner facing the open diagonal.

	Determinism: region() is two-phase (decide all reading the original buffer, then
	apply), so results are independent of iteration order. All orientation outputs
	go through Shape.storedOrientation (the ORIENTATION_REMAP inverse) so they match
	the mesher. Border neighbour reads use store:getCell across chunks; the CALLER
	must ensure neighbour base terrain exists (never treat out-of-chunk as Empty).
]]

local Constants = require(script.Parent.Constants)
local Shape = require(script.Parent.Shape)
local VoxelStore = require(script.Parent.VoxelStore)

local S = Constants.Shape
local WATER = Constants.Material.Water
local unpackByte1 = Constants.unpackByte1
local packByte1 = Constants.packByte1
local packCell = Constants.packCell

local Autowedge = {}

-- Tunable config -----------------------------------------------------------
Autowedge.ENABLED = true
Autowedge.RIDGE_MODE = "solid" -- "solid" | "vwedge"
Autowedge.PENINSULA_MODE = "corner" -- "corner" | "solid"
Autowedge.PILLAR_MODE = "solid" -- "solid"
Autowedge.INSIDE_CORNERS = true

local DIRS = {
	{ dx = 1, dz = 0 },
	{ dx = -1, dz = 0 },
	{ dx = 0, dz = 1 },
	{ dx = 0, dz = -1 },
}
local function dkey(dx: number, dz: number): string
	return dx .. "_" .. dz
end

-- open direction -> VerticalWedge geometric orientation (downhill toward open)
local VW_GEOM = { ["0_-1"] = 0, ["1_0"] = 1, ["0_1"] = 2, ["-1_0"] = 3 }
-- open corner (sum of the two open dirs) -> CornerWedge geom (apex at opposite)
local CW_GEOM = { ["1_1"] = 2, ["1_-1"] = 1, ["-1_-1"] = 0, ["-1_1"] = 3 }
-- open DIAGONAL (dx,dz) -> InverseCornerWedge geom (sliced top corner faces it)
local ICW_GEOM = { ["-1_-1"] = 0, ["1_-1"] = 1, ["1_1"] = 2, ["-1_1"] = 3 }

local function matAt(store: VoxelStore.Store, wx: number, wy: number, wz: number): number
	return (store:getCell(wx, wy, wz))
end
local function isSolidMat(m: number): boolean
	return m ~= 0 and m ~= WATER -- non-empty, non-water terrain
end
-- Water reads as a drop-off (air) for shaping decisions, so shoreline cubes ramp
-- down toward the water exactly as they would toward open air -> sloped shorelines.
local function isOpen(m: number): boolean
	return m == 0 or m == WATER
end

-- Decide the new (shape, geometricOrientation) for a cell, or nil for no change. --
function Autowedge.decide(store: VoxelStore.Store, wx: number, wy: number, wz: number): (number?, number?)
	local mat, byte1 = store:getCell(wx, wy, wz)
	if not isSolidMat(mat) then
		return nil
	end
	if unpackByte1(byte1) ~= S.Solid then
		return nil -- only Solid cubes are candidates (idempotent on a re-pass)
	end
	if not isOpen(matAt(store, wx, wy + 1, wz)) then
		return nil -- not a surface cell (solid directly above); water above is allowed
	end

	local open: { [string]: boolean } = {}
	local openCount = 0
	for _, d in DIRS do
		if isOpen(matAt(store, wx + d.dx, wy, wz + d.dz)) then
			open[dkey(d.dx, d.dz)] = true
			openCount += 1
		end
	end

	local shape: number?, geom: number? = nil, nil
	if openCount == 1 then
		for k in open do
			shape, geom = S.VerticalWedge, VW_GEOM[k]
		end
	elseif openCount == 2 then
		local PX, NX, PZ, NZ = open["1_0"], open["-1_0"], open["0_1"], open["0_-1"]
		if (PX and NX) or (PZ and NZ) then
			if Autowedge.RIDGE_MODE == "vwedge" then
				local k = (PX and "1_0") or (PZ and "0_1") or next(open)
				shape, geom = S.VerticalWedge, VW_GEOM[k]
			end -- else ridge stays Solid
		else
			local ox = (PX and 1 or 0) + (NX and -1 or 0)
			local oz = (PZ and 1 or 0) + (NZ and -1 or 0)
			shape, geom = S.CornerWedge, CW_GEOM[dkey(ox, oz)]
		end
	elseif openCount == 3 then
		if Autowedge.PENINSULA_MODE == "corner" then
			-- closed = the one not open; corner = sum of the two opens perpendicular to it
			local closed
			for _, d in DIRS do
				if not open[dkey(d.dx, d.dz)] then
					closed = d
				end
			end
			local ox, oz = 0, 0
			for _, d in DIRS do
				if open[dkey(d.dx, d.dz)] and not (d.dx == -closed.dx and d.dz == -closed.dz) then
					ox += d.dx
					oz += d.dz
				end
			end
			if ox ~= 0 and oz ~= 0 then
				shape, geom = S.CornerWedge, CW_GEOM[dkey(ox, oz)]
			end
		end
	end
	-- openCount 0 (flat) and 4 (pillar) -> stay Solid here.

	-- INSIDE CORNER (concave): a DIAGONAL neighbour is open (a drop-off) while BOTH
	-- flanking orthogonal neighbours are filled -> slice the top corner toward that
	-- open diagonal so the two straight ramps blend. Purely occupancy-based
	-- (empty vs non-empty), never material. Runs after the convex pass (overrides).
	if Autowedge.INSIDE_CORNERS then
		local diagonals = { { 1, 1 }, { 1, -1 }, { -1, -1 }, { -1, 1 } }
		for _, dg in diagonals do
			local dx, dz = dg[1], dg[2]
			if
				isOpen(matAt(store, wx + dx, wy, wz + dz)) -- diagonal is a drop-off (or water)
				and not isOpen(matAt(store, wx + dx, wy, wz)) -- flanking orthogonal filled
				and not isOpen(matAt(store, wx, wy, wz + dz)) -- flanking orthogonal filled
			then
				shape, geom = S.InverseCornerWedge, ICW_GEOM[dkey(dx, dz)]
				break
			end
		end
	end

	return shape, geom
end

-- Transform a cell box. Two-phase. Returns deltas {wx,wy,wz,value}. --
function Autowedge.region(
	store: VoxelStore.Store,
	minX: number,
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number
): { { number } }
	if not Autowedge.ENABLED then
		return {}
	end
	local decisions: { { number } } = {}
	for wy = minY, maxY do
		for wz = minZ, maxZ do
			for wx = minX, maxX do
				local shape, geom = Autowedge.decide(store, wx, wy, wz)
				if shape then
					decisions[#decisions + 1] = { wx, wy, wz, shape, geom :: number }
				end
			end
		end
	end
	local deltas: { { number } } = {}
	for _, d in decisions do
		local wx, wy, wz, shape, geom = d[1], d[2], d[3], d[4], d[5]
		local mat = matAt(store, wx, wy, wz) -- preserve material
		local byte1 = packByte1(shape, Shape.storedOrientation(shape, geom))
		store:setCell(wx, wy, wz, mat, byte1)
		deltas[#deltas + 1] = { wx, wy, wz, packCell(mat, byte1) }
	end
	return deltas
end

return Autowedge
