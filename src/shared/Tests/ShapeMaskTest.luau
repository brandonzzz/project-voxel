--!strict
--[[
	ShapeMaskTest — M2 verification oracle.

	The ORACLE table below is transcribed verbatim from the mission brief. Each
	row is an orientation (0..3 = NegZ, X, Z, NegX); each column is a face in the
	order +X, -X, +Y, -Y, +Z, -Z. Tokens:
	  "F"        = full
	  "N"        = none
	  "T:<ra><rb>" = triangle, right-angle corner at param-A sign <ra>, param-B
	               sign <rb>. Param axes per face: +-X->(Z,Y), +-Y->(X,Z), +-Z->(X,Y).

	The brief's labels (e.g. T(Z+,Y-)) map to tokens as "T:+-": ra=Z+ -> '+', rb=Y- -> '-'.

	Asserts Shape.faceCoverage(shape, o, face) == oracle for every entry, plus a
	popcount cross-check of faceMaskBits (F->4, TRI->3, N-><=2).
]]

local Lib = script.Parent.Parent
local Constants = require(Lib.Constants)
local Shape = require(Lib.Shape)

local S = Constants.Shape

-- [shapeId] = { [o] = { +X, -X, +Y, -Y, +Z, -Z } }
local ORACLE: { [number]: { { string } } } = {
	[S.Solid] = {
		{ "F", "F", "F", "F", "F", "F" },
		{ "F", "F", "F", "F", "F", "F" },
		{ "F", "F", "F", "F", "F", "F" },
		{ "F", "F", "F", "F", "F", "F" },
	},
	[S.VerticalWedge] = {
		{ "T:+-", "T:+-", "N", "F", "F", "N" },
		{ "N", "F", "N", "F", "T:--", "T:--" },
		{ "T:--", "T:--", "N", "F", "N", "F" },
		{ "F", "N", "N", "F", "T:+-", "T:+-" },
	},
	[S.HorizontalWedge] = {
		{ "F", "N", "T:++", "T:++", "F", "N" },
		{ "N", "F", "T:-+", "T:-+", "F", "N" },
		{ "N", "F", "T:--", "T:--", "N", "F" },
		{ "F", "N", "T:+-", "T:+-", "N", "F" },
	},
	-- CornerWedge oracle REGENERATED from the corrected corner tetrahedron (the
	-- legacy "Corner": triangular base + single slope) confirmed by the user at the
	-- M2 visual gate. This supersedes the brief's original square-pyramid CW rows.
	-- The -Y (base) face is now a triangle, not full.
	[S.CornerWedge] = {
		{ "T:+-", "N", "N", "T:++", "T:+-", "N" },
		{ "N", "T:+-", "N", "T:-+", "T:--", "N" },
		{ "N", "T:--", "N", "T:--", "N", "T:--" },
		{ "T:--", "N", "N", "T:+-", "N", "T:+-" },
	},
	[S.InverseCornerWedge] = {
		{ "F", "T:+-", "T:++", "F", "F", "T:+-" },
		{ "T:+-", "F", "T:-+", "F", "F", "T:--" },
		{ "T:--", "F", "T:--", "F", "T:--", "F" },
		{ "F", "T:--", "T:+-", "F", "T:+-", "F" },
	},
}

local SHAPE_NAMES = {
	[S.Solid] = "Solid",
	[S.VerticalWedge] = "VerticalWedge",
	[S.CornerWedge] = "CornerWedge",
	[S.InverseCornerWedge] = "InverseCornerWedge",
	[S.HorizontalWedge] = "HorizontalWedge",
}

local function popcount(mask: number): number
	local n = 0
	for bit = 0, 3 do
		if bit32.band(mask, 2 ^ bit) ~= 0 then
			n += 1
		end
	end
	return n
end

local function run(): (number, number)
	local pass, fail = 0, 0
	local function check(cond: boolean, name: string)
		if cond then
			pass += 1
			print("PASS: " .. name)
		else
			fail += 1
			print("FAIL: " .. name)
		end
	end

	for _, sid in Shape.SHAPES do
		local table4 = ORACLE[sid]
		local shapeOk = true
		for o = 0, 3 do
			for f = 1, 6 do
				local expected = table4[o + 1][f]
				local got = Shape.faceCoverage(sid, o, f)
				if got ~= expected then
					shapeOk = false
					print(
						string.format(
							"  MISMATCH %s o=%d face=%s expected=%s got=%s",
							SHAPE_NAMES[sid],
							o,
							Shape.FACES[f].name,
							expected,
							got
						)
					)
				end
				-- popcount cross-check vs faceMaskBits
				local pc = popcount(Shape.faceMaskBits(sid, o, f))
				local wantPc = (expected == "F") and 4 or (string.sub(expected, 1, 1) == "T") and 3 or nil
				if wantPc ~= nil then
					if pc ~= wantPc then
						shapeOk = false
						print(
							string.format(
								"  POPCOUNT %s o=%d face=%s token=%s popcount=%d want=%d",
								SHAPE_NAMES[sid],
								o,
								Shape.FACES[f].name,
								expected,
								pc,
								wantPc
							)
						)
					end
				elseif pc > 2 then -- expected "N"
					shapeOk = false
					print(
						string.format(
							"  POPCOUNT %s o=%d face=%s token=N popcount=%d (want <=2)",
							SHAPE_NAMES[sid],
							o,
							Shape.FACES[f].name,
							pc
						)
					)
				end
			end
		end
		check(shapeOk, string.format("%s: all 4 orientations x 6 faces match oracle", SHAPE_NAMES[sid]))
	end

	print(string.format("M2 MASK RESULT: %d passed, %d failed", pass, fail))
	return pass, fail
end

return run
