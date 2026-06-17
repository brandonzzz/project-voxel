--!strict
--[[ EditTest — M6 unit verification of EditService + ChunkManager debounce. ]]

local Lib = script.Parent.Parent
local Constants = require(Lib.Constants)
local VoxelStore = require(Lib.VoxelStore)
local EditService = require(Lib.EditService)
local ChunkManager = require(Lib.ChunkManager)

local Material = Constants.Material
local SOLID = Constants.packByte1(Constants.Shape.Solid, 0)

local function keyset(set)
	local n = 0
	for _ in set do
		n += 1
	end
	return n
end

local function run(): (number, number)
	local pass, fail = 0, 0
	local function check(cond, name)
		if cond then pass += 1; print("PASS: " .. name) else fail += 1; print("FAIL: " .. name) end
	end

	-- T1: affected chunks (borders dirty neighbours) -----------------------
	do
		check(#EditService.affectedChunks(8, 8, 8) == 1, "interior cell affects only its chunk")
		check(#EditService.affectedChunks(0, 8, 8) == 2, "x-border cell affects own + -X neighbour")
		check(#EditService.affectedChunks(15, 8, 8) == 2, "x=15 cell affects own + +X neighbour")
		check(#EditService.affectedChunks(0, 0, 0) == 4, "corner cell affects own + 3 neighbours")
	end

	-- T2: applyEdit ---------------------------------------------------------
	do
		local store = VoxelStore.new()
		local delta, affected = EditService.applyEdit(store, 8, 8, 8, Material.Grass, SOLID)
		local m, b = store:getCell(8, 8, 8)
		check(m == Material.Grass and b == SOLID, "applyEdit writes the cell")
		check(delta[1] == 8 and delta[4] == Constants.packCell(Material.Grass, SOLID), "delta carries world coords + packed value")
		check(keyset(affected) == 1, "applyEdit affects a single chunk for interior cell")
	end

	-- T3: explosion carves a sphere ----------------------------------------
	do
		local store = VoxelStore.new()
		-- pre-fill a solid block around the blast
		for x = 0, 20 do for y = 0, 20 do for z = 0, 20 do
			store:setCell(x, y, z, Material.Granite, SOLID)
		end end end
		local noop = function() end
		local deltas, affected = EditService.explode(store, noop, 10, 10, 10, 3)

		check((store:getCell(10, 10, 10)) == 0, "blast centre carved to empty")
		check((store:getCell(10, 10, 13)) == 0, "cell at radius (dist 3) carved")
		check((store:getCell(10, 10, 14)) ~= 0, "cell just outside radius (dist 4) untouched")
		check(#deltas > 0 and #deltas == 123, string.format("delta count = lattice points in r=3 sphere (got %d)", #deltas))
		check(keyset(affected) >= 1, "explosion reports affected chunks")

		-- re-exploding the same hole yields no new deltas (already empty)
		local deltas2 = EditService.explode(store, noop, 10, 10, 10, 3)
		check(#deltas2 == 0, "re-exploding carved region produces no deltas")
	end

	-- T4: markDirty debounce ------------------------------------------------
	do
		local mgr = ChunkManager.new({
			store = VoxelStore.new(),
			gen = nil,
			container = Instance.new("Folder"),
			focusFn = function() return Vector3.zero end,
			hud = false,
		})
		mgr:markDirty(5, 5)
		mgr:markDirty(5, 5)
		mgr:markDirty(6, 5)
		check(keyset(mgr.dirty) == 2, "duplicate markDirty on same chunk collapses (debounce)")
	end

	print(string.format("M6 EDIT RESULT: %d passed, %d failed", pass, fail))
	return pass, fail
end

return run
