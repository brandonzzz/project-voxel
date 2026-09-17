-- [RECOVERED 2026-09-17 verbatim from the session transcript. Studio location:
--  ServerScriptService.ManualLoader (a Script at the root of ServerScriptService, NOT inside the
--  LegacyVoxelTerrain folder). See RECOVERY.md.]

-- ManualLoader -- chat-driven terrain boot for the authorised developer.
-- Sets the save configuration in ServerStorage.WorldConstants, then calls TerrainServer.Load()
-- directly. Load's resolver reads WorldConstants (saveType/customKey) + TerrainConfig to decide
-- whether and how to load. Load is double-load guarded, so the FIRST successful command wins for the
-- session; a refused config (e.g. Custom with no key) leaves it un-loaded and retryable. (Universal
-- boot safety -- stowing loose parts + clearing stale collision -- runs via Initialize() at start.)
--
--   /load          -> PrivateServer: saves to a DataStore scoped to this private server's Id
--                     (in a public server it loads/generates but never saves).
--   /load <key>    -> Custom, customKey=<key>: loads+saves the world stored under <key>. <key> may be
--                     a PrivateServerId, to open a private world's save from anywhere.
--   /preview       -> None: generates fresh terrain, never saves (customKey ignored).
--   /preview <key> -> Preview, customKey=<key>: loads the world under <key>; edits work in-session
--                     but are never saved.
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local WorldConstants = ServerStorage:WaitForChild("WorldConstants")
local TerrainServer = require(
	ServerScriptService:WaitForChild("LegacyVoxelTerrain"):WaitForChild("TerrainServer")
)

-- Universal boot safety, run immediately at server start (independent of any command): stows loose
-- parts + clears stale collision before the first physics step, so a saved place's parts don't fall.
TerrainServer.Initialize()

-- Set the save configuration, then load. The resolver inside Load() validates it (and refuses an
-- unsupported/incomplete config); requiring TerrainServer is side-effect-free until Initialize/Load.
local function boot(saveType: string, customKey: string)
	WorldConstants.saveType.Value = saveType
	WorldConstants.customKey.Value = customKey
	TerrainServer.Load()
end

local authId = 30578488

game.Players.PlayerAdded:Connect(function(plr)
	if plr.UserId == authId then
		plr.Chatted:Connect(function(msg)
			if string.sub(msg, 1, 1) == "/" then
				local split = string.split(string.sub(msg, 2), " ")
				local cmd = table.remove(split, 1)
				local args = split

				if cmd == "load" then
					if args[1] then
						boot("Custom", args[1])
					else
						boot("PrivateServer", "")
					end
				elseif cmd == "preview" then
					if args[1] then
						boot("Preview", args[1])
					else
						boot("None", "")
					end
				end
			end
		end)
	end
end)

print("Private Server Id:", game.PrivateServerId)
