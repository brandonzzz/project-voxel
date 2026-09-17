-- [RECOVERED 2026-09-17 verbatim from the session transcript. Studio location as found:
--  ServerStorage.Storage.ClientStates (ModuleScript). NOTE: this is a BUG in the found state --
--  a client-side module in ServerStorage is unreachable by clients; it MUST be relocated to
--  ReplicatedStorage. It also indexes RS.RemoteSignals.StateSync without WaitForChild (require-time
--  race). Phase-A fixes in RECOVERY.md / [[worlds-and-runtime-update-plan]]. Preserved AS-WAS.]

local ClientStates = {}

local RS = game:GetService("ReplicatedStorage")

-- Local cache of replicated session states
-- { [stateName] = { data = {}, listeners = {fn} } }
local cache = {}

-- Listen for updates from server
RS.RemoteSignals.StateSync.OnClientEvent:Connect(function(stateName, data)
	if not cache[stateName] then
		cache[stateName] = { data = {}, listeners = {} }
	end
	-- Update in place so any scripts holding a reference see the change
	local entry = cache[stateName]
	for k in entry.data do entry.data[k] = nil end
	for k, v in data do entry.data[k] = v end
	-- Fire listeners
	for _, fn in entry.listeners do
		task.spawn(fn, entry.data)
	end
end)

-- Get a value from a replicated session state
function ClientStates.Get(stateName, key)
	local entry = cache[stateName]
	if not entry then return nil end
	if key then return entry.data[key] end
	return entry.data
end

-- Listen for changes to a session state
-- fn is called with the full updated data table whenever the state changes
function ClientStates.OnChanged(stateName, fn)
	if not cache[stateName] then
		cache[stateName] = { data = {}, listeners = {} }
	end
	table.insert(cache[stateName].listeners, fn)
end

return ClientStates
