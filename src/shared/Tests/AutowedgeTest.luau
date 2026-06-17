--!strict
--[[ AutowedgeTest — P2 unit verification against a hand-authored expected table.
     Inside corners are concave (open DIAGONAL + filled flanks), material-agnostic. ]]

local Lib = script.Parent.Parent
local Constants = require(Lib.Constants)
local VoxelStore = require(Lib.VoxelStore)
local Shape = require(Lib.Shape)
local Autowedge = require(Lib.Autowedge)

local S = Constants.Shape
local GRANITE = Constants.Material.Granite
local SOLID = Constants.packByte1(S.Solid, 0)

-- Candidate Solid at (8,8,8), Empty above. All 8 same-level neighbours default
-- to Solid; spec sets any of the 8 keys to "empty".
local function makeStore(spec: { [string]: string }): VoxelStore.Store
	local store = VoxelStore.new()
	store:setCell(8, 8, 8, GRANITE, SOLID)
	local n = {
		["1_0"] = { 1, 0 },
		["-1_0"] = { -1, 0 },
		["0_1"] = { 0, 1 },
		["0_-1"] = { 0, -1 },
		["1_1"] = { 1, 1 },
		["1_-1"] = { 1, -1 },
		["-1_-1"] = { -1, -1 },
		["-1_1"] = { -1, 1 },
	}
	for k, d in n do
		if (spec[k] or "solid") ~= "empty" then
			store:setCell(8 + d[1], 8, 8 + d[2], GRANITE, SOLID)
		end
	end
	return store
end

local function run(): (number, number)
	local pass, fail = 0, 0
	local function check(cond, name)
		if cond then pass += 1; print("PASS: " .. name) else fail += 1; print("FAIL: " .. name) end
	end

	local cases = {
		-- single-edge ramps (1 open orthogonal, diagonals on the open side also open)
		{ "ramp +X", { ["1_0"] = "empty", ["1_1"] = "empty", ["1_-1"] = "empty" }, S.VerticalWedge, 1 },
		{ "ramp -X", { ["-1_0"] = "empty", ["-1_1"] = "empty", ["-1_-1"] = "empty" }, S.VerticalWedge, 3 },
		{ "ramp +Z", { ["0_1"] = "empty", ["1_1"] = "empty", ["-1_1"] = "empty" }, S.VerticalWedge, 2 },
		{ "ramp -Z", { ["0_-1"] = "empty", ["1_-1"] = "empty", ["-1_-1"] = "empty" }, S.VerticalWedge, 0 },
		-- outside corners (2 adjacent open + open diagonal -> flanks open, NOT inside)
		{ "corner +X+Z", { ["1_0"] = "empty", ["0_1"] = "empty", ["1_1"] = "empty" }, S.CornerWedge, 2 },
		{ "corner +X-Z", { ["1_0"] = "empty", ["0_-1"] = "empty", ["1_-1"] = "empty" }, S.CornerWedge, 1 },
		{ "corner -X-Z", { ["-1_0"] = "empty", ["0_-1"] = "empty", ["-1_-1"] = "empty" }, S.CornerWedge, 0 },
		{ "corner -X+Z", { ["-1_0"] = "empty", ["0_1"] = "empty", ["-1_1"] = "empty" }, S.CornerWedge, 3 },
		-- inside corners (open DIAGONAL, both flanks filled) -> InverseCornerWedge
		{ "inside +X+Z", { ["1_1"] = "empty" }, S.InverseCornerWedge, 2 },
		{ "inside +X-Z", { ["1_-1"] = "empty" }, S.InverseCornerWedge, 1 },
		{ "inside -X-Z", { ["-1_-1"] = "empty" }, S.InverseCornerWedge, 0 },
		{ "inside -X+Z", { ["-1_1"] = "empty" }, S.InverseCornerWedge, 3 },
		-- ridge (2 opposite open) / pillar (all open) / flat (none open) -> no change
		{ "ridge X", { ["1_0"] = "empty", ["-1_0"] = "empty" }, false, 0 },
		{ "ridge Z", { ["0_1"] = "empty", ["0_-1"] = "empty" }, false, 0 },
		{
			"pillar",
			{ ["1_0"] = "empty", ["-1_0"] = "empty", ["0_1"] = "empty", ["0_-1"] = "empty", ["1_1"] = "empty", ["1_-1"] = "empty", ["-1_-1"] = "empty", ["-1_1"] = "empty" },
			false,
			0,
		},
		{ "flat", {}, false, 0 },
		-- REGRESSION: a flat cell whose neighbours are all filled (e.g. sand floor at
		-- a grass-hill base) must NOT become an inside corner (the old "dip" bug).
		{ "flat-by-wall no dip", {}, false, 0 },
	}

	for _, c in cases do
		local name, spec, expShape, expGeom = c[1], c[2], c[3], c[4]
		local store = makeStore(spec)
		local shape, geom = Autowedge.decide(store, 8, 8, 8)
		if expShape == false then
			check(shape == nil, name .. " -> no change")
		else
			check(shape == expShape and geom == expGeom, string.format("%s -> shape=%s geom=%s", name, tostring(expShape), tostring(expGeom)))
		end
	end

	-- region() writes the correct STORED byte1 (geom round-trips through the remap)
	do
		local store = makeStore({ ["1_0"] = "empty" })
		local deltas = Autowedge.region(store, 8, 8, 8, 8, 8, 8)
		local m, b1 = store:getCell(8, 8, 8)
		local shp, st = Constants.unpackByte1(b1)
		check(#deltas == 1 and shp == S.VerticalWedge and Shape.geomOrientation(shp, st) == 1 and m == GRANITE,
			"region writes VW geom 1 (stored via remap), material preserved")
	end

	-- material-agnostic: same open pattern, different materials -> same decision
	do
		local a = VoxelStore.new()
		a:setCell(8, 8, 8, Constants.Material.Grass, SOLID)
		a:setCell(9, 8, 8, Constants.Material.Grass, SOLID)
		a:setCell(8, 8, 9, Constants.Material.Grass, SOLID)
		local sa, ga = Autowedge.decide(a, 8, 8, 8) -- only diag (9,8,9) open -> inside +X+Z
		local b = VoxelStore.new()
		b:setCell(8, 8, 8, Constants.Material.Sand, SOLID)
		b:setCell(9, 8, 8, Constants.Material.Sand, SOLID)
		b:setCell(8, 8, 9, Constants.Material.Sand, SOLID)
		local sb, gb = Autowedge.decide(b, 8, 8, 8)
		check(sa == sb and ga == gb and sa == S.InverseCornerWedge, "decision is material-agnostic (grass == sand)")
	end

	-- idempotency
	do
		local store = makeStore({ ["1_0"] = "empty", ["0_1"] = "empty", ["1_1"] = "empty" })
		Autowedge.region(store, 7, 7, 7, 9, 9, 9)
		local second = Autowedge.region(store, 7, 7, 7, 9, 9, 9)
		check(#second == 0, "second Autowedge pass is idempotent (0 deltas)")
	end

	print(string.format("P2 AUTOWEDGE RESULT: %d passed, %d failed", pass, fail))
	return pass, fail
end

return run
