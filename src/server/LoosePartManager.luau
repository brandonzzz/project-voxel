--!strict
--[[
	LoosePartManager — streams loose physics objects with the terrain chunks (server).

	A "loose object" is a TOP-LEVEL workspace child that is either an unanchored BasePart or a
	non-character Model containing an unanchored part. Each such object's physics assembly
	streams as ONE unit (Models keep their welded assemblies together; a standalone part is a
	single-part assembly). Anchored parts and player characters are ignored here.

	When a chunk UNLOADS its terrain collision, the loose objects sitting in that chunk are
	parked in ServerStorage so they can't fall through the now-collision-less area; when the
	chunk LOADS again they are returned to the workspace at their stored positions.

	The parking location IS the index -- ServerStorage/VoxelStowedParts/Chunk_<cx>_<cz>. There
	is no lookup table and no DataStore: ServerStorage saves with the place, so a SavePlaceAsync
	place keeps stowed objects under their chunk directories and restores them on next load.
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")

local Lib = game:GetService("ReplicatedStorage"):WaitForChild("LegacyVoxelTerrain")
local Constants = require(Lib:WaitForChild("Constants"))
local CHUNK_STUDS = Constants.CHUNK * Constants.CELL

local LoosePartManager = {}

local STOW_ROOT_NAME = "VoxelStowedParts"
-- A part with this tag pins every chunk it occupies (across boundaries) as permanently
-- collision-loaded, and is itself exempt from streaming out.
local SOFTLOAD_TAG = "RBLXClassic_ChunkSoftLoader"

-- Collision groups for ownership-aware terrain collision. A CLIENT-owned loose assembly is put
-- in GROUP_CLIENT, which is set non-collidable with the server terrain group -- so on the
-- owning client it rests on that client's OWN collision (in Default) and ignores the (coincident)
-- replicated server collision. A SERVER-owned assembly stays in Default and collides with the
-- server terrain. Swapped by GetNetworkOwner (see updateOwnershipGroups).
local GROUP_CLIENT = "LooseClient"
local GROUP_DEFAULT = "Default"

local function setObjectGroup(inst: Instance, group: string)
	if inst:IsA("BasePart") then
		if inst.CollisionGroup ~= group then
			inst.CollisionGroup = group
		end
	else
		for _, d in inst:GetDescendants() do
			if d:IsA("BasePart") and d.CollisionGroup ~= group then
				d.CollisionGroup = group
			end
		end
	end
end

local function stowRoot(): Folder
	local f = ServerStorage:FindFirstChild(STOW_ROOT_NAME)
	if not f then
		f = Instance.new("Folder")
		f.Name = STOW_ROOT_NAME
		f.Parent = ServerStorage
	end
	return f :: Folder
end

local function chunkFolderName(cx: number, cz: number): string
	return string.format("Chunk_%d_%d", cx, cz)
end

local function isCharacter(model: Model): boolean
	return model:FindFirstChildOfClass("Humanoid") ~= nil or Players:GetPlayerFromCharacter(model) ~= nil
end

local function isSoftLoader(inst: Instance): boolean
	return CollectionService:HasTag(inst, SOFTLOAD_TAG)
end

-- A top-level workspace child that STREAMS with chunks (parked on unload, restored on load):
-- any Part or non-character Model, EXCEPT the world baseplate and ChunkSoftLoader-tagged parts
-- (those stay in place, never stowed). Both anchored and unanchored qualify. The terrain
-- collision is a Folder of nested parts, so it never matches here. --
local function isStreamable(inst: Instance): boolean
	if isSoftLoader(inst) then
		return false
	end
	if inst:IsA("Terrain") then
		return false -- the engine's singleton Terrain is-a BasePart but can't be reparented
	end
	if inst:IsA("Model") then
		return not isCharacter(inst)
	elseif inst:IsA("BasePart") then
		return inst.Name ~= "Baseplate"
	end
	return false
end

-- A streamable object with an unanchored part: only these get ownership collision groups and
-- the SC4 edge soft-load (anchored streamables don't need collision under them). --
local function isLoose(inst: Instance): boolean
	if not isStreamable(inst) then
		return false
	end
	if inst:IsA("BasePart") then
		return not inst.Anchored
	end
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") and not d.Anchored then
			return true
		end
	end
	return false
end

local function objectChunk(inst: Instance): (number, number)
	local pos: Vector3
	if inst:IsA("Model") then
		pos = inst:GetPivot().Position
	else
		pos = (inst :: BasePart).Position
	end
	return math.floor(pos.X / CHUNK_STUDS), math.floor(pos.Z / CHUNK_STUDS)
end

local function stowFolderFor(cx: number, cz: number): Folder
	local root = stowRoot()
	local name = chunkFolderName(cx, cz)
	local f = root:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = root
	end
	return f :: Folder
end

-- Park every loose object currently in chunk (cx,cz) into its ServerStorage directory. Call
-- this when the chunk's collision unloads, so the object leaves the world before it can fall. --
function LoosePartManager.stowChunk(cx: number, cz: number)
	local dest: Folder? = nil
	for _, inst in workspace:GetChildren() do
		if isStreamable(inst) then
			local ocx, ocz = objectChunk(inst)
			if ocx == cx and ocz == cz then
				dest = dest or stowFolderFor(cx, cz)
				inst.Parent = dest
			end
		end
	end
end

-- Return every object stowed for chunk (cx,cz) to the workspace (collision is present again). --
function LoosePartManager.restoreChunk(cx: number, cz: number)
	local root = ServerStorage:FindFirstChild(STOW_ROOT_NAME)
	if not root then
		return
	end
	local dest = root:FindFirstChild(chunkFolderName(cx, cz))
	if not dest then
		return
	end
	for _, inst in dest:GetChildren() do
		-- reset to the server-owned default so a part stowed as LooseClient (which ignores the
		-- server terrain) can't fall through before the next ownership poll re-classifies it.
		setObjectGroup(inst, GROUP_DEFAULT)
		inst.Parent = workspace
	end
	dest:Destroy() -- empty now; the directory only exists while it holds parked objects
end

-- World-AABB chunk span of an object, padded by its bounding sphere so rotation can't make us
-- miss a chunk it overlaps. Returns the home chunk + the list of all chunks it touches. --
local function objectSpan(inst: Instance): (number, number, { { cx: number, cz: number } })
	local center: Vector3
	local radius: number
	if inst:IsA("Model") then
		local cf, size = inst:GetBoundingBox()
		center = cf.Position
		radius = size.Magnitude / 2
	else
		local p = inst :: BasePart
		center = p.Position
		radius = p.Size.Magnitude / 2
	end
	local hcx = math.floor(center.X / CHUNK_STUDS)
	local hcz = math.floor(center.Z / CHUNK_STUDS)
	local minCx = math.floor((center.X - radius) / CHUNK_STUDS)
	local maxCx = math.floor((center.X + radius) / CHUNK_STUDS)
	local minCz = math.floor((center.Z - radius) / CHUNK_STUDS)
	local maxCz = math.floor((center.Z + radius) / CHUNK_STUDS)
	local span = {}
	for cx = minCx, maxCx do
		for cz = minCz, maxCz do
			span[#span + 1] = { cx = cx, cz = cz }
		end
	end
	return hcx, hcz, span
end

-- SC4 + SC5: expand the desired chunk set. For each LOOSE assembly whose HOME chunk is already
-- wanted (loaded around a player), add every chunk it spans into, so it can't fall through a
-- loaded/unloaded seam (gated on the home chunk so far-away assemblies still unload + stow). For
-- each ChunkSoftLoader-tagged part, add every chunk it occupies UNCONDITIONALLY -- that pins
-- those chunks' collision permanently, regardless of player proximity. Mutates `want`. --
function LoosePartManager.expandLoaded(want: { [string]: { cx: number, cz: number } })
	for _, inst in workspace:GetChildren() do
		if isSoftLoader(inst) then
			local _, _, span = objectSpan(inst)
			for _, c in span do
				want[string.format("%d_%d", c.cx, c.cz)] = c
			end
		elseif isLoose(inst) then
			local hcx, hcz, span = objectSpan(inst)
			if want[string.format("%d_%d", hcx, hcz)] then
				for _, c in span do
					want[string.format("%d_%d", c.cx, c.cz)] = c
				end
			end
		end
	end
end

-- Stow any loose object whose HOME chunk has no collision loaded (spawned into an unloaded
-- area, or sitting past the server collision radius) so it can't sit/fall with nothing under
-- it. The streamer's restoreChunk returns it when that chunk loads. Run periodically. --
function LoosePartManager.stowOrphans(isLoaded: (number, number) -> boolean)
	for _, inst in workspace:GetChildren() do
		if isStreamable(inst) then
			local hcx, hcz = objectChunk(inst)
			if not isLoaded(hcx, hcz) then
				inst.Parent = stowFolderFor(hcx, hcz)
			end
		end
	end
end

-- Poll every loose workspace assembly's network owner and put it in the matching collision
-- group: GROUP_CLIENT when a client owns it (rests on that client's own collision), Default
-- when the server owns it (rests on the server collision). Run periodically. --
function LoosePartManager.updateOwnershipGroups()
	for _, inst in workspace:GetChildren() do
		if isLoose(inst) then
			local rep = (inst:IsA("BasePart") and inst) or inst:FindFirstChildWhichIsA("BasePart", true)
			if rep and not (rep :: BasePart).Anchored then
				local owner: Player? = nil
				pcall(function()
					owner = (rep :: BasePart):GetNetworkOwner()
				end)
				setObjectGroup(inst, if owner then GROUP_CLIENT else GROUP_DEFAULT)
			end
		end
	end
end

-- Park ALL loose objects currently in the workspace, by chunk. Used at server startup: a saved
-- place can leave loose parts in the workspace over chunks whose collision isn't loaded yet, so
-- park them all (respecting them) and let the streamer restore each as its chunk loads. --
function LoosePartManager.stowAll()
	for _, inst in workspace:GetChildren() do
		if isStreamable(inst) then
			local cx, cz = objectChunk(inst)
			inst.Parent = stowFolderFor(cx, cz)
		end
	end
end

return LoosePartManager
