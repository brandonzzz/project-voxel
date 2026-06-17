--!strict
--[[
	Mesher — turns a chunk's voxel cells into baked render MeshPart(s).

	Pipeline:
	  1. ONE cull pass collects every surviving triangle (axis faces per the cull
	     rule, slope faces always), tagging each with its octant. Neighbour chunks
	     are sampled at borders so there are no seams.
	  2. Decide split: if the triangle count would approach the 20k EditableMesh
	     limit (the rare checkerboard case) the triangles are partitioned into up
	     to eight 8^3 octant meshes; otherwise one mesh.
	  3. fillAndBake each (sub)mesh: a fresh EditableMesh centred on its own bbox,
	     unique verts per triangle (default flat normals, default UVs) + per-material
	     vertex colours, then CreateDataModelContentAsync (releases the editable
	     budget) -> CreateMeshPartAsync -> ApplyMesh onto the persistent part.

	Per-face geometry (no greedy meshing). Culling keeps typical chunks small. The
	voxel buffer is the only source of truth; every MeshPart is a regenerable cache.
	A `yielder` may be supplied to time-slice the cull + fill across frames.
]]

local AssetService = game:GetService("AssetService")

local Constants = require(script.Parent.Constants)
local Shape = require(script.Parent.Shape)
local VoxelStore = require(script.Parent.VoxelStore)
local MaterialPalette = require(script.Parent.MaterialPalette)
local TextureAtlas = require(script.Parent.TextureAtlas)

local CELL = Constants.CELL
local HALF_CELL = Constants.CELL / 2
local CHUNK = Constants.CHUNK
local CHUNK_STUDS = Constants.CHUNK_STUDS
local WATER = Constants.Material.Water
local unpackCell = Constants.unpackCell
local unpackByte1 = Constants.unpackByte1
local geomOrientation = Shape.geomOrientation
local faceMaskBits = Shape.faceMaskBits
local hullTriangles = Shape.hullTriangles

-- Split when triangles would approach the 20k EditableMesh limit. 9,500 quads ~=
-- 19,000 tris (the brief's threshold); 3 verts/tri -> 57k verts < 60k.
local TRI_SPLIT_THRESHOLD = 19000

-- Per-face neighbour direction (local cell deltas) and opposing face index.
-- FACES order: 1=+X 2=-X 3=+Y 4=-Y 5=+Z 6=-Z
local FDX = { 1, -1, 0, 0, 0, 0 }
local FDY = { 0, 0, 1, -1, 0, 0 }
local FDZ = { 0, 0, 0, 0, 1, -1 }
local OPPOSITE = { 2, 1, 4, 3, 6, 5 }

local Mesher = {}

-- Debug counter of live EditableMesh allocations (must stay <= 4 under the M4
-- semaphore; one build holds one at a time so a single build peaks at 1).
Mesher.liveEditables = 0
Mesher.maxLiveEditables = 0

local function acquireEditable(): EditableMesh
	local em = AssetService:CreateEditableMesh()
	Mesher.liveEditables += 1
	if Mesher.liveEditables > Mesher.maxLiveEditables then
		Mesher.maxLiveEditables = Mesher.liveEditables
	end
	return em
end

local function releaseEditable(em: EditableMesh)
	em:Destroy()
	Mesher.liveEditables -= 1
end

local function octantOf(lx: number, ly: number, lz: number): number
	return (lx >= 8 and 1 or 0) + (ly >= 8 and 2 or 0) + (lz >= 8 and 4 or 0)
end

-- Rotate UV by `rot` quarter-turns (calibrates slope-face texture orientation). --
local function rotUV(u: number, v: number, rot: number): (number, number)
	if rot == 1 then
		return v, 1 - u
	elseif rot == 2 then
		return 1 - u, 1 - v
	elseif rot == 3 then
		return 1 - v, u
	end
	return u, v
end

-- Cull pass over a local cell range, invoking emit(p1,p2,p3, materialId, octant)
-- for each surviving triangle. Positions are chunk-local studs (0..CHUNK_STUDS). --
local function forEachTriangle(
	store: VoxelStore.Store,
	cx: number,
	cy: number,
	cz: number,
	lxlo: number,
	lxhi: number,
	lylo: number,
	lyhi: number,
	lzlo: number,
	lzhi: number,
	emit: (Vector3, Vector3, Vector3, number, number, number, number, number, number, boolean, boolean, number, number, number) -> (),
	yielder: (() -> ())?
)
	local sample = store:makeNeighborSampler(cx, cy, cz)
	local emitFace = table.create(6)
	local emitted = 0
	for lx = lxlo, lxhi do
		for ly = lylo, lyhi do
			for lz = lzlo, lzhi do
				local mat, byte1 = unpackCell(sample(lx, ly, lz))
				if mat ~= 0 and mat ~= WATER then
					local shape, storedO = unpackByte1(byte1)
					local geomO = geomOrientation(shape, storedO)

					for f = 1, 6 do
						local myMask = faceMaskBits(shape, geomO, f)
						if myMask == 0 then
							emitFace[f] = false
						else
							local nMat, nByte1 = unpackCell(sample(lx + FDX[f], ly + FDY[f], lz + FDZ[f]))
							if nMat == 0 or nMat == WATER then
								emitFace[f] = true -- empty / water neighbour never culls a solid
							else
								local nShape, nStoredO = unpackByte1(nByte1)
								local nMask = faceMaskBits(nShape, geomOrientation(nShape, nStoredO), OPPOSITE[f])
								emitFace[f] = bit32.band(myMask, bit32.band(0xF, bit32.bnot(nMask))) ~= 0
							end
						end
					end

					local oct = octantOf(lx, ly, lz)
					local ox = (lx + 0.5) * CELL
					local oy = (ly + 0.5) * CELL
					local oz = (lz + 0.5) * CELL
					local cwx, cwy, cwz = cx * CHUNK + lx, cy * CHUNK + ly, cz * CHUNK + lz
					local topExposed = emitFace[3] == true -- +Y emitted -> grass-fringe variant
					for _, t in hullTriangles(shape, geomO) do
						if t.face == 0 or emitFace[t.face] then
							local crest = false
							if t.face == 0 then
								-- crest = ramp does not continue uphill (cell above the
								-- uphill neighbour is empty); uphill = opposite the slope
								-- normal's dominant horizontal axis.
								-- uphill = cell above the uphill neighbour. InverseCorner is special: a
								-- corner stacks DIRECTLY above it (aligned), so it is a top only when the
								-- cell straight above is empty -- unlike wedges/corners (diagonal uphill).
								local udx, udz = 0, 0
								if shape ~= Shape.Id.InverseCornerWedge then
									local nx, nz = t.n.X, t.n.Z
									udx = (nx > 1e-3) and -1 or (nx < -1e-3) and 1 or 0
									udz = (nz > 1e-3) and -1 or (nz < -1e-3) and 1 or 0
								end
								crest = unpackCell(sample(lx + udx, ly + 1, lz + udz)) == 0
							end
							emit(
								Vector3.new(ox + t.a.X, oy + t.a.Y, oz + t.a.Z),
								Vector3.new(ox + t.b.X, oy + t.b.Y, oz + t.b.Z),
								Vector3.new(ox + t.c.X, oy + t.c.Y, oz + t.c.Z),
								mat,
								oct,
								t.face,
								cwx,
								cwy,
								cwz,
								topExposed,
								crest,
								ox,
								oy,
								oz
							)
							emitted += 1
							if yielder and emitted % 512 == 0 then
								yielder()
							end
						end
					end
				end
			end
		end
	end
end

local function countRange(
	store: VoxelStore.Store,
	cx: number,
	cy: number,
	cz: number,
	lxlo: number,
	lxhi: number,
	lylo: number,
	lyhi: number,
	lzlo: number,
	lzhi: number,
	yielder: (() -> ())?
): number
	local n = 0
	forEachTriangle(store, cx, cy, cz, lxlo, lxhi, lylo, lyhi, lzlo, lzhi, function()
		n += 1
	end, yielder)
	return n
end

function Mesher.countChunk(store: VoxelStore.Store, cx: number, cy: number, cz: number, yielder: (() -> ())?): number
	return countRange(store, cx, cy, cz, 0, CHUNK - 1, 0, CHUNK - 1, 0, CHUNK - 1, yielder)
end

export type Tri = {
	p1: Vector3,
	p2: Vector3,
	p3: Vector3,
	mat: number,
	oct: number,
	face: number, -- 1..6 axis (per Shape.FACES), 0 = slope
	cwx: number,
	cwy: number,
	cwz: number, -- world cell coords (texture tiling)
	topExposed: boolean, -- cell's +Y face is emitted (side grass-fringe variant)
	slopeCrest: boolean, -- slope does not continue uphill (slope crest variant)
	ccx: number,
	ccy: number,
	ccz: number, -- cell centre (chunk-local studs) for in-cell UV coords
}

-- Single cull pass over a range; returns the collected triangles + count. --
local function collectRange(
	store: VoxelStore.Store,
	cx: number,
	cy: number,
	cz: number,
	lxlo: number,
	lxhi: number,
	lylo: number,
	lyhi: number,
	lzlo: number,
	lzhi: number,
	yielder: (() -> ())?
): ({ Tri }, number)
	local collected: { Tri } = {}
	forEachTriangle(
		store,
		cx,
		cy,
		cz,
		lxlo,
		lxhi,
		lylo,
		lyhi,
		lzlo,
		lzhi,
		function(p1, p2, p3, mat, oct, face, cwx, cwy, cwz, topExposed, slopeCrest, ccx, ccy, ccz)
			collected[#collected + 1] = {
				p1 = p1,
				p2 = p2,
				p3 = p3,
				mat = mat,
				oct = oct,
				face = face,
				cwx = cwx,
				cwy = cwy,
				cwz = cwz,
				topExposed = topExposed,
				slopeCrest = slopeCrest,
				ccx = ccx,
				ccy = ccy,
				ccz = ccz,
			}
		end,
		yielder
	)
	return collected, #collected
end

-- Fill + bake one EditableMesh from a triangle list, centred on its own bbox.
-- Returns (bakedContent, triCount, vertCount, centerLocal) or nil when empty. --
local function fillAndBake(
	tris: { Tri },
	yielder: (() -> ())?,
	assetGate: (() -> ())?,
	cubeCenter: Vector3?,
	cubeHalf: Vector3?
): (Content?, number, number, Vector3?, boolean?)
	local count = #tris
	if count == 0 then
		return nil, 0, 0, nil
	end

	-- The mesh is centred on `center`; the part's Position is then chunkOrigin + center, so the
	-- geometry lands at the same world spot regardless of `center`. The streaming path supplies a
	-- FIXED cube centre (and pads the bbox to the cube below) so the part's transform is constant
	-- across rebuilds; tests pass nil and fall back to the tight bounding-box centre.
	local center: Vector3
	if cubeCenter then
		center = cubeCenter
	else
		local minX, minY, minZ = math.huge, math.huge, math.huge
		local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
		for _, t in tris do
			for _, p in { t.p1, t.p2, t.p3 } do
				if p.X < minX then minX = p.X end
				if p.Y < minY then minY = p.Y end
				if p.Z < minZ then minZ = p.Z end
				if p.X > maxX then maxX = p.X end
				if p.Y > maxY then maxY = p.Y end
				if p.Z > maxZ then maxZ = p.Z end
			end
		end
		center = Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
	end

	-- Unique verts per triangle => default normals are flat (crisp). Textured mode
	-- assigns atlas UVs per face type; otherwise per-material vertex colours.
	local em = acquireEditable()
	local textured = TextureAtlas.ENABLED
	local colorIds: { [number]: number } = {}
	local uvIds: { [string]: number } = {} -- share UV ids for repeated sub-tile corners
	local function getUV(u: number, v: number): number
		local key = string.format("%d_%d", math.floor(u * 8192 + 0.5), math.floor(v * 8192 + 0.5))
		local id = uvIds[key]
		if not id then
			id = em:AddUV(Vector2.new(u, v))
			uvIds[key] = id
		end
		return id
	end

	local filled = 0
	for _, t in tris do
		local fid =
			em:AddTriangle(em:AddVertex(t.p1 - center), em:AddVertex(t.p2 - center), em:AddVertex(t.p3 - center))

		if textured then
			local ft
			if t.face == 3 then
				ft = "TOP"
			elseif t.face == 4 then
				ft = "BOTTOM"
			elseif t.face == 0 then
				ft = "SLOPE"
			else
				ft = "SIDE"
			end
			local isHWSide = (t.face == 0) and (math.abs(((t.p2 - t.p1):Cross(t.p3 - t.p1)).Unit.Y) < 0.3)
				if isHWSide then
					ft = "SIDE" -- HorizontalWedge's vertical chamfer: texture like a solid's side
				end
				-- across phase uses the cell coord along the slope's WIDTH axis only (so the
				-- across texture does not shift one voxel per row as the slope rises).
				local slopeAcross: number? = nil
				if t.face == 0 then
					local sw = ((t.p2 - t.p1):Cross(t.p3 - t.p1)):Cross(Vector3.yAxis)
					slopeAcross = (math.abs(sw.X) >= math.abs(sw.Z)) and t.cwx or t.cwz
				end
				local u0, v0, u1, v1 = TextureAtlas.faceRect(ft, t.mat, t.cwx, t.cwy, t.cwz, t.topExposed, t.slopeCrest, slopeAcross)
			local cmx, cmy, cmz = t.ccx - HALF_CELL, t.ccy - HALF_CELL, t.ccz - HALF_CELL
			-- Slope UV: U runs along the slope's horizontal (XZ-plane) edge (= normal x Y),
			-- V up the slope; the face's (U,V) bounding box maps to the sub-tile, anchored
			-- so V=0 sits on the lowest (horizontal) edge. Works for cardinal ramps and the
			-- diagonal corner / inverse-corner faces alike.
			local sU = Vector3.zero
			local sV = Vector3.zero
			local sMinU, sRngU, sMinV, sRngV = 0, 1, 0, 1
			if t.face == 0 then -- slope basis (also for HW chamfer textured as side)
				local n = (t.p2 - t.p1):Cross(t.p3 - t.p1)
				if n.Y < 0 then
					n = -n
				end
				n = (n.Magnitude > 1e-5) and n.Unit or Vector3.yAxis
				sU = n:Cross(Vector3.yAxis)
				sU = (sU.Magnitude > 1e-4) and sU.Unit or Vector3.xAxis
				sV = sU:Cross(n).Unit
				if sV.Y < 0 then
					sV = -sV
				end
				local u1, u2, u3 = t.p1:Dot(sU), t.p2:Dot(sU), t.p3:Dot(sU)
				local v1, v2, v3 = t.p1:Dot(sV), t.p2:Dot(sV), t.p3:Dot(sV)
				sMinU = math.min(u1, u2, u3)
				sRngU = math.max(u1, u2, u3) - sMinU
				sMinV = math.min(v1, v2, v3)
				sRngV = math.max(v1, v2, v3) - sMinV
				if sRngU < 1e-4 then
					sRngU = 1
				end
				if sRngV < 1e-4 then
					sRngV = 1
				end
			end
			local function vertUV(p: Vector3): number
				local icx, icy, icz = (p.X - cmx) / CELL, (p.Y - cmy) / CELL, (p.Z - cmz) / CELL
				local pu, pv
				if ft == "TOP" or ft == "BOTTOM" then
					pu, pv = icx, icz
				elseif ft == "SIDE" then
					if isHWSide then
						pu, pv = (p:Dot(sU) - sMinU) / sRngU, 1 - icy
					elseif t.face == 1 or t.face == 2 then
						pu, pv = icz, 1 - icy
					else
						pu, pv = icx, 1 - icy
					end
				else -- SLOPE: anchored to the horizontal (XZ) edge via the n x Y basis (works
					-- for wedges AND diagonal corners); the per-cell tile is chosen by world
					-- position in faceRect so neighbours tile seamlessly, like the SIDE faces.
					-- down-slope = vertical height (icy): cell-aligned like the SIDE faces, so
					-- the cwy tile phase + within-cell fraction combine seamlessly (the tilted
					-- up-slope vector spans CELL*sqrt2 and would not align). across = sU edge.
					-- Axis-aligned to the voxel's XZ footprint. WEDGES (cardinal normal): down =
					-- height (icy) -- direction-consistent so all four facings tile vertically;
					-- on the 45 face icy == the downhill axis, so it is still the XZ square.
					-- across = the perpendicular cardinal axis. CORNERS (diagonal normal): the
					-- XZ square (icx,icz) so the triangle is a cell-aligned half-square (90deg
					-- swap reverted per the texture's authored orientation). sU = (-nz,0,nx).
					if math.abs(sU.X) >= math.abs(sU.Z) then
						pu, pv = icy, icx -- project from Z about Y (across = X); corners use this too
					else
						pu, pv = icy, icz -- project from X about Y (across = Z); corners use this too
					end
				end
				if ft == "SLOPE" then
					pu, pv = rotUV(pu, pv, TextureAtlas.SLOPE_ROT)
				end
				return getUV(u0 + (u1 - u0) * math.clamp(pu, 0, 1), v0 + (v1 - v0) * math.clamp(pv, 0, 1))
			end
			em:SetFaceUVs(fid, { vertUV(t.p1), vertUV(t.p2), vertUV(t.p3) })
		else
			local cid = colorIds[t.mat]
			if not cid then
				cid = em:AddColor(MaterialPalette.color(t.mat), 1)
				colorIds[t.mat] = cid
			end
			em:SetFaceColors(fid, { cid, cid, cid })
		end

		filled += 1
		if yielder and filled % 512 == 0 then
			yielder()
		end
	end

	-- Pin the mesh bbox to the fixed chunk/octant cube so the baked part's Size -- and therefore
	-- its Position -- are CONSTANT across rebuilds. With a constant transform, ApplyMesh is a pure
	-- in-place geometry swap: there is no Size/Position update to lag a frame behind the swapped
	-- geometry (which made the chunk "shift then snap back"), and the reused part never blinks out.
	-- Two zero-area triangles at opposite cube corners extend the vertex bounds to the full cube
	-- without drawing anything; they are not included in the returned triangle count.
	if cubeCenter and cubeHalf then
		local lo = em:AddVertex(-cubeHalf)
		local hi = em:AddVertex(cubeHalf)
		em:AddTriangle(lo, lo, lo)
		em:AddTriangle(hi, hi, hi)
	end

	-- Gate the (main-thread-blocking) bake so at most `assetGate` allows N AssetService ops per
	-- frame across all concurrent builds -- see rebuildChunk. Spreads the spikes one-per-frame.
	if assetGate then
		assetGate()
	end
	local result, baked = AssetService:CreateDataModelContentAsync(Content.fromObject(em))
	releaseEditable(em)
	if result == Enum.CreateContentResult.StorageLimitExceeded then
		-- The server's 200 MB/server static-content budget is full. Don't crash: signal the caller
		-- (5th return) so a server streamer can LRU-evict an old chunk's mesh and retry. Clients are
		-- limited only by disk space and never hit this. See [[server-render-architecture-findings]].
		return nil, 0, 0, nil, true
	elseif result ~= Enum.CreateContentResult.Success then
		error("CreateDataModelContentAsync failed: " .. tostring(result))
	end
	return baked, count, count * 3, center, false
end

-- Range-based build (kept for tests): collect a range then fill + bake. --
function Mesher.buildSubMesh(
	store: VoxelStore.Store,
	cx: number,
	cy: number,
	cz: number,
	lxlo: number,
	lxhi: number,
	lylo: number,
	lyhi: number,
	lzlo: number,
	lzhi: number,
	yielder: (() -> ())?
): (Content?, number, number, Vector3?)
	local tris = collectRange(store, cx, cy, cz, lxlo, lxhi, lylo, lyhi, lzlo, lzhi, yielder)
	return fillAndBake(tris, yielder)
end

-- Render the chunk into a PERSISTENT per-chunk MeshPart. Because the part's transform is fixed
-- (its bbox is pinned to the chunk/octant cube in fillAndBake), a rebuild only swaps geometry via
-- ApplyMesh -- Size/Position never change. That avoids two artifacts seen while iterating on this:
--   (1) recreating the part each edit blinks the chunk out for the frame before the new mesh is
--       GPU-resident;
--   (2) moving the part to follow a tight bbox makes the chunk "shift then snap back", because
--       ApplyMesh commits the new geometry a frame after the cheap transform update.
-- A fixed transform + in-place ApplyMesh has neither: the part is always present and never moves. --
local function applyOrCreate(container: Instance, name: string, baked: Content, position: Vector3)
	local source = AssetService:CreateMeshPartAsync(baked, { CollisionFidelity = Enum.CollisionFidelity.Box })
	local existing = container:FindFirstChild(name)
	if existing and existing:IsA("MeshPart") then
		-- Pure in-place geometry swap. The new mesh's bbox equals the part's (fixed cube) Size, so
		-- ApplyMesh's "keep the old Size" renders it 1:1, and Position is left untouched. No
		-- transform update => no shift; the part never leaves the tree => no blink.
		existing:ApplyMesh(source)
		source:Destroy()
		-- One atlas TextureID per chunk part (still one draw call). Re-set each rebuild so toggling
		-- TEXTURE_ENABLED takes effect on the next rebuild. Not a transform, so it cannot shift.
		existing.TextureID = TextureAtlas.ENABLED and TextureAtlas.ASSET_ID or ""
	else
		if existing then
			existing:Destroy()
		end
		source.Name = name
		source.Anchored = true
		-- Visual only: let raycasts pass THROUGH the mesh so they hit the (invisible)
		-- collision boxes/wedges instead -- cleaner, blocky hit geometry for gameplay.
		source.CanQuery = false
		source.CanTouch = false
		source.CanCollide = false -- physics is the separate Collision system
		-- NOTE: default-camera (Poppercam) occlusion against terrain is a known limitation -- render
		-- parts are opaque but not CanCollide, so the default camera does not occlude against them.
		-- Fix later via a custom occlusion pass. See the camera-occlusion notes.
		source.Material = Enum.Material.Fabric -- matte; reads better than SmoothPlastic
		source.Color = Color3.new(1, 1, 1)
		source.Position = position -- fixed chunk/octant cube centre; constant for the part's lifetime
		source.TextureID = TextureAtlas.ENABLED and TextureAtlas.ASSET_ID or ""
		source.Parent = container
	end
end

export type RebuildStats =
	{ tris: number, verts: number, split: boolean, parts: number, buildMs: number, storageLimited: boolean }

-- Rebuild a chunk's render mesh(es) into `container` with a SINGLE cull pass. `assetGate`, if
-- given, is called once before EACH main-thread-blocking AssetService op (the bake and each
-- CreateMeshPartAsync) so the streamer can cap how many run per frame -- spreading the unavoidable
-- ~16-24 ms-per-op cost one-per-frame instead of letting concurrent builds stack into one stutter. --
function Mesher.rebuildChunk(
	store: VoxelStore.Store,
	cx: number,
	cy: number,
	cz: number,
	container: Instance,
	yielder: (() -> ())?,
	assetGate: (() -> ())?
): RebuildStats
	local t0 = os.clock()
	local baseName = string.format("C_%d_%d_%d", cx, cy, cz)
	local origin = Vector3.new(cx * CHUNK_STUDS, cy * CHUNK_STUDS, cz * CHUNK_STUDS)

	local collected, total = collectRange(store, cx, cy, cz, 0, CHUNK - 1, 0, CHUNK - 1, 0, CHUNK - 1, yielder)
	local split = total > TRI_SPLIT_THRESHOLD
	local desired: { [string]: boolean } = {}
	local parts = 0
	local storageLimited = false -- set if any (sub)mesh bake hit the server static-content budget

	if total > 0 and not split then
		-- Fixed transform: centre the part on the full chunk cube and pin its bbox to it.
		local cc = Vector3.new(CHUNK_STUDS / 2, CHUNK_STUDS / 2, CHUNK_STUDS / 2)
		local baked, _, _, center, sl = fillAndBake(collected, yielder, assetGate, cc, cc)
		storageLimited = storageLimited or sl == true
		if baked then
			if assetGate then -- gate CreateMeshPartAsync too, so it can't stack with a bake in one frame
				assetGate()
			end
			applyOrCreate(container, baseName, baked, origin + (center :: Vector3))
			desired[baseName] = true
			parts = 1
		end
	elseif split then
		-- partition the already-collected triangles by octant (no re-cull)
		local buckets: { { Tri } } = {}
		for oi = 0, 7 do
			buckets[oi] = {}
		end
		for _, t in collected do
			local b = buckets[t.oct]
			b[#b + 1] = t
		end
		-- Each octant is a fixed half-chunk cube; pin its bbox so its transform is constant too.
		local oct = CHUNK_STUDS / 2 -- octant edge length (studs)
		local q = CHUNK_STUDS / 4 -- octant half-extent
		for oi = 0, 7 do
			local ox, oy, oz = oi % 2, math.floor(oi / 2) % 2, math.floor(oi / 4) % 2
			local cc = Vector3.new(ox * oct + q, oy * oct + q, oz * oct + q)
			local baked, _, _, center, sl = fillAndBake(buckets[oi], yielder, assetGate, cc, Vector3.new(q, q, q))
			storageLimited = storageLimited or sl == true
			if baked then
				local nm = baseName .. "_oct" .. oi
				if assetGate then -- gate CreateMeshPartAsync too (one AssetService op per frame)
					assetGate()
				end
				applyOrCreate(container, nm, baked, origin + (center :: Vector3))
				desired[nm] = true
				parts += 1
			end
		end
	end

	for _, ch in container:GetChildren() do
		if (ch.Name == baseName or string.match(ch.Name, "^" .. baseName .. "_oct%d$")) and not desired[ch.Name] then
			ch:Destroy()
		end
	end

	return {
		tris = total,
		verts = total * 3,
		split = split,
		parts = parts,
		buildMs = (os.clock() - t0) * 1000,
		storageLimited = storageLimited,
	}
end

Mesher.TRI_SPLIT_THRESHOLD = TRI_SPLIT_THRESHOLD

return Mesher
