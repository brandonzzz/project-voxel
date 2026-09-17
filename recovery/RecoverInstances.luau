--!strict
--[[
	RecoverInstances — recreates the non-script DataModel instances that were lost with the Studio
	place file (they can't live in src/ as .luau). Run ONCE in a fresh place (e.g. paste into the
	command bar, or drop as a Script, run, then delete). Idempotent: it only creates what's missing.

	See RECOVERY.md §2. Values marked TODO are LOST and must be re-chosen to match the intended world.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local function folder(parent: Instance, name: string): Folder
	local f = parent:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f :: Folder
end

local function value(parent: Instance, className: string, name: string, v: any)
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Value = v
	inst.Parent = parent
	return inst
end

-- ReplicatedStorage.TerrainConfig (read by BOTH client + server) --------------------
local terrainConfig = folder(ReplicatedStorage, "TerrainConfig")
value(terrainConfig, "IntValue", "seed", 0)          -- TODO: real seed was LOST
value(terrainConfig, "StringValue", "type", "")      -- TODO: real WorldGen type was LOST
value(terrainConfig, "NumberValue", "period", 1)     -- TODO: real period was LOST
value(terrainConfig, "NumberValue", "amplitude", 1)  -- TODO: real amplitude was LOST
value(terrainConfig, "IntValue", "flatHeight", 12)   -- ~12 (from testing); confirm
value(terrainConfig, "BoolValue", "isInitialized", false) -- server sets true on its last boot line

-- ServerStorage.WorldConstants (server-only save settings) --------------------------
local worldConstants = folder(ServerStorage, "WorldConstants")
value(worldConstants, "StringValue", "saveType", "PrivateServer") -- None/PrivateServer/Custom/Preview/SavePlaceAsync
value(worldConstants, "StringValue", "customKey", "")

-- ReplicatedStorage.RemoteSignals (StateService expects this; it did NOT exist before) ---
folder(ReplicatedStorage, "RemoteSignals")

-- ServerStorage.Storage (organizing folder; AxisModel is LOST and cannot be recreated) ---
folder(ServerStorage, "Storage")

print("[RecoverInstances] done. Review TODO values in ReplicatedStorage.TerrainConfig.")
