--!strict
--[[
	RenderTest — M3 verification. Runs in Edit via the folder-clone fresh-require
	pattern; builds into a temporary Workspace folder and cleans up after.

	Covers: counts within EditableMesh limits + count matches fill exactly;
	checkerboard chunk triggers octant split; no seams between adjacent chunks
	(border culling samples the real neighbour, never "empty"); edited-chunk
	rebuild swaps geometry in place on the same part with a CONSTANT transform
	(bbox pinned to the chunk cube -- so a growing edit never shifts the chunk);
	live editable allocations never exceed the budget and never leak.
]]

local Workspace = game:GetService("Workspace")

local Lib = script.Parent.Parent
local Constants = require(Lib.Constants)
local VoxelStore = require(Lib.VoxelStore)
local Shape = require(Lib.Shape)
local Mesher = require(Lib.Mesher)

local Material = Constants.Material
local SHP = Constants.Shape
local packByte1 = Constants.packByte1

local SOLID = packByte1(SHP.Solid, 0)

local function fillChunkSolid(store, cx, cy, cz, material)
	local base = Constants.CHUNK
	for lx = 0, base - 1 do
		for ly = 0, base - 1 do
			for lz = 0, base - 1 do
				store:setCell(cx * base + lx, cy * base + ly, cz * base + lz, material, SOLID)
			end
		end
	end
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

	Mesher.maxLiveEditables = 0
	local container = Instance.new("Folder")
	container.Name = "LVT_RenderTest"
	container.Parent = Workspace

	-- T1: random terrain within limits, count matches fill, no editable leak ----
	do
		local store = VoxelStore.new()
		math.randomseed(424242)
		local shapes = { SHP.Solid, SHP.VerticalWedge, SHP.CornerWedge, SHP.InverseCornerWedge, SHP.HorizontalWedge }
		for lx = 0, 15 do
			for ly = 0, 15 do
				for lz = 0, 15 do
					if math.random() < 0.5 then
						local b1 = packByte1(shapes[math.random(#shapes)], math.random(0, 3))
						store:setCell(lx, ly, lz, math.random(1, 16), b1)
					end
				end
			end
		end
		local counted = Mesher.countChunk(store, 0, 0, 0)
		local baked, builtTris, builtVerts = Mesher.buildSubMesh(store, 0, 0, 0, 0, 15, 0, 15, 0, 15)
		check(baked ~= nil, "random chunk bakes to content")
		check(builtTris == counted, string.format("count pass matches fill exactly (%d)", counted))
		check(builtTris <= 20000 and builtVerts <= 60000, string.format("within EditableMesh limits (%d tris, %d verts)", builtTris, builtVerts))
		check(Mesher.liveEditables == 0, "no editable leak after build")
		check(Mesher.maxLiveEditables <= 4, string.format("live editables stayed <= 4 (peak %d)", Mesher.maxLiveEditables))
	end

	-- T2: checkerboard triggers octant split -----------------------------------
	do
		local store = VoxelStore.new()
		for lx = 0, 15 do
			for ly = 0, 15 do
				for lz = 0, 15 do
					if (lx + ly + lz) % 2 == 0 then
						store:setCell(lx, ly, lz, Material.Granite, SOLID)
					end
				end
			end
		end
		local total = Mesher.countChunk(store, 0, 0, 0)
		check(total > Mesher.TRI_SPLIT_THRESHOLD, string.format("checkerboard exceeds split threshold (%d tris)", total))
		local stats = Mesher.rebuildChunk(store, 0, 0, 0, container)
		check(stats.split and stats.parts == 8, string.format("rebuild split into 8 octants (split=%s parts=%d)", tostring(stats.split), stats.parts))
		-- every octant must individually fit the EditableMesh tri limit
		local worstTris = 0
		for oi = 0, 7 do
			local ox, oy, oz = oi % 2, math.floor(oi / 2) % 2, math.floor(oi / 4) % 2
			local _, tris = Mesher.buildSubMesh(store, 0, 0, 0, ox * 8, ox * 8 + 7, oy * 8, oy * 8 + 7, oz * 8, oz * 8 + 7)
			if tris > worstTris then
				worstTris = tris
			end
		end
		check(worstTris <= 20000, string.format("each octant within tri limit (worst %d)", worstTris))
	end

	-- T3: no seams between adjacent chunks (border culling) ---------------------
	do
		-- isolated solid chunk: only the 6 outer faces survive = 6*256*2 = 3072 tris
		local solo = VoxelStore.new()
		fillChunkSolid(solo, 0, 0, 0, Material.Granite)
		local isolated = Mesher.countChunk(solo, 0, 0, 0)
		check(isolated == 3072, string.format("isolated solid chunk emits only 6 outer faces (%d, want 3072)", isolated))

		-- add a solid +X neighbour: the shared face (256 quads = 512 tris) is culled
		local pair = VoxelStore.new()
		fillChunkSolid(pair, 0, 0, 0, Material.Granite)
		fillChunkSolid(pair, 1, 0, 0, Material.Granite)
		local withNeighbour = Mesher.countChunk(pair, 0, 0, 0)
		check(withNeighbour == isolated - 512, string.format("shared border culled vs neighbour (%d, want %d)", withNeighbour, isolated - 512))
	end

	-- T4: edited-chunk rebuild swaps geometry in place, same part, CONSTANT transform -----------
	do
		local store = VoxelStore.new()
		local cxT = 3 -- isolated chunk, away from T2's leftovers at (0,0,0)
		for lx = 4, 11 do
			for lz = 4, 11 do
				store:setCell(cxT * 16 + lx, 0, lz, Material.Grass, SOLID)
			end
		end
		Mesher.rebuildChunk(store, cxT, 0, 0, container)
		local part1 = container:FindFirstChild("C_3_0_0")
		local pos1 = part1 and part1.Position
		local size1 = part1 and part1.Size
		-- grow the chunk UPWARD: a tight-bbox part would move its centre + size; the fixed cube must not
		for ly = 1, 6 do
			store:setCell(cxT * 16 + 7, ly, 7, Material.Brick, SOLID)
		end
		Mesher.rebuildChunk(store, cxT, 0, 0, container)
		local part2 = container:FindFirstChild("C_3_0_0")
		check(part1 ~= nil and part1 == part2, "edit reuses the SAME MeshPart instance (in-place ApplyMesh)")
		check(part2 ~= nil and part2:IsA("MeshPart") and part2.MeshContent ~= nil, "reused part still has baked mesh content")
		-- The fix: a bbox-growing edit must NOT move the part (no "shift then snap back").
		check(part2 ~= nil and part2.Position == pos1 and part2.Size == size1, "transform is CONSTANT across a bbox-growing edit (no shift)")
		local s = part2 and part2.Size or Vector3.zero
		check(math.abs(s.X - 64) < 0.01 and math.abs(s.Y - 64) < 0.01 and math.abs(s.Z - 64) < 0.01, "chunk part bbox pinned to the 64-stud cube")
	end

	check(Mesher.liveEditables == 0, "no live editables leaked across all M3 tests")

	container:Destroy()
	print(string.format("M3 RESULT: %d passed, %d failed", pass, fail))
	return pass, fail
end

return run
