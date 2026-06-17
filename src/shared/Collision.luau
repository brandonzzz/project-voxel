--!strict
--[[
	Collision — server-style collision geometry + DDA cell picking.

	Collision is built from the voxel buffer, independent of the render mesh:
	  * Full Solid cubes are merged with a 3D greedy box pass into a few invisible
	    anchored Parts per chunk (1 if the chunk is fully solid).
	  * Each wedge cell gets an invisible anchored MeshPart cloned from a per-shape
	    convex-Hull collision template (baked once), positioned at the cell centre
	    and yawed by -geomO*90 degrees (matching the corner transform (x,z)->(-z,x)).
	  * Empty / water cells get nothing.

	Picking uses a DDA ray-march through the voxel grid in cell space (no physics
	raycasts), returning the first non-empty cell and the face entered.

	Collision parts are invisible (Transparency=1), Anchored, CanCollide=true,
	CanQuery=false, CanTouch=false. Picking uses DDA on the buffer (not raycasts).
	Camera occlusion is handled by the opaque, queryable render parts instead, since
	Poppercam ignores fully-transparent occluders. Per-chunk parts live under a
	"Col_cx_cy_cz" folder so
	a rebuild is independent of the render ApplyMesh swap.
]]

local AssetService = game:GetService("AssetService")

local Constants = require(script.Parent.Constants)
local Shape = require(script.Parent.Shape)
local VoxelStore = require(script.Parent.VoxelStore)

local CELL = Constants.CELL
local CHUNK = Constants.CHUNK
local WATER = Constants.Material.Water
local SOLID = Constants.Shape.Solid
local unpackByte1 = Constants.unpackByte1

local Collision = {}

-- Per-shape convex-Hull collision templates (geomO = 0), baked lazily. --
local templates: { [number]: MeshPart } = {}

local function getTemplate(shapeId: number): MeshPart
	local cached = templates[shapeId]
	if cached then
		return cached
	end
	local em = AssetService:CreateEditableMesh()
	for _, t in Shape.hullTriangles(shapeId, 0) do
		em:AddTriangle(em:AddVertex(t.a), em:AddVertex(t.b), em:AddVertex(t.c))
	end
	local _, baked = AssetService:CreateDataModelContentAsync(Content.fromObject(em))
	local part = AssetService:CreateMeshPartAsync(baked, { CollisionFidelity = Enum.CollisionFidelity.Hull })
	em:Destroy()
	part.Anchored = true
	part.CanCollide = true
	part.CanQuery = true -- raycasts hit the (invisible) collision geometry, not the render mesh
	part.CanTouch = true -- parts can detect when they touch terrain (.Touched)
	part.Transparency = 1
	part.Name = "WedgeCollisionTemplate_" .. shapeId
	-- kept nil-parented (out of the world) and alive via `templates`
	templates[shapeId] = part
	return part
end

local function lidx(lx: number, ly: number, lz: number): number
	return lx + lz * CHUNK + ly * (CHUNK * CHUNK) + 1
end

-- Local 16^3 boolean of "full solid cube" cells (material present, shape Solid). --
local function buildCubeMask(store: VoxelStore.Store, cx: number, cy: number, cz: number): { boolean }
	local mask = table.create(CHUNK * CHUNK * CHUNK, false)
	for ly = 0, CHUNK - 1 do
		for lz = 0, CHUNK - 1 do
			for lx = 0, CHUNK - 1 do
				local mat, byte1 = store:getCell(cx * CHUNK + lx, cy * CHUNK + ly, cz * CHUNK + lz)
				if mat ~= 0 and mat ~= WATER then
					local shape = unpackByte1(byte1)
					if shape == SOLID then
						mask[lidx(lx, ly, lz)] = true
					end
				end
			end
		end
	end
	return mask
end

export type Box = { x0: number, y0: number, z0: number, x1: number, y1: number, z1: number }

-- 3D greedy merge of the cube mask: extend X, then Y (whole row), then Z (slab). --
function Collision.greedyBoxes(mask: { boolean }): { Box }
	local visited = table.create(CHUNK * CHUNK * CHUNK, false)
	local function free(lx: number, ly: number, lz: number): boolean
		local i = lidx(lx, ly, lz)
		return mask[i] and not visited[i]
	end
	local boxes: { Box } = {}
	for ly = 0, CHUNK - 1 do
		for lz = 0, CHUNK - 1 do
			for lx = 0, CHUNK - 1 do
				if free(lx, ly, lz) then
					local x1 = lx
					while x1 + 1 <= CHUNK - 1 and free(x1 + 1, ly, lz) do
						x1 += 1
					end
					local y1 = ly
					local function rowOK(yy: number): boolean
						for xx = lx, x1 do
							if not free(xx, yy, lz) then
								return false
							end
						end
						return true
					end
					while y1 + 1 <= CHUNK - 1 and rowOK(y1 + 1) do
						y1 += 1
					end
					local z1 = lz
					local function slabOK(zz: number): boolean
						for yy = ly, y1 do
							for xx = lx, x1 do
								if not free(xx, yy, zz) then
									return false
								end
							end
						end
						return true
					end
					while z1 + 1 <= CHUNK - 1 and slabOK(z1 + 1) do
						z1 += 1
					end
					for zz = lz, z1 do
						for yy = ly, y1 do
							for xx = lx, x1 do
								visited[lidx(xx, yy, zz)] = true
							end
						end
					end
					boxes[#boxes + 1] = { x0 = lx, y0 = ly, z0 = lz, x1 = x1, y1 = y1, z1 = z1 }
				end
			end
		end
	end
	return boxes
end

local function colliderPart(): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = true
	p.CanQuery = true -- raycasts hit the (invisible) collision geometry, not the render mesh
	p.CanTouch = true -- parts can detect when they touch terrain (.Touched)
	p.Transparency = 1
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

local function folderName(cx: number, cy: number, cz: number): string
	return string.format("Col_%d_%d_%d", cx, cy, cz)
end

-- Rebuild a chunk's collision into `container`. Returns (#boxes, #wedges). --
function Collision.rebuildChunk(
	store: VoxelStore.Store,
	cx: number,
	cy: number,
	cz: number,
	container: Instance
): (number, number)
	local name = folderName(cx, cy, cz)
	local old = container:FindFirstChild(name)
	local folder = Instance.new("Folder")
	folder.Name = name

	local mask = buildCubeMask(store, cx, cy, cz)
	local boxes = Collision.greedyBoxes(mask)
	for _, b in boxes do
		local part = colliderPart()
		local w = (b.x1 - b.x0 + 1) * CELL
		local h = (b.y1 - b.y0 + 1) * CELL
		local d = (b.z1 - b.z0 + 1) * CELL
		part.Size = Vector3.new(w, h, d)
		part.Position = Vector3.new(
			(cx * CHUNK + b.x0) * CELL + w / 2,
			(cy * CHUNK + b.y0) * CELL + h / 2,
			(cz * CHUNK + b.z0) * CELL + d / 2
		)
		part.Parent = folder
	end

	local wedges = 0
	for ly = 0, CHUNK - 1 do
		for lz = 0, CHUNK - 1 do
			for lx = 0, CHUNK - 1 do
				local mat, byte1 = store:getCell(cx * CHUNK + lx, cy * CHUNK + ly, cz * CHUNK + lz)
				if mat ~= 0 and mat ~= WATER then
					local shape, storedO = unpackByte1(byte1)
					if shape ~= SOLID then
						local geomO = Shape.geomOrientation(shape, storedO)
						local clone = getTemplate(shape):Clone()
						clone.CFrame = CFrame.new(
							(cx * CHUNK + lx + 0.5) * CELL,
							(cy * CHUNK + ly + 0.5) * CELL,
							(cz * CHUNK + lz + 0.5) * CELL
						) * CFrame.Angles(0, -geomO * (math.pi / 2), 0)
						clone.Parent = folder
						wedges += 1
					end
				end
			end
		end
	end

	-- Swap in the fresh folder, then destroy the old one (no collision gap).
	folder.Parent = container
	if old then
		old:Destroy()
	end
	return #boxes, wedges
end

function Collision.removeChunk(cx: number, cy: number, cz: number, container: Instance)
	local f = container:FindFirstChild(folderName(cx, cy, cz))
	if f then
		f:Destroy()
	end
end

-- Bake all wedge collision templates up front (each yields once). Lets a streamer warm
-- the cache so the first chunk it builds doesn't stall on a mid-stream bake. --
function Collision.prewarmTemplates()
	getTemplate(Constants.Shape.VerticalWedge)
	getTemplate(Constants.Shape.CornerWedge)
	getTemplate(Constants.Shape.InverseCornerWedge)
	getTemplate(Constants.Shape.HorizontalWedge)
end

-- DDA cell picking ----------------------------------------------------------
export type Hit = { cellX: number, cellY: number, cellZ: number, face: number, pos: Vector3 }

-- March a ray (origin in studs, dir need not be unit) through the voxel grid;
-- return the first non-empty cell and the face index entered (1..6), or nil. --
function Collision.rayMarch(store: VoxelStore.Store, origin: Vector3, dir: Vector3, maxDist: number): Hit?
	local d = dir.Unit
	local inv = 1 / CELL

	local cx = math.floor(origin.X * inv)
	local cy = math.floor(origin.Y * inv)
	local cz = math.floor(origin.Z * inv)

	local function axis(o: number, dv: number): (number, number, number)
		-- returns step, tMax (studs to first boundary), tDelta (studs per cell)
		if dv == 0 then
			return 0, math.huge, math.huge
		end
		local step = dv > 0 and 1 or -1
		local edge = (math.floor(o * inv) + (step > 0 and 1 or 0)) * CELL
		return step, (edge - o) / dv, CELL / math.abs(dv)
	end

	local stepX, tMaxX, tDeltaX = axis(origin.X, d.X)
	local stepY, tMaxY, tDeltaY = axis(origin.Y, d.Y)
	local stepZ, tMaxZ, tDeltaZ = axis(origin.Z, d.Z)

	local t = 0
	local face = 0
	-- generous iteration cap based on range
	for _ = 1, math.ceil(maxDist * inv) + 3 do
		local mat = store:getCell(cx, cy, cz)
		if mat ~= 0 then
			return { cellX = cx, cellY = cy, cellZ = cz, face = face, pos = origin + d * t }
		end
		if tMaxX <= tMaxY and tMaxX <= tMaxZ then
			cx += stepX
			t = tMaxX
			tMaxX += tDeltaX
			face = stepX > 0 and 2 or 1 -- entered through -X / +X
		elseif tMaxY <= tMaxZ then
			cy += stepY
			t = tMaxY
			tMaxY += tDeltaY
			face = stepY > 0 and 4 or 3 -- entered through -Y / +Y
		else
			cz += stepZ
			t = tMaxZ
			tMaxZ += tDeltaZ
			face = stepZ > 0 and 6 or 5 -- entered through -Z / +Z
		end
		if t > maxDist then
			return nil
		end
	end
	return nil
end

return Collision
