--!strict
--[[
	VoxelClient — runtime entry point (StarterPlayerScripts). Builds the client
	store + generator + ChunkManager and streams terrain around the camera.

	Streams render + collision + water around the character and binds the
	LegacyVoxelTerrain API to this local replica. Exposes the manager at _G.VoxelChunkManager.
	(No remotes: the terrain system creates none, so there is no edit-delta replication here.)
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Lib = ReplicatedStorage:WaitForChild("LegacyVoxelTerrain")
local VoxelStore = require(Lib:WaitForChild("VoxelStore"))
local WorldGen = require(Lib:WaitForChild("WorldGen"))
local ChunkManager = require(Lib:WaitForChild("ChunkManager"))
local Collision = require(Lib:WaitForChild("Collision"))
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
	onBuilt = function(cx, cy, cz, tris)
		if tris > 0 then
			-- Visible chunk: pace the collision+water rebuild onto its own gated frame so it doesn't
			-- pile onto the frame that just ran the render bake/CreateMeshPartAsync (that was the stutter).
			manager:waitAssetSlot()
			Collision.rebuildChunk(store, cx, cy, cz, collision)
		else
			-- No render triangles => no exposed faces => buried or empty => unreachable, so it needs no
			-- collision (collision is solid-cube only). This skips the entire invisible interior of the
			-- 3D sphere (deep bedrock, sky). No bake ran either, so there's nothing to pace against --
			-- don't spend an asset-slot credit. removeChunk clears stale collision if an edit just
			-- buried a formerly-exposed chunk. A later dig re-exposes faces -> tris > 0 -> collision back.
			Collision.removeChunk(cx, cy, cz, collision)
		end
		-- Water is independent of solid render tris (a fully-submerged chunk has 0 solid tris but still
		-- renders water), and is cheap for uniform chunks, so refresh it either way.
		WaterRender.rebuildChunk(store, cx, cy, cz, water)
	end,
	onUnloaded = function(cx, cy, cz)
		Collision.removeChunk(cx, cy, cz, collision)
		WaterRender.removeChunk(cx, cy, cz, water)
	end,
})

-- Expose the classic-terrain API (LegacyVoxelTerrain.GetCell/SetCell/...) on this CLIENT replica:
-- edits write the local store + rebuild render/collision/water for the affected chunks. No onDeltas --
-- the client replica is local; route edits through the server (authoritative) if replication is needed.
local LegacyVoxelTerrain = require(Lib)
LegacyVoxelTerrain.bind({
	store = store,
	ensureGenerated = function(cx, cy, cz)
		manager:ensureGenerated(cx, cy, cz)
	end,
	markDirty = function(cx, cy, cz)
		manager:markDirty(cx, cy, cz)
	end,
})

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
