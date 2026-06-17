--!strict
--[[
	CollisionTest — M5 unit verification (pure; no baking / physics).
	Greedy-box coverage invariants + DDA cell-picking accuracy.
]]

local Lib = script.Parent.Parent
local Constants = require(Lib.Constants)
local VoxelStore = require(Lib.VoxelStore)
local Collision = require(Lib.Collision)

local CHUNK = Constants.CHUNK
local Material = Constants.Material
local SOLID = Constants.packByte1(Constants.Shape.Solid, 0)

local function lidx(lx, ly, lz)
	return lx + lz * CHUNK + ly * (CHUNK * CHUNK) + 1
end

local function makeMask(pred): { boolean }
	local m = table.create(CHUNK * CHUNK * CHUNK, false)
	for ly = 0, CHUNK - 1 do
		for lz = 0, CHUNK - 1 do
			for lx = 0, CHUNK - 1 do
				if pred(lx, ly, lz) then
					m[lidx(lx, ly, lz)] = true
				end
			end
		end
	end
	return m
end

-- Verify boxes cover exactly the mask cells, each exactly once. --
local function coverageOk(mask, boxes): (boolean, number)
	local cover = table.create(CHUNK * CHUNK * CHUNK, 0)
	for _, b in boxes do
		for zz = b.z0, b.z1 do
			for yy = b.y0, b.y1 do
				for xx = b.x0, b.x1 do
					local i = lidx(xx, yy, zz)
					cover[i] += 1
				end
			end
		end
	end
	local solidCells = 0
	for i = 1, CHUNK * CHUNK * CHUNK do
		local want = mask[i] and 1 or 0
		if cover[i] ~= want then
			return false, 0
		end
		solidCells += want
	end
	return true, solidCells
end

local function run(): (number, number)
	local pass, fail = 0, 0
	local function check(cond, name)
		if cond then pass += 1; print("PASS: " .. name) else fail += 1; print("FAIL: " .. name) end
	end

	-- T1: greedy box coverage + counts -------------------------------------
	do
		local full = makeMask(function() return true end)
		local fb = Collision.greedyBoxes(full)
		local ok1 = coverageOk(full, fb)
		check(ok1 and #fb == 1, string.format("fully-solid chunk -> 1 box (got %d)", #fb))

		local single = makeMask(function(x, y, z) return x == 3 and y == 4 and z == 5 end)
		local sb = Collision.greedyBoxes(single)
		check(#sb == 1 and sb[1].x0 == 3 and sb[1].x1 == 3, "single cell -> 1 unit box")

		local slab = makeMask(function(_, y) return y == 0 end)
		local slb = Collision.greedyBoxes(slab)
		check(coverageOk(slab, slb) and #slb == 1, string.format("flat slab -> 1 box (got %d)", #slb))

		local holed = makeMask(function(x, y, z) return not (x == 8 and y == 8 and z == 8) end)
		local hb = Collision.greedyBoxes(holed)
		local okH, cellsH = coverageOk(holed, hb)
		check(okH and cellsH == CHUNK ^ 3 - 1, "solid-with-one-hole: exact coverage, hole excluded")

		local checker = makeMask(function(x, y, z) return (x + y + z) % 2 == 0 end)
		local cb = Collision.greedyBoxes(checker)
		check(coverageOk(checker, cb), "checkerboard: exact coverage (no overlaps/gaps)")
	end

	-- T2: DDA cell picking -------------------------------------------------
	do
		local store = VoxelStore.new()
		store:setCell(5, 5, 5, Material.Granite, SOLID)
		-- cell (5,5,5) centre is (22,22,22)
		local function hitFrom(o, dir)
			return Collision.rayMarch(store, o, dir, 400)
		end
		local hz = hitFrom(Vector3.new(22, 22, 100), Vector3.new(0, 0, -1))
		check(hz ~= nil and hz.cellX == 5 and hz.cellY == 5 and hz.cellZ == 5 and hz.face == 5, "ray -Z hits (5,5,5) via +Z face")

		local hx = hitFrom(Vector3.new(-100, 22, 22), Vector3.new(1, 0, 0))
		check(hx ~= nil and hx.cellX == 5 and hx.cellZ == 5 and hx.face == 2, "ray +X hits (5,5,5) via -X face")

		local hy = hitFrom(Vector3.new(22, 100, 22), Vector3.new(0, -1, 0))
		check(hy ~= nil and hy.cellY == 5 and hy.face == 3, "ray -Y hits (5,5,5) via +Y face")

		local hzp = hitFrom(Vector3.new(22, 22, -100), Vector3.new(0, 0, 1))
		check(hzp ~= nil and hzp.cellZ == 5 and hzp.face == 6, "ray +Z hits (5,5,5) via -Z face")

		-- miss: parallel ray that never enters the cell
		local miss = hitFrom(Vector3.new(0, 0, 100), Vector3.new(0, 0, -1))
		check(miss == nil, "ray down an empty column misses")

		-- origin already inside solid -> returns that cell, face 0
		local inside = hitFrom(Vector3.new(22, 22, 22), Vector3.new(1, 0, 0))
		check(inside ~= nil and inside.cellX == 5 and inside.face == 0, "origin inside solid returns that cell (face 0)")

		-- a solid wall at x=10, diagonal-ish ray still lands on the wall plane
		local wall = VoxelStore.new()
		for y = 0, 15 do
			for z = 0, 15 do
				wall:setCell(10, y, z, Material.Brick, SOLID)
			end
		end
		local hw = Collision.rayMarch(wall, Vector3.new(0, 22, 22), Vector3.new(1, 0.15, 0), 400)
		check(hw ~= nil and hw.cellX == 10 and hw.face == 2, "angled ray into +X wall hits x=10 via -X face")
	end

	print(string.format("M5 COLLISION RESULT: %d passed, %d failed", pass, fail))
	return pass, fail
end

return run
