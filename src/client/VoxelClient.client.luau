--!strict
--[[
	VoxelClient — runtime entry point (StarterPlayerScripts). Builds the client
	store + generator + ChunkManager and streams terrain around the camera.

	Streams render + collision + water around the camera, applies edit deltas, and
	hosts the place/remove/explode tool. Exposes the manager at _G.VoxelChunkManager.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Lib = ReplicatedStorage:WaitForChild("LegacyVoxelTerrain")
local VoxelStore = require(Lib:WaitForChild("VoxelStore"))
local WorldGen = require(Lib:WaitForChild("WorldGen"))
local ChunkManager = require(Lib:WaitForChild("ChunkManager"))
local Collision = require(Lib:WaitForChild("Collision"))
local EditService = require(Lib:WaitForChild("EditService"))
local Constants = require(Lib:WaitForChild("Constants"))
local WaterRender = require(Lib:WaitForChild("WaterRender"))
local WaterPhysics = require(Lib:WaitForChild("WaterPhysics"))
local CollectPool = require(Lib:WaitForChild("CollectPool"))

local player = Players.LocalPlayer

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

local collision = root:FindFirstChild("Collision")
if collision then
	collision:Destroy()
end
collision = Instance.new("Folder")
collision.Name = "Collision"
collision.Parent = root

local water = root:FindFirstChild("Water")
if water then
	water:Destroy()
end
water = Instance.new("Folder")
water.Name = "Water"
water.Parent = root

local store = VoxelStore.new()
local gen = WorldGen.new(Constants.WORLD_SEED)

local camera = Workspace.CurrentCamera

-- Parallel-collect worker pool: offloads the render cull (~21 ms/chunk) off the main thread. Created
-- before the manager so it can be handed in. Yields ~20 ms once while the worker Actors bind.
local collectPool = nil
if Constants.PARALLEL_COLLECT then
	collectPool = CollectPool.new(Constants.COLLECT_WORKERS, player:WaitForChild("PlayerScripts"))
end

local manager -- forward-declared so onBuilt can pace its collision+water rebuild via the manager
manager = ChunkManager.new({
	store = store,
	gen = gen,
	container = render,
	-- Stream around the CHARACTER (not the camera) so client and server load the same
	-- chunks for the same player -- a prerequisite for artifact-free loose-part streaming.
	-- Falls back to the camera before the character first spawns.
	focusFn = function()
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			return hrp.Position
		end
		local cam = Workspace.CurrentCamera
		return cam and cam.CFrame.Position or Vector3.zero
	end,
	-- The heavy per-chunk ops (the two AssetService calls + the collision+water rebuild) each block
	-- the main thread and can't be parallelized (AssetService is main-thread-only) or time-sliced.
	-- maxConcurrent=1 keeps one chunk's work from stacking with another's; ChunkManager then paces
	-- the heavy ops with a DISTANCE-ADAPTIVE credit bucket -- near chunks build fast (accept a brief
	-- fps dip so they catch up when you move fast), far chunks build < 1 op/frame (idle frames stay
	-- 60fps). Live-tunable via cfgMaxConcurrent / cfgNearOpsPerFrame / cfgFarOpsPerFrame.
	radius = 6,
	frameBudgetMs = 3,
	maxConcurrent = 1,
	cy = 0,
	collectPool = collectPool,
	onBuilt = function(cx, cy, cz)
		-- Pace the collision+water rebuild onto its own gated frame so it doesn't pile onto the
		-- frame that just ran the render bake/CreateMeshPartAsync (that stacking was the stutter).
		manager:waitAssetSlot()
		Collision.rebuildChunk(store, cx, cy, cz, collision)
		WaterRender.rebuildChunk(store, cx, cy, cz, water)
	end,
	onUnloaded = function(cx, cy, cz)
		Collision.removeChunk(cx, cy, cz, collision)
		WaterRender.removeChunk(cx, cy, cz, water)
	end,
})

-- Apply existing edits to the store BEFORE the first chunk streams, so each chunk's first
-- render already includes them (no base terrain showing first, then edits popping in). Bounded
-- so a slow/absent server can't stall terrain: fall back to streaming base, edits arrive via
-- the EditDeltas backup. ensureGenerated(base+autowedge) then setCell, matching the live path.
do
	local remotes = ReplicatedStorage:WaitForChild("VoxelRemotes", 10)
	local getOverlay = remotes and remotes:FindFirstChild("GetOverlay")
	if getOverlay then
		local result: any = nil
		local done = false
		task.spawn(function()
			local ok, deltas = pcall(function()
				return getOverlay:InvokeServer()
			end)
			result = ok and deltas or nil
			done = true
		end)
		local t0 = os.clock()
		while not done and os.clock() - t0 < 6 do
			task.wait()
		end
		if type(result) == "table" then
			for _, d in result do
				local wx, wy, wz, value = d[1], d[2], d[3], d[4]
				if wx and wy and wz and value then
					manager:ensureGenerated(VoxelStore.worldToChunk(wx), VoxelStore.worldToChunk(wy), VoxelStore.worldToChunk(wz))
					store:setCell(wx, wy, wz, Constants.unpackCell(value))
				end
			end
		end
	end
end

manager:start()
WaterRender.startScroll(water)

_G.VoxelChunkManager = manager
_G.VoxelStore = store
_G.VoxelWorldGen = gen

-- Drop the avatar in above the surface; M5 collision gives it ground to land on.
local swimCleanup: (() -> ())? = nil
local function placeCharacter(char: Model)
	local hrp = char:WaitForChild("HumanoidRootPart", 5)
	if hrp and hrp:IsA("BasePart") then
		-- max terrain height is 15 cells = 60 studs; drop in from safely above
		hrp.CFrame = CFrame.new(32, 120, 32)
	end
	if swimCleanup then
		swimCleanup()
	end
	swimCleanup = WaterPhysics.attach(store, char) -- legacy swimming via buffer lookup
end

player.CharacterAdded:Connect(placeCharacter)
if player.Character then
	placeCharacter(player.Character)
end

-- Edit replication + tool ---------------------------------------------------
local UserInputService = game:GetService("UserInputService")
local remotes = ReplicatedStorage:WaitForChild("VoxelRemotes")
local EditDeltas = remotes:WaitForChild("EditDeltas")
local RequestEdit = remotes:WaitForChild("RequestEdit")
local RequestExplode = remotes:WaitForChild("RequestExplode")

local FACE_DIR = {
	Vector3.new(1, 0, 0),
	Vector3.new(-1, 0, 0),
	Vector3.new(0, 1, 0),
	Vector3.new(0, -1, 0),
	Vector3.new(0, 0, 1),
	Vector3.new(0, 0, -1),
}

-- Apply broadcast deltas to the local store and dirty-rebuild affected chunks.
EditDeltas.OnClientEvent:Connect(function(deltas)
	local affected: { [string]: { cx: number, cy: number, cz: number } } = {}
	for _, d in deltas do
		local wx, wy, wz, value = d[1], d[2], d[3], d[4]
		manager:ensureGenerated( -- base first, so the edit isn't clobbered
			VoxelStore.worldToChunk(wx),
			VoxelStore.worldToChunk(wy),
			VoxelStore.worldToChunk(wz)
		)
		store:setCell(wx, wy, wz, Constants.unpackCell(value))
		for _, c in EditService.affectedChunks(wx, wy, wz) do
			affected[c.cx .. "_" .. c.cy .. "_" .. c.cz] = { cx = c.cx, cy = c.cy, cz = c.cz }
		end
	end
	for _, c in affected do
		manager:ensureGenerated(c.cx, c.cy, c.cz)
		manager:markDirty(c.cx, c.cy, c.cz)
	end
end)

-- DDA pick under the mouse (no physics raycast).
local function pickCell(): Collision.Hit?
	local cam = workspace.CurrentCamera
	if not cam then
		return nil
	end
	local mp = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(mp.X, mp.Y)
	return Collision.rayMarch(store, ray.Origin, ray.Direction, 90)
end

-- Left click = remove, Q = place, E = explode (all under the cursor).
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		local hit = pickCell()
		if hit then
			RequestEdit:FireServer(hit.cellX, hit.cellY, hit.cellZ, 0, 0)
		end
	elseif input.KeyCode == Enum.KeyCode.Q then
		local hit = pickCell()
		if hit and hit.face >= 1 then
			local dir = FACE_DIR[hit.face]
			RequestEdit:FireServer(
				hit.cellX + dir.X,
				hit.cellY + dir.Y,
				hit.cellZ + dir.Z,
				Constants.Material.Brick,
				Constants.packByte1(Constants.Shape.Solid, 0)
			)
		end
	elseif input.KeyCode == Enum.KeyCode.E then
		local hit = pickCell()
		if hit then
			RequestExplode:FireServer(hit.cellX, hit.cellY, hit.cellZ, 4)
		end
	end
end)
