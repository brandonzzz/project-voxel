--!strict
--[[ TextureAtlasTest — P4: every faceRect must land inside its region rectangle
     (within the correct material space, inset, non-degenerate). ]]

local Lib = script.Parent.Parent
local TextureAtlas = require(Lib.TextureAtlas)

local ATLAS = 1024
local REGION = TextureAtlas.REGION

local function run(): (number, number)
	local pass, fail = 0, 0
	local function check(cond, name)
		if cond then pass += 1; print("PASS: " .. name) else fail += 1; print("FAIL: " .. name) end
	end

	local faceTypes = { "TOP", "BOTTOM", "SIDE", "SLOPE" }
	local cells = { { 0, 0, 0 }, { 1, 2, 3 }, { 5, 7, 11 }, { -3, 4, -9 }, { 16, 1, 16 } }

	local allInside = true
	local degenerate = false
	local checkedTypes: { [string]: boolean } = {}
	for material = 1, 16 do
		local i = TextureAtlas.MAT_TO_SLOT[material] -- atlas slot != material-1 (see ATLAS_ORDER)
		local mbx, mby = (i % 4) * 256, math.floor(i / 4) * 256
		for _, ft in faceTypes do
			local r = REGION[ft]
			for _, te in { true, false } do
				for _, sc in { true, false } do
					for _, c in cells do
						local u0, v0, u1, v1 = TextureAtlas.faceRect(ft, material, c[1], c[2], c[3], te, sc)
						-- non-degenerate, correct winding
						if not (u0 < u1 and v0 < v1) then
							degenerate = true
						end
						-- convert to material-local pixels and check within region box
						local lx0 = u0 * ATLAS - mbx
						local ly0 = v0 * ATLAS - mby
						local lx1 = u1 * ATLAS - mbx
						local ly1 = v1 * ATLAS - mby
						if not (lx0 >= r.ox - 0.01 and lx1 <= r.ox + r.w + 0.01 and ly0 >= r.oy - 0.01 and ly1 <= r.oy + r.h + 0.01) then
							allInside = false
						end
						-- sub-tile must be exactly one voxel wide/tall (no inset now)
						local w = (u1 - u0) * ATLAS
						local h = (v1 - v0) * ATLAS
						if math.abs(w - r.vox) > 0.05 or math.abs(h - r.vox) > 0.05 then
							allInside = false
						end
						checkedTypes[ft] = true
					end
				end
			end
		end
	end
	check(allInside, "all faceRects land inside their region box, sized to one voxel (inset)")
	check(not degenerate, "all faceRects are non-degenerate (u0<u1, v0<v1)")
	check(checkedTypes.TOP and checkedTypes.SIDE and checkedTypes.SLOPE and checkedTypes.BOTTOM, "all four region types exercised")

	-- material spaces don't overlap: material 1 vs 16 rects are far apart
	do
		local a0 = select(1, TextureAtlas.faceRect("TOP", 1, 0, 0, 0, false, false))
		local b0 = select(1, TextureAtlas.faceRect("TOP", 16, 0, 0, 0, false, false))
		check(a0 ~= b0, "different materials map to different atlas offsets")
	end

	-- variants change the rect (fringe vs body; crest vs body)
	do
		local _, sv0 = TextureAtlas.faceRect("SIDE", 1, 0, 0, 0, true, false)
		local _, sv1 = TextureAtlas.faceRect("SIDE", 1, 0, 0, 0, false, false)
		check(sv0 ~= sv1, "SIDE top-exposed (fringe) differs from body variant")
		local sl0 = select(1, TextureAtlas.faceRect("SLOPE", 1, 0, 0, 0, false, true))
		local sl1 = select(1, TextureAtlas.faceRect("SLOPE", 1, 0, 0, 0, false, false))
		check(sl0 ~= sl1, "SLOPE crest differs from body variant")
	end

	print(string.format("P4 TEXTURE RESULT: %d passed, %d failed", pass, fail))
	return pass, fail
end

return run
