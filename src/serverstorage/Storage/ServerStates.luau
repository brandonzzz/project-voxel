-- [RECOVERED 2026-09-17 verbatim from the session transcript. Studio location:
--  ServerStorage.Storage.ServerStates (ModuleScript). NOTE: as recovered this module is BROKEN --
--  it references ReplicatedStorage.RemoteSignals, which does not exist (it came from another place
--  file). It is also not wired to any script yet. Phase-A fixes are documented in RECOVERY.md and
--  [[worlds-and-runtime-update-plan]] (ensure/create RemoteSignals; add a StateInit RemoteFunction
--  for late joiners; self-wire PlayerAdded/Removing). Preserved AS-WAS for fidelity.]

local ServerStates = {}
local RS = game:GetService("ReplicatedStorage")
local P = game:GetService("Players")
-- Remote for replicating session state changes to clients
local stateSync = Instance.new("RemoteEvent")
stateSync.Name = "StateSync"
stateSync.Parent = RS.RemoteSignals
-- Session states: permanent, optionally replicated
-- { [stateName] = { data = {}, replicate = bool } }
local sessionStates = {}
-- Player states: per-player, never replicated, cleaned up on leave
-- { [plr] = { [key] = value } }
local playerStates = {}
-- Register a session state
function ServerStates.RegisterSessionState(name, initialData, replicate)
	sessionStates[name] = {
		data = initialData or {},
		replicate = replicate or false,
	}
	if replicate then
		-- Replicate initial state to any already-connected clients
		stateSync:FireAllClients(name, initialData or {})
	end
end
-- Set a value in a session state
function ServerStates.Set(stateName, key, value)
	local state = sessionStates[stateName]
	if not state then
		warn("ServerStates.Set: unknown state '" .. tostring(stateName) .. "'")
		return
	end
	state.data[key] = value
	if state.replicate then
		stateSync:FireAllClients(stateName, state.data)
	end
end
-- Get a value from a session state
function ServerStates.Get(stateName, key)
	local state = sessionStates[stateName]
	if not state then return nil end
	if key then return state.data[key] end
	return state.data
end
-- Initialize a player state (call on PlayerAdded)
function ServerStates.InitPlayer(plr)
	playerStates[plr] = {}
end
-- Get a player's state table (transient access only — do not cache)
function ServerStates.GetPlayerState(plr)
	return playerStates[plr]
end
-- Set a value in a player state
function ServerStates.SetPlayerState(plr, key, value)
	local state = playerStates[plr]
	if not state then
		warn("ServerStates.SetPlayerState: no state for " .. tostring(plr))
		return
	end
	state[key] = value
end
-- Clean up a player state (call on PlayerRemoving)
function ServerStates.CleanupPlayer(plr)
	playerStates[plr] = nil
end
-- Internal accessor for iterating all player states
function ServerStates._playerStates()
	return next, playerStates
end

return ServerStates
