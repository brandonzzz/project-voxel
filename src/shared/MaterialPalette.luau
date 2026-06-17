--!strict
--[[
	MaterialPalette — material id -> Color3 for v1 rendering (per-face vertex colors,
	no texture). v1.5 will replace this with a procedurally drawn tile atlas
	(EditableImage) baked once; the UV math changes there, the ids here stay.
]]

local Constants = require(script.Parent.Constants)
local M = Constants.Material

local MaterialPalette = {}

-- Indexed by material id. Index 0 (Empty) is unused but present for safety. --
local COLORS: { [number]: Color3 } = {
	[M.Empty] = Color3.fromRGB(0, 0, 0),
	[M.Grass] = Color3.fromRGB(75, 151, 75),
	[M.Sand] = Color3.fromRGB(215, 196, 138),
	[M.Brick] = Color3.fromRGB(151, 75, 60),
	[M.Granite] = Color3.fromRGB(102, 102, 110),
	[M.Asphalt] = Color3.fromRGB(60, 60, 64),
	[M.Iron] = Color3.fromRGB(120, 120, 128),
	[M.Aluminum] = Color3.fromRGB(170, 172, 175),
	[M.Gold] = Color3.fromRGB(220, 180, 60),
	[M.WoodPlank] = Color3.fromRGB(172, 135, 90),
	[M.WoodLog] = Color3.fromRGB(110, 80, 50),
	[M.Gravel] = Color3.fromRGB(120, 120, 115),
	[M.CinderBlock] = Color3.fromRGB(140, 140, 135),
	[M.MossyStone] = Color3.fromRGB(90, 110, 80),
	[M.Cement] = Color3.fromRGB(160, 160, 160),
	[M.RedPlastic] = Color3.fromRGB(196, 40, 40),
	[M.BluePlastic] = Color3.fromRGB(40, 80, 196),
	[M.Water] = Color3.fromRGB(60, 120, 200),
}

local FALLBACK = Color3.fromRGB(255, 0, 255)

function MaterialPalette.color(materialId: number): Color3
	return COLORS[materialId] or FALLBACK
end

return MaterialPalette
