--!strict
--[[
	WaterRender — v1 legacy water.

	Greedy-merges contiguous water cells (plus render-time "waterlogged" shoreline
	slope cells) into Parts. Two looks, selected by TEXTURE_ENABLED:
	  enabled  -> OPAQUE part, Material = Fabric, a scrolling Texture on the top face
	              (the asset tiles over a 4x4-voxel space; OffsetStuds animated).
	  fallback -> the original transparent, glass-material look (no texture).
	Water is NON-collidable (you swim through it); the Mesher and Collision both
	ignore water cells, so this is the only water system.

	SHORELINE WATERLOGGING (render-time only; never written to the voxel data, so
	water never overlaps another voxel). Water visually laps onto adjacent SLOPE
	cells (wedge / corner / inverse-corner) via an orthogonal flood fill from water:
	  - candidates are orthogonal XZ neighbours in the y=0 and y=-1 planes,
	  - a slope is only flooded if its face toward the water is NOT fully covered
	    (a covered/culled face = a solid wall = no gap = no flow),
	  - diagonals are reached only THROUGH an orthogonal slope bridge (the fill steps
	    orthogonally), and a doubly-diagonal / lower cell needs two bridging slopes —
	    both fall out of the orthogonal BFS for free.
]]

local RunService = game:GetService("RunService")

local Constants = require(script.Parent.Constants)
local Collision = require(script.Parent.Collision)
local Shape = require(script.Parent.Shape)

local CELL = Constants.CELL
local CHUNK = Constants.CHUNK
local WATER = Constants.Material.Water
local SHAPE = Constants.Shape
local unpackByte1 = Constants.unpackByte1
local unpackCell = Constants.unpackCell

local WaterRender = {}

WaterRender.COLOR = Color3.fromRGB(40, 90, 170)
WaterRender.TRANSPARENCY = 0.55 -- fallback (glass) transparency
WaterRender.SCROLL_SPEED = 1.5 -- studs/sec
WaterRender.TILE = CELL * 4 -- the scroll texture covers a 4x4-voxel space (16 studs)
-- Per-face offset magnitude (see rebuildChunk): faces vs terrain pull IN (terrain wins,
-- no z-fight); faces vs water within a chunk push OUT to overlap (cover concave-boundary
-- gaps) while chunk-border water faces abut exactly (no overlap grid).
WaterRender.FACE_INSET = 0.02
WaterRender.BRICKCOLOR = "Steel blue"
-- Opaque scrolling water vs. the transparent glass fallback. Setting TEXTURE to ""
-- (or ENABLED=false) reverts to the legacy glass look.
WaterRender.TEXTURE_ENABLED = true
WaterRender.TEXTURE = "rbxassetid://91991105419794"

-- Per-chunk RENDERED-water mask (actual water + waterlogged shoreline slopes), keyed by
-- chunk folder name. Lets swimming be triggered from rendered water (incl. waterlogged
-- slopes) via a data lookup -- no part collision query. Kept in sync by rebuild/remove.
WaterRender._rendered = {} :: { [string]: { boolean } }

-- Per-chunk flat list of scrollable textures with their PRECOMPUTED world-grid base offset
-- (faceAlign is static between rebuilds). The scroll loop just adds the animated offset --
-- no per-frame tree walk or faceAlign recompute. Keyed by chunk folder name.
WaterRender._scroll = {} :: { [string]: { { tex: Texture, bu: number, bv: number, vY: boolean } } }

-- Shoreline flood reach: how far (cells) waterlogging may spread from water in XZ,
-- and how far it may descend. Slopes only exist at shores, so this stays local.
local BORDER = 4
local VDOWN = 4

local SLOPE_SHAPE = {
	[SHAPE.VerticalWedge] = true,
	[SHAPE.CornerWedge] = true,
	[SHAPE.InverseCornerWedge] = true,
	[SHAPE.HorizontalWedge] = true,
}

local DIRS = {
	{ dx = 1, dz = 0 },
	{ dx = -1, dz = 0 },
	{ dx = 0, dz = 1 },
	{ dx = 0, dz = -1 },
}
-- direction (dx,dz) from a watered cell toward neighbour N -> N's Shape.FACES index
-- that faces back at the water (1=+X,2=-X,3=+Y,4=-Y,5=+Z,6=-Z).
local FACE_TOWARD = {
	["1_0"] = 2,
	["-1_0"] = 1,
	["0_1"] = 6,
	["0_-1"] = 5,
}

local function lidx(lx: number, ly: number, lz: number): number
	return lx + lz * CHUNK + ly * (CHUNK * CHUNK) + 1
end

local function waterMask(store, cx: number, cy: number, cz: number): { boolean }
	local read = store:makeChunkReader(cx, cy, cz)
	local mask = table.create(CHUNK * CHUNK * CHUNK, false)
	for ly = 0, CHUNK - 1 do
		for lz = 0, CHUNK - 1 do
			for lx = 0, CHUNK - 1 do
				local raw = read(lx, ly, lz)
				if raw ~= 0 and unpackCell(raw) == WATER then
					mask[lidx(lx, ly, lz)] = true
				end
			end
		end
	end
	return mask
end

-- Is cell N a slope whose face toward the water (direction dx,dz from water to N)
-- leaves a gap? A fully covered face is a wall the water cannot flow past. --
local function slopeOpenToward(sample, nx: number, ny: number, nz: number, dx: number, dz: number): boolean
	local raw = sample(nx, ny, nz)
	if raw == 0 then
		return false
	end
	local mat, byte1 = unpackCell(raw)
	if mat == WATER then
		return false
	end
	local shape, storedO = unpackByte1(byte1)
	if not SLOPE_SHAPE[shape] then
		return false
	end
	local geomO = Shape.geomOrientation(shape, storedO)
	local fidx = FACE_TOWARD[dx .. "_" .. dz]
	return Shape.faceCoverage(shape, geomO, fidx) ~= "F"
end

-- Is there an ACTUAL water cell within (x,y,z)'s 1-cell neighbourhood? A slope is only
-- waterlogged if real water laps right against it -- this stops the flood from walking
-- slope->slope along a connected chain (e.g. a crater rim) into cells with no water nearby,
-- while still allowing single-bridge diagonal shorelines (their water is 1 cell away). --
local function waterNearby(sample, x: number, y: number, z: number): boolean
	for ax = -1, 1 do
		for ay = -1, 1 do
			for az = -1, 1 do
				if (ax ~= 0 or ay ~= 0 or az ~= 0) and unpackCell(sample(x + ax, y + ay, z + az)) == WATER then
					return true
				end
			end
		end
	end
	return false
end

-- Flood water onto shoreline slope cells; returns a set of LOCAL chunk indices to
-- add to the render mask. Reads the global store (crosses chunk borders). --
local function waterlogMask(store, cx: number, cy: number, cz: number): { [number]: boolean }
	local result: { [number]: boolean } = {}

	-- exploration bounds (world cells): the chunk grown by BORDER in XZ, VDOWN down.
	local minX, maxX = cx * CHUNK - BORDER, cx * CHUNK + CHUNK - 1 + BORDER
	local minZ, maxZ = cz * CHUNK - BORDER, cz * CHUNK + CHUNK - 1 + BORDER
	local minY, maxY = cy * CHUNK - VDOWN, cy * CHUNK + CHUNK - 1

	local visited: { [string]: boolean } = {}
	local queue: { { number } } = {}
	local qn = 0
	local function vkey(x: number, y: number, z: number): string
		return x .. "_" .. y .. "_" .. z
	end

	-- Pre-resolve the 3x3x3 neighbour chunks once. The flood stays within +-BORDER (XZ) / -VDOWN (Y)
	-- of the chunk -- well inside one neighbour (<= 16) -- so a chunk-relative neighbour sampler can
	-- replace per-cell getCell (no worldToChunk / string chunkKey / table lookup per call). `sample`
	-- takes WORLD cell coords and returns the raw 16-bit value (0 outside / absent), like getCell.
	local sampler = store:makeNeighborSampler(cx, cy, cz)
	local ox, oy, oz = cx * CHUNK, cy * CHUNK, cz * CHUNK
	local function sample(wx: number, wy: number, wz: number): number
		return sampler(wx - ox, wy - oy, wz - oz)
	end

	-- seed: water cells in the chunk + a one-cell shell (enough to catch water lapping
	-- in from neighbours; the fill then runs inward onto slopes).
	local sx0, sx1 = cx * CHUNK - 1, cx * CHUNK + CHUNK
	local sy0, sy1 = math.max(minY, cy * CHUNK - 1), cy * CHUNK + CHUNK
	local sz0, sz1 = cz * CHUNK - 1, cz * CHUNK + CHUNK
	for wy = sy0, sy1 do
		for wz = sz0, sz1 do
			for wx = sx0, sx1 do
				if unpackCell(sample(wx, wy, wz)) == WATER then
					local k = vkey(wx, wy, wz)
					if not visited[k] then
						visited[k] = true
						qn += 1
						queue[qn] = { wx, wy, wz }
					end
				end
			end
		end
	end

	local head = 1
	while head <= qn do
		local c = queue[head]
		head += 1
		local cw, ch, cd = c[1], c[2], c[3]
		for _, d in DIRS do
			for _, dy in { 0, -1 } do
				local nx, ny, nz = cw + d.dx, ch + dy, cd + d.dz
				if nx >= minX and nx <= maxX and nz >= minZ and nz <= maxZ and ny >= minY and ny <= maxY then
					local k = vkey(nx, ny, nz)
					if not visited[k] and slopeOpenToward(sample, nx, ny, nz, d.dx, d.dz) then
						local ok = true
						if dy == -1 then
							-- to spill down onto N, the cell directly above it must not be a
							-- full solid cube (that would wall the water off above N).
							local am, ab = unpackCell(sample(nx, ny + 1, nz))
							if am ~= 0 and am ~= WATER and unpackByte1(ab) == SHAPE.Solid then
								ok = false
							end
						end
						-- ...and only if real water actually laps against this cell, so the flood
						-- can't chain slope->slope into water-less cells (the crater-rim bug).
						if ok and waterNearby(sample, nx, ny, nz) then
							visited[k] = true
							qn += 1
							queue[qn] = { nx, ny, nz }
							local lx, ly, lz = nx - cx * CHUNK, ny - cy * CHUNK, nz - cz * CHUNK
							if lx >= 0 and lx < CHUNK and ly >= 0 and ly < CHUNK and lz >= 0 and lz < CHUNK then
								result[lidx(lx, ly, lz)] = true
							end
						end
					end
				end
			end
		end
	end
	return result
end

WaterRender._waterlogMask = waterlogMask -- exposed for tests/diagnostics

-- The engine anchors a face's Texture at one corner (size-independent), and that corner
-- differs per face (user-mapped). U/V map to two world axes; uMax/vMax say whether the
-- anchor sits at that axis's max or min. vY marks faces whose V is vertical (Y) so they
-- don't scroll vertically.
--   +Y Top:+X+Z  -Y Bottom:-X+Z  -Z Front:+X+Y  +Z Back:-X+Y  -X Left:-Z+Y  +X Right:+Z+Y
local FACE_DEFS = {
	{ id = Enum.NormalId.Top, ua = "X", uMax = true, va = "Z", vMax = true, vY = false },
	{ id = Enum.NormalId.Bottom, ua = "X", uMax = false, va = "Z", vMax = true, vY = false },
	{ id = Enum.NormalId.Front, ua = "X", uMax = true, va = "Y", vMax = true, vY = true },
	{ id = Enum.NormalId.Back, ua = "X", uMax = false, va = "Y", vMax = true, vY = true },
	{ id = Enum.NormalId.Left, ua = "Z", uMax = false, va = "Y", vMax = true, vY = true },
	{ id = Enum.NormalId.Right, ua = "Z", uMax = true, va = "Y", vMax = true, vY = true },
}
local FACE_BY_ID: { [Enum.NormalId]: any } = {}
for _, d in FACE_DEFS do
	FACE_BY_ID[d.id] = d
end

-- World-grid base offset for a face's texture: -(anchor corner's world coord on each of
-- the face's two axes), so every part's texture lands on the same world grid. --
local function faceAlign(part: BasePart, def): (number, number)
	local pos, sz = part.Position, part.Size
	local function axisVal(axis: string, useMax: boolean): number
		if axis == "X" then
			return useMax and (pos.X + sz.X / 2) or (pos.X - sz.X / 2)
		elseif axis == "Y" then
			return useMax and (pos.Y + sz.Y / 2) or (pos.Y - sz.Y / 2)
		else
			return useMax and (pos.Z + sz.Z / 2) or (pos.Z - sz.Z / 2)
		end
	end
	return -axisVal(def.ua, def.uMax), -axisVal(def.va, def.vMax)
end

local function waterPart(): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Color = WaterRender.COLOR
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if WaterRender.TEXTURE_ENABLED and WaterRender.TEXTURE ~= "" then
		-- opaque legacy water: SmoothPlastic + Steel blue, with the scrolling surface texture
		p.Material = Enum.Material.SmoothPlastic
		p.BrickColor = BrickColor.new(WaterRender.BRICKCOLOR)
		p.Transparency = 0
		p.Reflectance = 0
		for _, def in FACE_DEFS do
			local tex = Instance.new("Texture")
			tex.Name = "WS"
			tex.Face = def.id
			tex.StudsPerTileU = WaterRender.TILE
			tex.StudsPerTileV = WaterRender.TILE
			tex.Transparency = 0
			tex.Color3 = Color3.new(1, 1, 1)
			tex.Texture = WaterRender.TEXTURE
			tex.Parent = p
		end
	else
		-- fallback: original transparent glass look
		p.Material = Enum.Material.Glass
		p.Transparency = WaterRender.TRANSPARENCY
		p.Reflectance = 0.1
	end
	return p
end

local function folderName(cx: number, cy: number, cz: number): string
	return string.format("Water_%d_%d_%d", cx, cy, cz)
end

-- Across face `dir` of box `b`, classify the neighbouring cells, returning
-- (allWater, anyWater). A cell counts as water if it is an actual water cell OR a
-- render-time waterlogged slope (in mask) -- otherwise two adjacent waterlog parts
-- (slopes in the store) would read as terrain and gap.
local function faceWaterState(store, cx: number, cy: number, cz: number, b, dir: string, mask: { boolean }): (boolean, boolean)
	local function isW(lx: number, ly: number, lz: number): boolean
		if lx >= 0 and lx < CHUNK and ly >= 0 and ly < CHUNK and lz >= 0 and lz < CHUNK then
			return mask[lidx(lx, ly, lz)] == true
		end
		local m, byte1 = store:getCell(cx * CHUNK + lx, cy * CHUNK + ly, cz * CHUNK + lz)
		if m == WATER then
			return true
		end
		return m ~= 0 and unpackByte1(byte1) ~= SHAPE.Solid
	end
	local all, any = true, false
	local function tally(w: boolean)
		if w then any = true else all = false end
	end
	if dir == "+x" then
		for ly = b.y0, b.y1 do for lz = b.z0, b.z1 do tally(isW(b.x1 + 1, ly, lz)) end end
	elseif dir == "-x" then
		for ly = b.y0, b.y1 do for lz = b.z0, b.z1 do tally(isW(b.x0 - 1, ly, lz)) end end
	elseif dir == "+y" then
		for lx = b.x0, b.x1 do for lz = b.z0, b.z1 do tally(isW(lx, b.y1 + 1, lz)) end end
	elseif dir == "-y" then
		for lx = b.x0, b.x1 do for lz = b.z0, b.z1 do tally(isW(lx, b.y0 - 1, lz)) end end
	elseif dir == "+z" then
		for lx = b.x0, b.x1 do for ly = b.y0, b.y1 do tally(isW(lx, ly, b.z1 + 1)) end end
	else
		for lx = b.x0, b.x1 do for ly = b.y0, b.y1 do tally(isW(lx, ly, b.z0 - 1)) end end
	end
	return all, any
end

function WaterRender.rebuildChunk(store, cx: number, cy: number, cz: number, container: Instance): number
	local name = folderName(cx, cy, cz)
	local old = container:FindFirstChild(name)
	local folder = Instance.new("Folder")
	folder.Name = name

	local mask = waterMask(store, cx, cy, cz)
	-- waterlogged shoreline slopes render as water cubes too (render-time only)
	for idx in waterlogMask(store, cx, cy, cz) do
		mask[idx] = true
	end
	WaterRender._rendered[name] = mask -- expose the exact rendered-water set for swim checks

	local boxes = Collision.greedyBoxes(mask)
	local INSET = WaterRender.FACE_INSET
	local scrollEntries = {}
	for _, b in boxes do
		local part = waterPart()
		local w = (b.x1 - b.x0 + 1) * CELL
		local h = (b.y1 - b.y0 + 1) * CELL
		local d = (b.z1 - b.z0 + 1) * CELL
		local cornerX = (cx * CHUNK + b.x0) * CELL
		local cornerY = (cy * CHUNK + b.y0) * CELL
		local cornerZ = (cz * CHUNK + b.z0) * CELL
		-- per-face offset (three-way) -- kills gaps AND overlaps:
		--   fully water-facing  -> ABUT (0): the neighbour water/waterlog part meets
		--     here exactly, so there is neither a gap nor a double-alpha overlap.
		--   partially water-facing (a mixed shoreline the greedy box could not split)
		--     -> EXPAND OUT by INSET so the water covers the seam; the only cost is a
		--     thin, acceptable overlap along irregular shorelines.
		--   no water across (terrain/air) -> pull IN by INSET so terrain wins (no z-fight).
		local function o(dir: string): number
			local allW, anyW = faceWaterState(store, cx, cy, cz, b, dir, mask)
			if allW then return 0 end
			if anyW then return INSET end
			return -INSET
		end
		local opx, onx = o("+x"), o("-x")
		local opy, ony = o("+y"), o("-y")
		local opz, onz = o("+z"), o("-z")
		part.Size = Vector3.new(w + opx + onx, h + opy + ony, d + opz + onz)
		part.Position = Vector3.new(
			cornerX + w / 2 + (opx - onx) / 2,
			cornerY + h / 2 + (opy - ony) / 2,
			cornerZ + d / 2 + (opz - onz) / 2
		)
		part.Parent = folder
		-- precompute each texture's static world-grid base offset for the scroll loop
		for _, tex in part:GetChildren() do
			if tex:IsA("Texture") then
				local def = FACE_BY_ID[tex.Face]
				if def then
					local au, av = faceAlign(part, def)
					scrollEntries[#scrollEntries + 1] = { tex = tex, bu = au, bv = av, vY = def.vY }
				end
			end
		end
	end
	WaterRender._scroll[name] = scrollEntries

	folder.Parent = container
	if old then
		old:Destroy()
	end
	return #boxes
end

function WaterRender.removeChunk(cx: number, cy: number, cz: number, container: Instance)
	local name = folderName(cx, cy, cz)
	WaterRender._rendered[name] = nil
	WaterRender._scroll[name] = nil
	local f = container:FindFirstChild(name)
	if f then
		f:Destroy()
	end
end

-- Is world cell (wx,wy,wz) currently RENDERED as water -- actual water OR a waterlogged
-- shoreline slope? Reads the cached render mask only (data-driven; no part collision). --
function WaterRender.isRenderedWater(wx: number, wy: number, wz: number): boolean
	local cx = math.floor(wx / CHUNK)
	local cy = math.floor(wy / CHUNK)
	local cz = math.floor(wz / CHUNK)
	local chunk = WaterRender._rendered[folderName(cx, cy, cz)]
	if not chunk then
		return false
	end
	return chunk[lidx(wx - cx * CHUNK, wy - cy * CHUNK, wz - cz * CHUNK)] == true
end

-- Animate the legacy scroll on all water textures. Iterates the precomputed flat list
-- (_scroll); each entry already holds its static world-grid base offset, so the per-frame
-- work is just two OffsetStuds writes. Vertical (Y) faces don't scroll along V (water
-- doesn't visibly flow up a wall). `container` is unused now (kept for call-site compat). --
function WaterRender.startScroll(_container: Instance?)
	if WaterRender._conn then
		return
	end
	local off = 0
	-- U advances 2 tiles and V advances 1 tile over PERIOD; both are whole multiples of
	-- TILE, so the loop wraps with no visible jump (the earlier 0.6 ratio never realigned).
	local PERIOD = WaterRender.TILE * 2
	WaterRender._conn = RunService.Heartbeat:Connect(function(dt)
		off = (off + dt * WaterRender.SCROLL_SPEED) % PERIOD
		local voff = off * 0.5
		for _, entries in WaterRender._scroll do
			for _, e in entries do
				e.tex.OffsetStudsU = e.bu + off
				e.tex.OffsetStudsV = e.bv + (e.vY and 0 or voff)
			end
		end
	end)
end

function WaterRender.stopScroll()
	if WaterRender._conn then
		WaterRender._conn:Disconnect()
		WaterRender._conn = nil
	end
end

return WaterRender
