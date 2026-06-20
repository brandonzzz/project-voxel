--!strict
--[[ PersistTest — M7 persistence round-trips + WorldGen water generation. ]]

local Lib = script.Parent.Parent
local Constants = require(Lib.Constants)
local VoxelStore = require(Lib.VoxelStore)
local WorldGen = require(Lib.WorldGen)
local Persist = require(Lib.PersistenceService)

local CHUNK = Constants.CHUNK

local function run(): (number, number)
	local pass, fail = 0, 0
	local function check(cond, name)
		if cond then pass += 1; print("PASS: " .. name) else fail += 1; print("FAIL: " .. name) end
	end

	-- T1: base64 round-trip -------------------------------------------------
	do
		math.randomseed(99)
		local ok = true
		for _, len in { 1, 2, 3, 4, 100, 8192 } do
			local buf = buffer.create(len)
			for i = 0, len - 1 do
				buffer.writeu8(buf, i, math.random(0, 255))
			end
			local back = Persist.base64decode(Persist.base64encode(buf))
			if buffer.len(back) ~= len or buffer.tostring(back) ~= buffer.tostring(buf) then
				ok = false
			end
		end
		check(ok, "base64 encode/decode round-trips (incl. 8192 bytes, all paddings)")
	end

	-- T2: RLE delta chunk round-trip (incl. carve value 0) ------------------
	do
		local edits = { [0] = Constants.packCell(Constants.Material.Brick, 0), [256] = 0, [4095] = Constants.packCell(17, 5) }
		local back = Persist.decodeChunkDeltas(Persist.encodeChunkDeltas(edits))
		local same = true
		local count = 0
		for idx, val in back do
			count += 1
			if edits[idx] ~= val then same = false end
		end
		check(same and count == 3, "delta chunk round-trips exactly (carve 0 preserved, sentinel excluded)")

		-- empty overlay encodes/decodes to nothing
		local empty = Persist.decodeChunkDeltas(Persist.encodeChunkDeltas({}))
		check(next(empty) == nil, "empty delta chunk decodes to no edits")
	end

	-- T3: region serialize -> apply round-trip ------------------------------
	do
		-- two edited chunks in region (0,0)
		local overlay = {
			["1_0_2"] = { [0] = Constants.packCell(Constants.Material.Gold, 0), [100] = 0 },
			["3_0_1"] = { [4095] = Constants.packCell(Constants.Material.Iron, 0) },
		}
		local data = Persist.serializeRegion(overlay, 0, 0)
		local store = VoxelStore.new()
		local deltas = Persist.applyRegion(store, data)
		-- chunk 1_0_2 cell index 0 -> world (16,0,32)
		local m1 = store:getCell(1 * CHUNK + 0, 0, 2 * CHUNK + 0)
		-- chunk 3_0_1 cell index 4095 -> local (15,15,15)
		local m2 = store:getCell(3 * CHUNK + 15, 15, 1 * CHUNK + 15)
		check(m1 == Constants.Material.Gold and m2 == Constants.Material.Iron and #deltas == 3,
			"region serialize -> apply restores edited cells across chunks")
	end

	-- T4: WorldGen floods low areas with water. Use an explicit LOW flat config (surface below sea
	-- level) so this is independent of the live Constants.GEN -- which may be a dry plateau ABOVE sea
	-- level (then there is legitimately no water) -- and tests the flooding mechanism itself.
	do
		local store = VoxelStore.new()
		local gen = WorldGen.new(Constants.WORLD_SEED, { type = "flat", flatHeight = 1 })
		local water = 0
		for cx = 0, 3 do
			for cz = 0, 3 do
				gen:fillChunk(store, cx, 0, cz)
			end
		end
		for wx = 0, 63 do
			for wz = 0, 63 do
				for wy = 0, 10 do
					if (store:getCell(wx, wy, wz)) == Constants.Material.Water then
						water += 1
					end
				end
			end
		end
		check(water > 0, string.format("WorldGen fills low areas with water (%d water cells)", water))
	end

	print(string.format("M7 PERSIST/WATER RESULT: %d passed, %d failed", pass, fail))
	return pass, fail
end

return run
