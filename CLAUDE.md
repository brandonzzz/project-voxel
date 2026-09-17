# Legacy Voxel Terrain — project instructions

## Deployment workflow (IMPORTANT — changed 2026-07-23)

**Files in this repo no longer sync to the Roblox Studio project.** Rojo is no longer the deploy
channel. Editing anything under `src/` has **no effect** on what runs in Studio.

- **Studio is the source of truth for in-studio content.**
- **Modify anything in-studio through the Roblox Studio MCP server** (`multi_edit` / setting
  `.Source`, `execute_luau`, instance creation and property edits). Editing scripts via MCP is now
  the correct path — the old "never edit scripts via MCP" rule is obsolete.
- **Read live state from Studio, not from `src/`**: use `script_read`, `script_grep`,
  `search_game_tree`, `inspect_instance`. The `src/` tree is a historical snapshot from the Rojo era
  and **will drift** from Studio. Never assert current behavior from a repo file without checking
  Studio first.
- Git still tracks history and is useful for reading past implementations, but committing deploys
  nothing.

## Where things live in Studio

- `ReplicatedStorage/LegacyVoxelTerrain` — shared engine + the parent ModuleScript API facade
- `ServerScriptService/LegacyVoxelTerrain` — VoxelServer, LoosePartManager, ServerChunkStreamer
- `StarterPlayer/StarterPlayerScripts/LegacyVoxelTerrain` — VoxelClient + collect workers

## MCP gotchas that still apply

- `execute_luau` runs in its **own require context** with its own `_G`. It cannot read a running
  script's module/bound/singleton state. Verify running-script state via the Output console and
  observable DataModel side effects instead.
- An already-required module in a live **Edit** session can serve **stale** source after an edit.
  Restart Play to force a fresh require before trusting a behavioral test.

## User-owned areas — do not modify without being asked

`StarterPack` (the Stamper tool) and `ReplicatedStorage.Packages` are the user's own work.
