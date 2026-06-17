--!strict
--[[
	ShapeDemo — M2 visual confirmation (diagnostic, not part of the runtime pipeline).

	Builds every shape x orientation in a labeled 5x4 grid under
	Workspace/LegacyVoxelTerrain/ShapeDemo so wedge orientations can be eyeballed
	against legacy reference imagery. Idempotent: re-running clears and recreates.

	Slope (non-axis) faces are coloured orange; axis faces light grey. Parts are
	single-sided, so a winding error would appear as a visible hole.

	Columns (+X):  Solid, VerticalWedge, CornerWedge, InverseCornerWedge, HorizontalWedge
	Rows (+Z):     orientation 0,1,2,3  (= NegZ, X, Z, NegX)
]]

local AssetService = game:GetService("AssetService")
local Workspace = game:GetService("Workspace")

local Lib = script.Parent.Parent
local Constants = require(Lib.Constants)
local Shape = require(Lib.Shape)

local GAP = 8
local BASE_Y = 4

local CODE = {
	[Constants.Shape.Solid] = "S",
	[Constants.Shape.VerticalWedge] = "VW",
	[Constants.Shape.CornerWedge] = "CW",
	[Constants.Shape.InverseCornerWedge] = "ICW",
	[Constants.Shape.HorizontalWedge] = "HW",
}

local GRAY = Color3.fromRGB(205, 205, 205)
local ORANGE = Color3.fromRGB(255, 140, 30)

local ShapeDemo = {}

local function buildShapeMesh(shapeId: number, o: number): MeshPart
	local em = AssetService:CreateEditableMesh()
	local grayC = em:AddColor(GRAY, 1)
	local slopeC = em:AddColor(ORANGE, 1)
	local uv = em:AddUV(Vector2.new(0, 0))
	for _, t in Shape.hullTriangles(shapeId, o) do
		local v1 = em:AddVertex(t.a)
		local v2 = em:AddVertex(t.b)
		local v3 = em:AddVertex(t.c)
		local fid = em:AddTriangle(v1, v2, v3)
		local nid = em:AddNormal()
		em:SetFaceNormals(fid, { nid, nid, nid })
		local c = t.isSlope and slopeC or grayC
		em:SetFaceColors(fid, { c, c, c })
		em:SetFaceUVs(fid, { uv, uv, uv })
	end
	-- BAKE: CreateMeshPartAsync(Content.fromObject(em)) only keeps a LIVE reference
	-- to the editable mesh; destroying the editable would blank the part. Bake to
	-- immutable DataModel content first, which also releases the editable budget.
	local result, baked = AssetService:CreateDataModelContentAsync(Content.fromObject(em))
	if result ~= Enum.CreateContentResult.Success then
		em:Destroy()
		error("CreateDataModelContentAsync failed: " .. tostring(result))
	end
	local part = AssetService:CreateMeshPartAsync(baked, { CollisionFidelity = Enum.CollisionFidelity.Box })
	em:Destroy()
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.DoubleSided = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = Color3.new(1, 1, 1)
	return part
end

local function label(parent: Instance, text: string, offsetY: number)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.new(0, 80, 0, 22)
	bb.StudsOffset = Vector3.new(0, offsetY, 0)
	bb.AlwaysOnTop = true
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.fromScale(1, 1)
	tl.BackgroundTransparency = 1
	tl.Text = text
	tl.TextColor3 = Color3.new(1, 1, 1)
	tl.TextStrokeTransparency = 0
	tl.TextScaled = true
	tl.Font = Enum.Font.SourceSansBold
	tl.Parent = bb
	bb.Parent = parent
end

local function axisMarker(parent: Instance, size: Vector3, pos: Vector3, color: Color3, text: string)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.Size = size
	p.Position = pos
	p.Color = color
	p.Material = Enum.Material.Neon
	p.Parent = parent
	label(p, text, 1)
end

function ShapeDemo.build(): number
	local root = Workspace:FindFirstChild("LegacyVoxelTerrain")
	if not root then
		root = Instance.new("Folder")
		root.Name = "LegacyVoxelTerrain"
		root.Parent = Workspace
	end
	local stale = root:FindFirstChild("__probe")
	if stale then
		stale:Destroy()
	end
	local existing = root:FindFirstChild("ShapeDemo")
	if existing then
		existing:Destroy()
	end
	local demo = Instance.new("Folder")
	demo.Name = "ShapeDemo"
	demo.Parent = root

	local count = 0
	for si, shapeId in Shape.SHAPES do
		for o = 0, 3 do
			-- Labels show the STORED orientation; geometry uses the remapped one so
			-- the demo reflects exactly what the runtime will render per stored bits.
			local part = buildShapeMesh(shapeId, Shape.geomOrientation(shapeId, o))
			part.Name = string.format("%s_o%d", CODE[shapeId], o)
			part.Position = Vector3.new((si - 1) * GAP, BASE_Y, o * GAP)
			label(part, string.format("%s o%d", CODE[shapeId], o), 3.5)
			part.Parent = demo
			count += 1
		end
	end

	-- World-axis reference gizmo at the grid's near-left corner.
	local origin = Vector3.new(-GAP, BASE_Y, -GAP)
	axisMarker(demo, Vector3.new(8, 0.4, 0.4), origin + Vector3.new(4, 0, 0), Color3.fromRGB(255, 60, 60), "+X")
	axisMarker(demo, Vector3.new(0.4, 0.4, 8), origin + Vector3.new(0, 0, 4), Color3.fromRGB(70, 120, 255), "+Z")
	axisMarker(demo, Vector3.new(0.4, 8, 0.4), origin + Vector3.new(0, 4, 0), Color3.fromRGB(70, 220, 90), "+Y")

	return count
end

return ShapeDemo
