--!strict
--[[
	TerrainDemo — M3 visual confirmation (diagnostic). Generates a small heightmap
	terrain and renders it through the real Mesher across several chunks, so chunk
	borders (no seams) and per-material vertex colours can be eyeballed. Idempotent.
]]

local Workspace = game:GetService("Workspace")

local Lib = script.Parent.Parent
local Constants = require(Lib.Constants)
local VoxelStore = require(Lib.VoxelStore)
local Mesher = require(Lib.Mesher)

local CHUNK = Constants.CHUNK
local M = Constants.Material
local SOLID = Constants.packByte1(Constants.Shape.Solid, 0)

local TerrainDemo = {}

local function generate(store, nx: number, nz: number)
	local sizeX, sizeZ = nx * CHUNK, nz * CHUNK
	for wx = 0, sizeX - 1 do
		for wz = 0, sizeZ - 1 do
			local n = math.noise(wx / 20, wz / 20, 4.5) -- -1..1
			local h = math.floor(6 + (n + 1) * 3.5) -- ~6..13
			for wy = 0, h do
				local mat
				if wy == h then
					mat = (h <= 6) and M.Sand or M.Grass
				elseif wy >= h - 2 then
					mat = M.Gravel
				else
					mat = M.Granite
				end
				store:setCell(wx, wy, wz, mat, SOLID)
			end
		end
	end
end

-- Returns the render container and aggregate stats. --
function TerrainDemo.build(nx: number?, nz: number?): (Instance, number, number)
	nx = nx or 3
	nz = nz or 3
	local store = VoxelStore.new()
	generate(store, nx :: number, nz :: number)

	local root = Workspace:FindFirstChild("LegacyVoxelTerrain")
	if not root then
		root = Instance.new("Folder")
		root.Name = "LegacyVoxelTerrain"
		root.Parent = Workspace
	end
	local render = root:FindFirstChild("Render")
	if render then
		render:Destroy()
	end
	render = Instance.new("Folder")
	render.Name = "Render"
	render.Parent = root

	local totalTris, maxMs = 0, 0
	for cx = 0, (nx :: number) - 1 do
		for cz = 0, (nz :: number) - 1 do
			local stats = Mesher.rebuildChunk(store, cx, 0, cz, render)
			totalTris += stats.tris
			if stats.buildMs > maxMs then
				maxMs = stats.buildMs
			end
		end
	end
	return render, totalTris, maxMs
end

return TerrainDemo
