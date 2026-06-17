--!strict
--[[
	Shape — corner-set model, yaw rotation, and axis-face coverage derivation.

	Every shape is the convex hull of a subset of the cell's 8 corners. A corner
	is a sign triple (sx, sy, sz), each in {-1, +1}, around the cell centre.

	Corner sets at orientation 0:
	  Solid               all 8
	  VerticalWedge       all except top(x-,z-), top(x+,z-)   (downhill side z-)
	  HorizontalWedge     all except bottom(x-,z-), top(x-,z-)(missing corner column)
	  CornerWedge         bottom 4 + top(x+,z+)
	  InverseCornerWedge  all except top(x-,z-)

	Orientation step (one -90 yaw; o0->o1->o2->o3):
	  (sx, sz, sy) -> (-sz, sx, sy)
	In (x,y,z) terms one step is: nx = -z, ny = y, nz = x.

	AXIS-FACE COVERAGE: each axis face has 4 cell corners. Of those, the count of
	corners present in the shape gives:
	  4 -> FULL (F)
	  3 -> TRI  (right-angle corner diagonally opposite the missing corner)
	  <=2 -> NONE (N)
	Face params use WORLD axes so opposing neighbour faces compare directly:
	  +-X faces -> (Z, Y) ; +-Z -> (X, Y) ; +-Y -> (X, Z).

	Geometry (vertex positions / slope faces) is DERIVED from the hull, never
	hand-authored. Coverage is reported as a normalised string the M2 oracle test
	compares against the calibration table.
]]

local Constants = require(script.Parent.Constants)

local Shape = {}

Shape.Id = Constants.Shape
Shape.SHAPES = {
	Constants.Shape.Solid,
	Constants.Shape.VerticalWedge,
	Constants.Shape.CornerWedge,
	Constants.Shape.InverseCornerWedge,
	Constants.Shape.HorizontalWedge,
}

-- CALIBRATION: maps a STORED orientation bit value -> geometric orientation used
-- for meshing. After the Milestone 2 visual comparison the user confirmed the
-- yaw direction is correct but CornerWedge / InverseCornerWedge / HorizontalWedge
-- needed one extra -90 yaw step (stored o0 renders as geometric o1, etc.).
-- VerticalWedge and Solid stay identity. Fix any further phase issues HERE only.
-- Indexed [shapeId][storedOrientation 0..3] = geometricOrientation 0..3.
Shape.ORIENTATION_REMAP = {} :: { [number]: { [number]: number } }
for _, sid in Shape.SHAPES do
	Shape.ORIENTATION_REMAP[sid] = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 }
end
for _, sid in { Constants.Shape.CornerWedge, Constants.Shape.InverseCornerWedge, Constants.Shape.HorizontalWedge } do
	Shape.ORIENTATION_REMAP[sid] = { [0] = 1, [1] = 2, [2] = 3, [3] = 0 }
end

function Shape.geomOrientation(shapeId: number, storedO: number): number
	return Shape.ORIENTATION_REMAP[shapeId][storedO]
end

-- Inverse remap: geometric orientation -> stored orientation bits. Autowedge
-- decides a geometric orientation and must persist the bits that render it, so it
-- stays consistent with the mesher (never bypass the remap).
Shape.ORIENTATION_REMAP_INV = {} :: { [number]: { [number]: number } }
for sid, fwd in Shape.ORIENTATION_REMAP do
	local inv = {}
	for storedO, geomO in fwd do
		inv[geomO] = storedO
	end
	Shape.ORIENTATION_REMAP_INV[sid] = inv
end

function Shape.storedOrientation(shapeId: number, geomO: number): number
	return Shape.ORIENTATION_REMAP_INV[shapeId][geomO]
end

-- Corner-sign key 0..7 ( bit2=x+, bit1=y+, bit0=z+ ). --
local function key(x: number, y: number, z: number): number
	return (x > 0 and 4 or 0) + (y > 0 and 2 or 0) + (z > 0 and 1 or 0)
end
Shape.cornerKey = key

local SIGNS = { -1, 1 }

local function allCorners(): { { x: number, y: number, z: number } }
	local t = {}
	for _, x in SIGNS do
		for _, y in SIGNS do
			for _, z in SIGNS do
				t[#t + 1] = { x = x, y = y, z = z }
			end
		end
	end
	return t
end

-- Base (orientation 0) corner sets, expressed as the set of keys to KEEP. ----
local function buildBaseSets(): { [number]: { [number]: boolean } }
	local keep: { [number]: { [number]: boolean } } = {}

	local function fromExclusion(excluded: { number }): { [number]: boolean }
		local set: { [number]: boolean } = {}
		for _, c in allCorners() do
			set[key(c.x, c.y, c.z)] = true
		end
		for _, k in excluded do
			set[k] = nil
		end
		return set
	end

	-- top(x-,z-) = key(-1,+1,-1)=2 ; top(x+,z-) = key(+1,+1,-1)=6
	-- bottom(x-,z-) = key(-1,-1,-1)=0
	keep[Constants.Shape.Solid] = fromExclusion({})
	keep[Constants.Shape.VerticalWedge] = fromExclusion({ 2, 6 })
	keep[Constants.Shape.HorizontalWedge] = fromExclusion({ 0, 2 })
	keep[Constants.Shape.InverseCornerWedge] = fromExclusion({ 2 })
	-- CornerWedge (the legacy "Corner"): a corner TETRAHEDRON, not a square pyramid.
	-- Triangular base + a single triangular slope face. Bottom right-triangle at
	-- {(x+,z+),(x-,z+),(x+,z-)} with the apex over the right-angle corner (x+,z+).
	--   (x+,y-,z+)=key 5  (x-,y-,z+)=key 1  (x+,y-,z-)=key 4  (x+,y+,z+)=key 7
	keep[Constants.Shape.CornerWedge] = { [5] = true, [1] = true, [4] = true, [7] = true }

	return keep
end

local BASE_SETS = buildBaseSets()

-- One -90 yaw step applied to a corner: (x,y,z) -> (-z, y, x). --
local function rotateOnce(x: number, y: number, z: number): (number, number, number)
	return -z, y, x
end

export type CornerSet = {
	keys: { [number]: boolean }, -- presence by corner key 0..7
	list: { { x: number, y: number, z: number } }, -- present corners
}

-- Cache all 5 shapes x 4 orientations. --
local CORNER_SETS: { [number]: { [number]: CornerSet } } = {}
for _, sid in Shape.SHAPES do
	CORNER_SETS[sid] = {}
	local base = BASE_SETS[sid]
	for o = 0, 3 do
		local keys: { [number]: boolean } = {}
		local list = {}
		for _, c in allCorners() do
			if base[key(c.x, c.y, c.z)] then
				local x, y, z = c.x, c.y, c.z
				for _ = 1, o do
					x, y, z = rotateOnce(x, y, z)
				end
				keys[key(x, y, z)] = true
				list[#list + 1] = { x = x, y = y, z = z }
			end
		end
		CORNER_SETS[sid][o] = { keys = keys, list = list }
	end
end

function Shape.cornerSet(shapeId: number, o: number): CornerSet
	return CORNER_SETS[shapeId][o]
end

-- Axis-face definitions. A = param axis 1, B = param axis 2 (world axes). -----
export type Face = { name: string, axis: string, sign: number, A: string, B: string }
Shape.FACES = {
	{ name = "+X", axis = "X", sign = 1, A = "Z", B = "Y" },
	{ name = "-X", axis = "X", sign = -1, A = "Z", B = "Y" },
	{ name = "+Y", axis = "Y", sign = 1, A = "X", B = "Z" },
	{ name = "-Y", axis = "Y", sign = -1, A = "X", B = "Z" },
	{ name = "+Z", axis = "Z", sign = 1, A = "X", B = "Y" },
	{ name = "-Z", axis = "Z", sign = -1, A = "X", B = "Y" },
} :: { Face }

-- Build the cell corner sitting at (paramA sign As, paramB sign Bs) on a face. --
local function faceCorner(face: Face, As: number, Bs: number): (number, number, number)
	if face.axis == "X" then
		return face.sign, Bs, As -- x = sign, A=Z -> z=As, B=Y -> y=Bs
	elseif face.axis == "Y" then
		return As, face.sign, Bs -- y = sign, A=X -> x=As, B=Z -> z=Bs
	else
		return As, Bs, face.sign -- z = sign, A=X -> x=As, B=Y -> y=Bs
	end
end

local function signChar(s: number): string
	return s > 0 and "+" or "-"
end

-- Normalised coverage token: "F", "N", or "T:<ra><rb>" where ra/rb are the
-- right-angle corner's param-A / param-B signs. --
function Shape.faceCoverage(shapeId: number, o: number, faceIndex: number): string
	local set = CORNER_SETS[shapeId][o].keys
	local face = Shape.FACES[faceIndex]
	local present = 0
	local missingA, missingB = 0, 0
	for _, As in SIGNS do
		for _, Bs in SIGNS do
			local x, y, z = faceCorner(face, As, Bs)
			if set[key(x, y, z)] then
				present += 1
			else
				missingA, missingB = As, Bs
			end
		end
	end
	if present == 4 then
		return "F"
	elseif present == 3 then
		-- right-angle corner is diagonally opposite the single missing corner
		return string.format("T:%s%s", signChar(-missingA), signChar(-missingB))
	end
	return "N"
end

-- 4-bit present-corner mask for the M3 cull rule. Bit = (As>0 and 1 or 0) +
-- (Bs>0 and 2 or 0). Opposing faces share param axes so masks compare directly. --
function Shape.faceMaskBits(shapeId: number, o: number, faceIndex: number): number
	local set = CORNER_SETS[shapeId][o].keys
	local face = Shape.FACES[faceIndex]
	local mask = 0
	for _, As in SIGNS do
		for _, Bs in SIGNS do
			local x, y, z = faceCorner(face, As, Bs)
			if set[key(x, y, z)] then
				local bit = (As > 0 and 1 or 0) + (Bs > 0 and 2 or 0)
				mask += 2 ^ bit
			end
		end
	end
	return mask
end

-- Hull geometry --------------------------------------------------------------
-- Triangulated convex hull of the shape's present corners, derived (NOT hand-
-- authored). Coordinates are cell-local studs centred at the cell centre, so a
-- corner sign (x,y,z) sits at (x,y,z) * (CELL/2). Each triangle carries its
-- outward face normal and an `isSlope` flag (normal not axis-aligned).
-- Winding is CCW viewed from outside, so the front face points outward.

local H = Constants.CELL / 2
local EPS = 1e-4

-- `face` = FACES index 1..6 (+X,-X,+Y,-Y,+Z,-Z) for axis faces, or 0 for slope. --
export type Tri = { a: Vector3, b: Vector3, c: Vector3, n: Vector3, isSlope: boolean, face: number }

-- Map an axis-aligned normal to its FACES index, or 0 when the normal is a slope. --
local function normalToFace(n: Vector3): number
	if n.X > 0.999 then
		return 1
	elseif n.X < -0.999 then
		return 2
	elseif n.Y > 0.999 then
		return 3
	elseif n.Y < -0.999 then
		return 4
	elseif n.Z > 0.999 then
		return 5
	elseif n.Z < -0.999 then
		return 6
	end
	return 0
end

local HULL_CACHE: { [number]: { [number]: { Tri } } } = {}

-- Round to 1e-3 and force -0 -> 0 so coplanar faces share one stable key. --
local function snap(x: number): number
	local r = math.floor(x * 1000 + 0.5) / 1000
	return r == 0 and 0 or r
end

local function buildHull(shapeId: number, o: number): { Tri }
	local list = CORNER_SETS[shapeId][o].list
	local pts: { Vector3 } = {}
	for _, c in list do
		pts[#pts + 1] = Vector3.new(c.x * H, c.y * H, c.z * H)
	end
	local count = #pts

	-- Collect unique supporting planes (each = one polygonal hull face). A triple
	-- defines a hull face iff every other point lies on ONE side of its plane; the
	-- outward normal is whichever sign makes `d` the maximum over all points (so
	-- orientation is correct even for slope faces passing through the cell centre).
	local planes: { [string]: { normal: Vector3, d: number } } = {}
	for i = 1, count do
		for j = i + 1, count do
			for k = j + 1, count do
				local pi, pj, pk = pts[i], pts[j], pts[k]
				local nor = (pj - pi):Cross(pk - pi)
				if nor.Magnitude > EPS then
					nor = nor.Unit
					local d = nor:Dot(pi)
					local allLE, allGE = true, true
					for m = 1, count do
						local val = nor:Dot(pts[m])
						if val > d + EPS then
							allLE = false
						end
						if val < d - EPS then
							allGE = false
						end
					end
					local outN, outD
					if allLE then
						outN, outD = nor, d -- nor already points outward (d is max)
					elseif allGE then
						outN, outD = -nor, -d -- flip so outward = max side
					end
					if outN then
						local sn = Vector3.new(snap(outN.X), snap(outN.Y), snap(outN.Z))
						local keyStr = string.format("%.3f_%.3f_%.3f_%.3f", sn.X, sn.Y, sn.Z, snap(outD))
						if planes[keyStr] == nil then
							planes[keyStr] = { normal = sn.Unit, d = outD }
						end
					end
				end
			end
		end
	end

	-- Triangulate each face polygon (fan), ordering vertices CCW about the normal.
	local tris: { Tri } = {}
	for _, plane in planes do
		local nor, d = plane.normal, plane.d
		local poly: { Vector3 } = {}
		for m = 1, count do
			if math.abs(nor:Dot(pts[m]) - d) < EPS then
				poly[#poly + 1] = pts[m]
			end
		end
		if #poly >= 3 then
			local fc = Vector3.zero
			for _, p in poly do
				fc += p
			end
			fc /= #poly
			local u = (poly[1] - fc)
			if u.Magnitude < EPS then
				u = (poly[2] - fc)
			end
			u = u.Unit
			local v = nor:Cross(u).Unit
			table.sort(poly, function(a, b)
				local da, db = a - fc, b - fc
				return math.atan2(v:Dot(da), u:Dot(da)) < math.atan2(v:Dot(db), u:Dot(db))
			end)
			local faceIdx = normalToFace(nor)
			local slope = faceIdx == 0
			for t = 2, #poly - 1 do
				tris[#tris + 1] =
					{ a = poly[1], b = poly[t], c = poly[t + 1], n = nor, isSlope = slope, face = faceIdx }
			end
		end
	end
	return tris
end

function Shape.hullTriangles(shapeId: number, o: number): { Tri }
	local byO = HULL_CACHE[shapeId]
	if not byO then
		byO = {}
		HULL_CACHE[shapeId] = byO
	end
	local cached = byO[o]
	if not cached then
		cached = buildHull(shapeId, o)
		byO[o] = cached
	end
	return cached
end

return Shape
