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
local WaterRender = require(script.Parent.WaterRender) -- for the water-sample look (texture/tile/colour); no cycle

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
-- `sample(lx,ly,lz) -> rawValue` over local coords -1..16 (chunk + 1-cell borders). The caller
-- supplies it -- store:makeNeighborSampler on the main thread, or a padded-buffer reader inside a
-- worker Actor -- so the cull is decoupled from the store and can run in parallel.
local function forEachTriangle(
	sample: (number, number, number) -> number,
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
	forEachTriangle(store:makeNeighborSampler(cx, cy, cz), cx, cy, cz, lxlo, lxhi, lylo, lyhi, lzlo, lzhi, function()
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
		store:makeNeighborSampler(cx, cy, cz),
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

-- ===== Parallel-collect support (worker-Actor offload of the cull) ============================
-- The cull/face-extraction is pure Lua, so it can run in a worker Actor. The main thread snapshots
-- the chunk (buildPaddedChunk) into a string an Actor can read (SharedTable can't hold a buffer);
-- the Actor rebuilds a sampler (makePaddedSampler), runs the cull emitting to a flat f32 buffer
-- (collectToBuffer), and the main thread turns that back into a Tri list (deserializeTris) to feed
-- the existing fillAndBake. 20 floats/triangle (see Tri).
local TRI_FLOATS = 20
local PAD = CHUNK + 2 -- 18: chunk 0..15 + a 1-cell border each side, indexed by +1

-- 18^3 raw-value snapshot of the chunk + its 1-cell shell (local coords -1..16), as a binary string. --
function Mesher.buildPaddedChunk(store: VoxelStore.Store, cx: number, cy: number, cz: number): string
	local buf = buffer.create(PAD * PAD * PAD * 2)
	local read = store:makeChunkReader(cx, cy, cz) -- fast path for the chunk's own 0..15 cells
	local sampler = store:makeNeighborSampler(cx, cy, cz) -- the -1 / 16 border shell (neighbour chunks)
	for ly = -1, CHUNK do
		for lz = -1, CHUNK do
			for lx = -1, CHUNK do
				local raw
				if lx >= 0 and lx < CHUNK and ly >= 0 and ly < CHUNK and lz >= 0 and lz < CHUNK then
					raw = read(lx, ly, lz)
				else
					raw = sampler(lx, ly, lz)
				end
				buffer.writeu16(buf, ((lx + 1) + (lz + 1) * PAD + (ly + 1) * PAD * PAD) * 2, raw)
			end
		end
	end
	return buffer.tostring(buf)
end

-- Reconstruct a sample(lx,ly,lz)->raw over local coords -1..16 from a padded-chunk string. --
function Mesher.makePaddedSampler(paddedStr: string): (number, number, number) -> number
	local buf = buffer.fromstring(paddedStr)
	return function(lx: number, ly: number, lz: number): number
		return buffer.readu16(buf, ((lx + 1) + (lz + 1) * PAD + (ly + 1) * PAD * PAD) * 2)
	end
end

-- Run the cull via `sample`, serializing every surviving triangle to a flat f32 buffer string.
-- Returns (bufferString, triangleCount). Pure Lua -> safe inside a worker Actor. --
function Mesher.collectToBuffer(
	sample: (number, number, number) -> number,
	cx: number,
	cy: number,
	cz: number,
	yielder: (() -> ())?
): (string, number)
	local out: { number } = {}
	local k = 0
	forEachTriangle(
		sample,
		cx,
		cy,
		cz,
		0,
		CHUNK - 1,
		0,
		CHUNK - 1,
		0,
		CHUNK - 1,
		function(p1, p2, p3, mat, oct, face, cwx, cwy, cwz, topExposed, slopeCrest, ccx, ccy, ccz)
			out[k + 1], out[k + 2], out[k + 3] = p1.X, p1.Y, p1.Z
			out[k + 4], out[k + 5], out[k + 6] = p2.X, p2.Y, p2.Z
			out[k + 7], out[k + 8], out[k + 9] = p3.X, p3.Y, p3.Z
			out[k + 10], out[k + 11], out[k + 12] = mat, oct, face
			out[k + 13], out[k + 14], out[k + 15] = cwx, cwy, cwz
			out[k + 16], out[k + 17], out[k + 18] = ccx, ccy, ccz
			out[k + 19] = topExposed and 1 or 0
			out[k + 20] = slopeCrest and 1 or 0
			k += TRI_FLOATS
		end,
		yielder
	)
	local buf = buffer.create(k * 4)
	for i = 0, k - 1 do
		buffer.writef32(buf, i * 4, out[i + 1])
	end
	return buffer.tostring(buf), k // TRI_FLOATS
end

-- Turn a collectToBuffer string back into a Tri list (main thread, after the Actor returns). --
function Mesher.deserializeTris(bufStr: string, count: number): { Tri }
	local buf = buffer.fromstring(bufStr)
	local tris: { Tri } = table.create(count)
	for t = 0, count - 1 do
		local o = t * TRI_FLOATS * 4
		tris[t + 1] = {
			p1 = Vector3.new(buffer.readf32(buf, o), buffer.readf32(buf, o + 4), buffer.readf32(buf, o + 8)),
			p2 = Vector3.new(buffer.readf32(buf, o + 12), buffer.readf32(buf, o + 16), buffer.readf32(buf, o + 20)),
			p3 = Vector3.new(buffer.readf32(buf, o + 24), buffer.readf32(buf, o + 28), buffer.readf32(buf, o + 32)),
			mat = buffer.readf32(buf, o + 36),
			oct = buffer.readf32(buf, o + 40),
			face = buffer.readf32(buf, o + 44),
			cwx = buffer.readf32(buf, o + 48),
			cwy = buffer.readf32(buf, o + 52),
			cwz = buffer.readf32(buf, o + 56),
			ccx = buffer.readf32(buf, o + 60),
			ccy = buffer.readf32(buf, o + 64),
			ccz = buffer.readf32(buf, o + 68),
			topExposed = buffer.readf32(buf, o + 72) ~= 0,
			slopeCrest = buffer.readf32(buf, o + 76) ~= 0,
		}
	end
	return tris
end
-- =============================================================================================

-- Fill + bake one EditableMesh from a triangle list, centred on its own bbox.
-- Returns (bakedContent, triCount, vertCount, centerLocal) or nil when empty. --
local function fillAndBake(
	tris: { Tri },
	yielder: (() -> ())?,
	assetGate: (() -> ())?,
	cubeCenter: Vector3?,
	cubeHalf: Vector3?,
	texturedOverride: boolean? -- nil = follow TextureAtlas.ENABLED; false = force vertex-colour (e.g. water, off-atlas)
): (Content?, number, number, Vector3?)
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
	local textured = if texturedOverride ~= nil then texturedOverride else TextureAtlas.ENABLED
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
	if result ~= Enum.CreateContentResult.Success then
		error("CreateDataModelContentAsync failed: " .. tostring(result))
	end
	return baked, count, count * 3, center
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

-- Triangles for ONE isolated voxel (all faces, no culling) of `shape`+`material` at orientation 0,
-- centred on the cell origin (verts are already cell-centre-relative, +/- HALF_CELL). --
local function oneCellTris(shape: number, material: number): { Tri }
	local tris: { Tri } = {}
	for _, t in hullTriangles(shape, 0) do
		tris[#tris + 1] = {
			p1 = t.a,
			p2 = t.b,
			p3 = t.c,
			mat = material,
			oct = 0,
			face = t.face,
			cwx = 0,
			cwy = 0,
			cwz = 0,
			topExposed = true, -- isolated voxel: top face shows the exposed (grass-fringe) variant
			slopeCrest = true, -- and slopes show their crest variant
			ccx = 0,
			ccy = 0,
			ccz = 0,
		}
	end
	return tris
end

-- Baked single-voxel STATIC content, keyed by shape*256 + material. fillAndBake builds an EditableMesh,
-- bakes it to immutable content with CreateDataModelContentAsync, and DESTROYS the EditableMesh -- so a
-- cached entry holds zero Editable* memory budget (the same EM -> bake -> destroy cycle the chunk
-- renderer uses). Each sampleVoxel call then spins a fresh MeshPart off the cached static content. --
local sampleCache: { [number]: Content } = {}

-- Serialize first-time sample bakes. fillAndBake yields (CreateDataModelContentAsync), so concurrent
-- callers -- e.g. a parts palette that task.spawns one preview per material -- would each create an
-- EditableMesh before any is destroyed, stacking N live editables and blowing the Editable* memory
-- budget. This gate keeps at most ONE sample bake in flight; cached combos skip it entirely (just a
-- CreateMeshPartAsync off the already-baked static content). Cooperative single-thread, so a plain flag
-- suffices: a waiter only re-enters after the holder cleared the flag with no yield in between. --
local baking = false

-- Bake (once, then cache) a single voxel of `shape`+`material` at orientation 0 to STATIC content, then
-- return a FRESH UNPARENTED, ANCHORED MeshPart built from it (DEFAULT collision fidelity; CanCollide is
-- left at its default of true) -- for part representations of voxels (debris, picked-up blocks,
-- previews). The mesh is centred on the cell, so the caller positions the part by the voxel centre and
-- rotates the part's CFrame for non-zero orientations. No cube-pinning, so the collision geometry
-- matches the actual shape (not a full cube).
--
-- WATER is special: it has no atlas tile and isn't real swim-water here, so a water sample is ALWAYS a
-- solid cube (the passed `shape` is ignored) and is dressed like the in-world water -- SmoothPlastic +
-- Steel-blue base + the water surface texture on every face -- but STATIC (no scroll). It is a solid,
-- collidable part standing in for water. --
function Mesher.sampleVoxel(shape: number, material: number): MeshPart
	local isWater = material == WATER
	if isWater then
		shape = Constants.Shape.Solid -- water sample is always a block, regardless of the CellBlock passed in
	end
	local key = shape * 256 + material
	local baked = sampleCache[key]
	if not baked then
		while baking do
			task.wait() -- another sample is baking; wait so only one EditableMesh is ever live
		end
		baked = sampleCache[key] -- a waiter ahead of us may have just baked this same combo
		if not baked then
			-- EditableMesh -> static content -> destroy the EditableMesh, all inside fillAndBake, so
			-- nothing lingers on the Editable* budget once the static content is cached. Water bakes
			-- textured-mode (clean white verts, atlas UVs unused) so its look is driven entirely by the
			-- base colour + face textures applied below.
			baking = true
			local textured: boolean? = if isWater then true else nil
			local ok, result = pcall(fillAndBake, oneCellTris(shape, material), nil, nil, Vector3.zero, nil, textured)
			baking = false -- always clear, even on failure, so the gate can't deadlock
			if not ok then
				error("Mesher.sampleVoxel: bake failed -- " .. tostring(result))
			end
			if not result then
				error(string.format("Mesher.sampleVoxel: shape %d produced no geometry", shape))
			end
			baked = result
			sampleCache[key] = baked
		end
	end
	local part = AssetService:CreateMeshPartAsync(baked, { CollisionFidelity = Enum.CollisionFidelity.Default })
	part.Name = string.format("Voxel_%d_%d", shape, material)
	part.Anchored = true
	if isWater then
		part.TextureID = "" -- water isn't on the atlas
		part.Material = Enum.Material.SmoothPlastic
		part.BrickColor = BrickColor.new(WaterRender.BRICKCOLOR) -- Steel-blue base under the texture
		for _, face in Enum.NormalId:GetEnumItems() do
			local tex = Instance.new("Texture")
			tex.Face = face
			tex.StudsPerTileU = WaterRender.TILE
			tex.StudsPerTileV = WaterRender.TILE
			tex.Color3 = Color3.new(1, 1, 1)
			tex.Texture = WaterRender.TEXTURE
			tex.Parent = part -- STATIC: no OffsetStuds animation (unlike streamed water)
		end
	else
		part.TextureID = TextureAtlas.ENABLED and TextureAtlas.ASSET_ID or ""
	end
	return part
end

export type RebuildStats = { tris: number, verts: number, split: boolean, parts: number, buildMs: number }

-- Build/swap a chunk's render parts from an ALREADY-COLLECTED triangle list -- the pipeline AFTER
-- the cull. Shared by rebuildChunk (cull on the main thread) and the parallel-collect path (cull run
-- in a worker Actor, triangles deserialized via Mesher.deserializeTris). `assetGate`, if given, is
-- called once before EACH main-thread-blocking AssetService op (bake + each CreateMeshPartAsync). --
function Mesher.rebuildFromTris(
	collected: { Tri },
	total: number,
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
	local split = total > TRI_SPLIT_THRESHOLD
	local desired: { [string]: boolean } = {}
	local parts = 0

	if total > 0 and not split then
		-- Fixed transform: centre the part on the full chunk cube and pin its bbox to it.
		local cc = Vector3.new(CHUNK_STUDS / 2, CHUNK_STUDS / 2, CHUNK_STUDS / 2)
		local baked, _, _, center = fillAndBake(collected, yielder, assetGate, cc, cc)
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
			local baked, _, _, center = fillAndBake(buckets[oi], yielder, assetGate, cc, Vector3.new(q, q, q))
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
	}
end

-- Rebuild a chunk's render mesh(es) into `container` with a SINGLE cull pass on the MAIN thread
-- (collect then fill/bake/apply). The parallel-collect path instead runs the cull in a worker Actor
-- and calls rebuildFromTris directly with the deserialized triangles. --
function Mesher.rebuildChunk(
	store: VoxelStore.Store,
	cx: number,
	cy: number,
	cz: number,
	container: Instance,
	yielder: (() -> ())?,
	assetGate: (() -> ())?
): RebuildStats
	local collected, total = collectRange(store, cx, cy, cz, 0, CHUNK - 1, 0, CHUNK - 1, 0, CHUNK - 1, yielder)
	return Mesher.rebuildFromTris(collected, total, cx, cy, cz, container, yielder, assetGate)
end

Mesher.TRI_SPLIT_THRESHOLD = TRI_SPLIT_THRESHOLD

return Mesher
