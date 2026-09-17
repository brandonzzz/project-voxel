--!strict
--[[
	WorldGen — seed-based terrain generation (the f(seed) half of the persistence
	model). Surface heights span the full vertical streaming range (clamped 1..MAX_HEIGHT,
	not the old single cy=0 band) so raising GEN.amplitude makes hills that rise past
	cellY=15 into the chunks above; the 3D streaming sphere generates them on demand.

	Generation is parameterised by Constants.GEN (type / period / amplitude /
	flatHeight). Config is read from Constants so the server and all clients agree
	on the deterministic base terrain; pass an override to WorldGen.new only for
	tests. type "void" produces an empty world; "flat" a constant-height plane.

	Column composition (top-down): the surface cell is Grass on land (Sand at/below
	sea level); the cells just beneath the surface are the SAME surface material,
	because the grass atlas texture already paints a dirt band down its sides — so a
	grass column reads as a grass-topped dirt cliff with no separate sub-layer. Deep
	cells are Granite.
]]

local Constants = require(script.Parent.Constants)

local CHUNK = Constants.CHUNK
local M = Constants.Material
local SOLID = Constants.packByte1(Constants.Shape.Solid, 0)
local SEA_LEVEL = 10 -- cells; columns lower than this fill with still water
-- Upper bound for a generated surface column. Generous so GEN.amplitude (not a band cap)
-- governs hill height -- terrain can rise into the vertical chunks above cy=0. Lower bound 1
-- keeps at least one solid floor cell. Default amplitude (~3.5) peaks near 15, so default
-- terrain is unchanged; only larger amplitudes reach higher.
local MAX_HEIGHT = 60

local WorldGen = {}
WorldGen.__index = WorldGen

export type GenConfig = { type: string, period: number, amplitude: number, flatHeight: number }
export type WorldGen = typeof(setmetatable({} :: { seed: number, config: GenConfig }, WorldGen))

local function resolveConfig(override: { [string]: any }?): GenConfig
	local base = Constants.GEN
	local o = override or {}
	return {
		type = o.type or base.type,
		period = o.period or base.period,
		amplitude = o.amplitude or base.amplitude,
		flatHeight = o.flatHeight or base.flatHeight,
	}
end

function WorldGen.new(seed: number?, config: { [string]: any }?): WorldGen
	return setmetatable({ seed = seed or 1337, config = resolveConfig(config) }, WorldGen)
end

function WorldGen.heightAt(self: WorldGen, wx: number, wz: number): number
	local cfg = self.config
	if cfg.type == "flat" then
		return math.clamp(math.floor(cfg.flatHeight), 1, MAX_HEIGHT)
	end
	local s = self.seed * 0.1
	local p = cfg.period
	-- detail octave keeps the original ~0.29 wavelength ratio relative to `period`
	local dp = p * 0.2917
	local broad = math.noise(wx / p + s, wz / p + s * 1.7)
	local detail = math.noise(wx / dp + s * 2.3, wz / dp + s * 0.9) * 0.4
	return math.clamp(math.floor(7 + (broad + detail + 1) * cfg.amplitude), 1, MAX_HEIGHT)
end

-- Fill one chunk's cells from the heightmap. Returns true if anything solid was written. --
function WorldGen.fillChunk(self: WorldGen, store, cx: number, cy: number, cz: number): boolean
	if self.config.type == "void" then
		return false -- empty world: no terrain, no water
	end
	local any = false
	for lx = 0, CHUNK - 1 do
		local wx = cx * CHUNK + lx
		for lz = 0, CHUNK - 1 do
			local wz = cz * CHUNK + lz
			local h = self:heightAt(wx, wz)
			local underwater = h <= SEA_LEVEL
			for ly = 0, CHUNK - 1 do
				local wy = cy * CHUNK + ly
				if wy <= h then
					local mat
					if wy >= h - 2 then
						-- surface + the two cells beneath share the surface material; the
						-- grass atlas already shows dirt on its sides, so no dirt sub-layer.
						mat = underwater and M.Sand or M.Grass
					else
						mat = M.Granite
					end
					store:setCell(wx, wy, wz, mat, SOLID)
					any = true
				elseif wy <= SEA_LEVEL then
					store:setCell(wx, wy, wz, M.Water, 0) -- still water (byte1 = 0 flow)
					any = true
				end
			end
		end
	end
	-- Collapse uniform results (deep bedrock = all granite, etc.) back to a flag-only chunk so the
	-- 3D streaming sphere doesn't carry an 8 KB buffer per off-surface chunk. No-op for genuinely
	-- mixed chunks (the surface band) and for mock stores without the method.
	if store.compactChunk then
		store:compactChunk(cx, cy, cz)
	end
	return any
end

return WorldGen
