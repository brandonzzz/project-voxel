--!strict
--[[
	DataLayerTest — M1 verification.

	require()d and called from the command bar via MCP:
	  local T = require(game.ReplicatedStorage.LegacyVoxelTerrain.Tests.DataLayerTest)
	  T()

	Prints one PASS:/FAIL: line per assertion group and a final summary line
	"M1 RESULT: <pass> passed, <fail> failed".
]]

local Lib = script.Parent.Parent
local Constants = require(Lib.Constants)
local VoxelStore = require(Lib.VoxelStore)
local Rle = require(Lib.Rle)

local Material = Constants.Material
local Shape = Constants.Shape
local Orientation = Constants.Orientation
local FillState = Constants.FillState
local packCell = Constants.packCell
local packByte1 = Constants.packByte1

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

	-- T1: byte1 + cell pack/unpack fuzz -------------------------------------
	do
		local ok = true
		for low = 0, 7 do
			for high = 0, 3 do
				local b = packByte1(low, high)
				local l, h = Constants.unpackByte1(b)
				if l ~= low or h ~= high then
					ok = false
				end
			end
		end
		check(ok, "byte1 pack/unpack round-trip (shape/orient 0..7 x 0..3)")

		local ok2 = true
		for mat = 0, 255 do
			for _, b1 in { 0, 1, 33, 200, 255 } do
				local v = packCell(mat, b1)
				local m, b = Constants.unpackCell(v)
				if m ~= mat or b ~= b1 or v ~= mat + b1 * 256 then
					ok2 = false
				end
			end
		end
		check(ok2, "cell pack/unpack round-trip (material x byte1)")
	end

	-- T2: coordinate math --------------------------------------------------
	do
		local cases = {
			{ 0, 0, 0 },
			{ 15, 0, 15 },
			{ 16, 1, 0 },
			{ 31, 1, 15 },
			{ -1, -1, 15 },
			{ -16, -1, 0 },
			{ -17, -2, 15 },
		}
		local ok = true
		for _, c in cases do
			local cc, ll = VoxelStore.worldToChunk(c[1])
			if cc ~= c[2] or ll ~= c[3] then
				ok = false
			end
		end
		check(ok, "worldToChunk floor-div incl. negatives")

		local li = VoxelStore.localIndex
		check(
			li(0, 0, 0) == 0
				and li(1, 0, 0) == 1
				and li(0, 0, 1) == 16
				and li(0, 1, 0) == 256
				and li(15, 15, 15) == 4095,
			"localIndex layout x + z*16 + y*256"
		)
	end

	-- T3: get/set cell + materialisation -----------------------------------
	do
		local store = VoxelStore.new()
		local m0, b0 = store:getCell(3, 4, 5)
		check(m0 == 0 and b0 == 0, "getCell on absent chunk returns Empty")

		local wedge = packByte1(Shape.VerticalWedge, Orientation.X)
		store:setCell(5, 2, 7, Material.Grass, wedge)
		local m1, b1 = store:getCell(5, 2, 7)
		check(m1 == Material.Grass and b1 == wedge, "setCell then getCell round-trip")

		local chunk = store:getChunk(0, 0, 0)
		check(chunk ~= nil and chunk.state == FillState.Mixed, "writing differing value materialises chunk")

		-- overwrite back to empty value: stays Mixed, reads Empty
		store:setCell(5, 2, 7, 0, 0)
		local m2, b2 = store:getCell(5, 2, 7)
		check(m2 == 0 and b2 == 0, "overwrite cell back to Empty")

		-- ALL_SOLID flag chunk: uniform read without a buffer
		local solidVal = packCell(Material.Granite, 0)
		local solid = VoxelStore.newChunk(2, 0, 0, FillState.Solid, solidVal)
		store:setChunk(solid)
		local sm, sb = store:getCell(2 * 16 + 7, 9, 3) -- inside chunk (2,0,0)
		check(sm == Material.Granite and sb == 0 and solid.buf == nil, "ALL_SOLID reads uniform with no buffer")

		-- editing one cell of a solid chunk materialises it, others stay solid
		store:setCell(2 * 16 + 7, 9, 3, Material.Sand, 0)
		local em, _ = store:getCell(2 * 16 + 7, 9, 3)
		local um, _ = store:getCell(2 * 16 + 8, 9, 3)
		check(
			em == Material.Sand and um == Material.Granite and solid.state == FillState.Mixed,
			"editing a Solid chunk materialises, neighbours keep fill"
		)
	end

	-- T4: RLE pure-codec fuzz + identity -----------------------------------
	do
		math.randomseed(20260612)
		local CELLS = Constants.CHUNK_CELLS
		local ok = true
		for _ = 1, 40 do
			local raw = buffer.create(Constants.CHUNK_BYTES)
			-- run-friendly fill: mostly repeat previous, sometimes jump
			local cur = math.random(0, 65535)
			for i = 0, CELLS - 1 do
				if math.random() < 0.25 then
					cur = math.random(0, 65535)
				end
				buffer.writeu16(raw, i * 2, cur)
			end
			local dec = Rle.decode(Rle.encode(raw))
			if buffer.tostring(dec) ~= buffer.tostring(raw) then
				ok = false
			end
		end
		check(ok, "RLE encode->decode identity over 40 fuzzed chunks")

		-- fully random (worst case, large palette / short runs)
		local rnd = buffer.create(Constants.CHUNK_BYTES)
		for i = 0, CELLS - 1 do
			buffer.writeu16(rnd, i * 2, math.random(0, 65535))
		end
		check(
			buffer.tostring(Rle.decode(Rle.encode(rnd))) == buffer.tostring(rnd),
			"RLE identity on fully-random chunk (large palette)"
		)

		-- uniform chunks (palette of 1)
		local zero = buffer.create(Constants.CHUNK_BYTES)
		check(buffer.tostring(Rle.decode(Rle.encode(zero))) == buffer.tostring(zero), "RLE identity on all-Empty chunk")
		local uni = buffer.create(Constants.CHUNK_BYTES)
		for i = 0, CELLS - 1 do
			buffer.writeu16(uni, i * 2, packCell(Material.Brick, 0))
		end
		check(buffer.tostring(Rle.decode(Rle.encode(uni))) == buffer.tostring(uni), "RLE identity on uniform-Solid chunk")

		-- re-encode stability
		local once = Rle.encode(uni)
		check(buffer.tostring(once) == buffer.tostring(Rle.encode(Rle.decode(once))), "RLE re-encode is stable")
	end

	-- T5: chunk-level RLE round-trip + flag preservation -------------------
	do
		-- Mixed chunk pattern
		local mixed = VoxelStore.newChunk(0, 0, 0)
		for i = 0, Constants.CHUNK_CELLS - 1 do
			VoxelStore.chunkSetRaw(mixed, i, packCell(i % 18, (i * 7) % 256))
		end
		local rebuilt = Rle.decodeChunk(Rle.encodeChunk(mixed), 0, 0, 0)
		local cellsOk = true
		for i = 0, Constants.CHUNK_CELLS - 1 do
			if VoxelStore.chunkGetRaw(rebuilt, i) ~= VoxelStore.chunkGetRaw(mixed, i) then
				cellsOk = false
			end
		end
		check(cellsOk, "Mixed chunk RLE round-trips all 4096 cells")

		-- Empty chunk decodes back to the Empty flag (no buffer)
		local emptyChunk = VoxelStore.newChunk(0, 0, 0)
		local emptyBack = Rle.decodeChunk(Rle.encodeChunk(emptyChunk), 0, 0, 0)
		check(emptyBack.state == FillState.Empty and emptyBack.buf == nil, "Empty chunk decodes to ALL_EMPTY flag")

		-- Solid chunk decodes back to the Solid flag (no buffer), value preserved
		local solidVal = packCell(Material.Iron, packByte1(Shape.Solid, Orientation.NegZ))
		local solidChunk = VoxelStore.newChunk(0, 0, 0, FillState.Solid, solidVal)
		local solidBack = Rle.decodeChunk(Rle.encodeChunk(solidChunk), 0, 0, 0)
		check(
			solidBack.state == FillState.Solid and solidBack.buf == nil and solidBack.fillValue == solidVal,
			"Solid chunk decodes to ALL_SOLID flag with value preserved"
		)
	end

	-- T6: padded neighbour sampling across chunk borders -------------------
	-- The seam-correctness guarantee: out-of-chunk reads MUST hit the real
	-- neighbour chunk, never be silently treated as Empty.
	do
		local store = VoxelStore.new()
		local center = packCell(Material.Cement, 0)
		local xPos = packCell(Material.Brick, 0)
		local xNeg = packCell(Material.Sand, 0)
		local zPos = packCell(Material.Gold, 0)
		local yPos = packCell(Material.Iron, 0)

		store:setCell(8, 8, 8, Material.Cement, 0) -- center interior, chunk (0,0,0)
		store:setCell(16, 5, 5, Material.Brick, 0) -- +X neighbour (1,0,0) local (0,5,5)
		store:setCell(-1, 5, 5, Material.Sand, 0) -- -X neighbour (-1,0,0) local (15,5,5)
		store:setCell(5, 5, 16, Material.Gold, 0) -- +Z neighbour (0,0,1) local (5,5,0)
		store:setCell(5, 16, 5, Material.Iron, 0) -- +Y neighbour (0,1,0) local (5,0,5)
		-- -Y neighbour deliberately left absent

		local sampler = store:makeNeighborSampler(0, 0, 0)
		check(sampler(8, 8, 8) == center, "sampler reads center interior")
		check(sampler(16, 5, 5) == xPos and xPos ~= 0, "sampler reads +X neighbour border (non-empty)")
		check(sampler(-1, 5, 5) == xNeg and xNeg ~= 0, "sampler reads -X neighbour border (non-empty)")
		check(sampler(5, 5, 16) == zPos and zPos ~= 0, "sampler reads +Z neighbour border (non-empty)")
		check(sampler(5, 16, 5) == yPos and yPos ~= 0, "sampler reads +Y neighbour border (non-empty)")
		check(sampler(5, -1, 5) == 0, "sampler returns Empty for genuinely absent neighbour")

		-- padded 18^3 view must agree with the sampler at the same coords
		local view = store:buildPaddedView(0, 0, 0)
		local function vAt(lx: number, ly: number, lz: number): number
			return buffer.readu16(view, VoxelStore.paddedIndex(lx + 1, ly + 1, lz + 1) * 2)
		end
		check(
			vAt(8, 8, 8) == center
				and vAt(16, 5, 5) == xPos
				and vAt(-1, 5, 5) == xNeg
				and vAt(5, 5, 16) == zPos
				and vAt(5, 16, 5) == yPos
				and vAt(5, -1, 5) == 0,
			"padded 18^3 view matches sampler at all six border probes"
		)
	end

	print(string.format("M1 RESULT: %d passed, %d failed", pass, fail))
	return pass, fail
end

return run
