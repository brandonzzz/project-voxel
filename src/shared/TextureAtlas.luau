--!strict
--[[
	TextureAtlas — UV-rect math for the textured render mode (P4).

	One 1024x1024 atlas, 16 material spaces of 256px (reading order: col=i%4,
	row=floor(i/4), i=material-1). Within each material space, 4 regions:
	  TOP    origin (8,8)    size 160x160  40px/voxel -> 4-voxel tiling period
	  SIDE   origin (184,8)  size 64x160   32px/voxel -> 2 wide; top 32px strip is
	         the grass-fringe variant (used when the voxel's top face is exposed)
	  SLOPE  origin (8,184)  size 160x64   32px/voxel; left 32px strip is the
	         ramp-crest variant (used when the slope does not continue upward)
	  BOTTOM origin (184,184) size 64x64   32px/voxel -> 2x2 tiling period
	8px gutters; UVs are inset by half a texel so mips don't bleed.

	faceRect() returns the normalised inset sub-tile rect (u0,v0,u1,v1) for a face;
	the mesher lerps each vertex's in-plane (0..1) coords inside it. The mod
	arithmetic per region is the calibration knob (PHASE), tuned visually.
]]

local TextureAtlas = {}

TextureAtlas.ENABLED = true
TextureAtlas.ASSET_ID = "rbxassetid://139235247401983"
-- Extra half-turn on slope UVs: the base mapping anchors to the horizontal (XZ)
-- edge but runs bottom-up; rot 2 flips it to run top-down (user-confirmed).
TextureAtlas.SLOPE_ROT = 2

local ATLAS = 1024
-- Intra-region sub-tiles abut, so a per-tile inset would leave a 1-texel gap and a
-- faint seam on every voxel edge. Inset 0 keeps adjacent voxel UVs contiguous; the
-- 8px region/material gutters prevent cross-region mip bleed.
local HALF = 0
local MAT = 256

-- region: origin px (within a material space) + size + voxel px size
local REGION = {
	TOP = { ox = 8, oy = 8, w = 160, h = 160, vox = 40 },
	SIDE = { ox = 184, oy = 8, w = 64, h = 160, vox = 32 },
	SLOPE = { ox = 8, oy = 184, w = 160, h = 64, vox = 32 },
	BOTTOM = { ox = 184, oy = 184, w = 64, h = 64, vox = 32 },
}
TextureAtlas.REGION = REGION

-- Calibration knobs (visual): per-region tile-phase offsets (integer cell phase).
TextureAtlas.PHASE = {
	topX = 0,
	topZ = 0,
	sideH = 0,
	sideV = 0,
	botX = 0,
	botZ = 0,
	slopeA = 0,
	slopeB = 0,
}

local function matBase(material: number): (number, number)
	local i = material - 1
	return (i % 4) * MAT, math.floor(i / 4) * MAT
end

-- floor-mod (handles negative cell coords)
local function fmod(a: number, n: number): number
	return ((a % n) + n) % n
end

-- normalised inset rect from a material-space pixel box
local function rect(bx: number, by: number, x0: number, y0: number, size: number): (number, number, number, number)
	return (bx + x0) / ATLAS + HALF, (by + y0) / ATLAS + HALF, (bx + x0 + size) / ATLAS - HALF, (by + y0 + size) / ATLAS - HALF
end

-- faceType: "TOP" | "BOTTOM" | "SIDE" | "SLOPE". Returns (u0,v0,u1,v1) normalised. --
function TextureAtlas.faceRect(
	faceType: string,
	material: number,
	cwx: number,
	cwy: number,
	cwz: number,
	topExposed: boolean,
	slopeCrest: boolean,
	slopeAcross: number?
): (number, number, number, number)
	local bx, by = matBase(material)
	local P = TextureAtlas.PHASE

	if faceType == "TOP" then
		local r = REGION.TOP
		local x0 = r.ox + fmod(cwx + P.topX, 4) * r.vox
		local y0 = r.oy + fmod(cwz + P.topZ, 4) * r.vox
		return rect(bx, by, x0, y0, r.vox)
	elseif faceType == "BOTTOM" then
		local r = REGION.BOTTOM
		local x0 = r.ox + fmod(cwx + P.botX, 2) * r.vox
		local y0 = r.oy + fmod(cwz + P.botZ, 2) * r.vox
		return rect(bx, by, x0, y0, r.vox)
	elseif faceType == "SIDE" then
		local r = REGION.SIDE
		local x0 = r.ox + fmod(cwx + cwz + P.sideH, 2) * r.vox
		local y0
		if topExposed then
			y0 = r.oy -- top strip = grass fringe
		else
			-- body rows below the fringe; row index DECREASES with height so it stays
			-- contiguous with the within-voxel V (1 - icy) -> seamless vertical tiling
			y0 = r.oy + r.vox + fmod(P.sideV - cwy, 4) * r.vox
		end
		return rect(bx, by, x0, y0, r.vox)
	else -- SLOPE
		local r = REGION.SLOPE
		-- Slope region is authored 90deg CCW, so both axes tile by world cell position:
		--   across-width -> atlas-up (y), down-slope -> atlas-right (x). Column 0 is the
		--   top-of-slope (crest) texture; BODY cells never sample it, so body tiles live in
		--   columns 1..4 and advance down-slope by height.
		-- across phase MUST be the cell coord along the slope's WIDTH axis only (passed in
		-- as slopeAcross): a slope spans the downhill axis as it rises, so mixing both
		-- horizontal coords (cwx+cwz) would shift the across texture one voxel per row.
		local across = slopeAcross or (cwx + cwz)
		local y0 = r.oy + fmod(across + P.slopeA, 2) * r.vox -- across-width -> atlas up
		local x0
		if slopeCrest then
			x0 = r.ox -- column 0 = crest (top of slope) only
		else
			-- body cols 1..4 advance down-slope by height (negated, like SIDE's vertical
			-- rows) so the down-slope strip is contiguous and tiles seamlessly
			x0 = r.ox + r.vox + fmod(P.slopeB - cwy, 4) * r.vox
		end
		return rect(bx, by, x0, y0, r.vox)
	end
end

return TextureAtlas
