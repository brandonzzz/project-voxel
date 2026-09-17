# RECOVERY — Studio place file lost (2026-09-17)

The Roblox Studio place file (`Voxel Terrain Demonstration`) was lost. Since **files stopped syncing
to Studio on 2026-07-23** (see `CLAUDE.md`), the `src/` tree was a stale pre-2026-07-23 snapshot and
Studio was the only home for ~2 months of work. This document records what was recovered, at what
fidelity, and — critically — **what was NOT recovered and must be re-done**.

Recovery was assembled from: (a) this session's transcript (exact code for anything read/written
here), (b) the pre-refactor `src/server/VoxelServer.server.luau` as the reconstruction base, and
(c) the `memory/` files (prose descriptions only — no verbatim source).

## Fidelity tiers

- **Tier 1 — EXACT** (verbatim from the transcript): `TerrainServer` save-options/boot sections,
  `ManualLoader`, `ServerStates`, `ClientStates`.
- **Tier 2 — RECONSTRUCTED** (`TerrainServer` as a whole): the save-options sections are Tier 1; the
  untouched middle (ensureWorld / recordEdit / detonate / no-clip / streamer / bind) is the verbatim
  `src` VoxelServer body. High confidence, but **not runtime-verified** (no Studio).
- **Tier 3 — DESCRIBED ONLY** (memory prose, no source): Studio-only edits to *shared* modules since
  2026-07-23. These are **listed below as a re-implementation checklist** — they are NOT in the code.
- **Tier 4 — LOST**: `AxisModel` (a binary Model), exact values of config instances, and anything
  changed in Studio that left no trace in transcript/memory/src.

---

## 1. Files written by this recovery

| File (in `src/`) | True Studio location | Fidelity |
|---|---|---|
| `server/TerrainServer.luau` | `ServerScriptService.LegacyVoxelTerrain.TerrainServer` | Tier 1 + 2 |
| `serverscriptservice/ManualLoader.server.luau` | `ServerScriptService.ManualLoader` (root) | Tier 1 |
| `serverstorage/Storage/ServerStates.luau` | `ServerStorage.Storage.ServerStates` | Tier 1 (broken as-was) |
| `serverstorage/Storage/ClientStates.luau` | `ServerStorage.Storage.ClientStates` | Tier 1 (mislocated as-was) |
| `server/PersistenceService.luau` | `ServerScriptService.LegacyVoxelTerrain.PersistenceService` | copied from `shared/` (see §4) |

> The `src/serverscriptservice` and `src/serverstorage` folders are new, created to preserve the true
> DataModel service of files that live outside the three original Rojo roots (`shared`→ReplicatedStorage,
> `server`→ServerScriptService.LegacyVoxelTerrain, `client`→StarterPlayerScripts). Rojo is dead, so
> these paths are documentation, not a build map.

---

## 2. Instances to recreate (NOT scripts — cannot live in `src/`)

Run `recovery/RecoverInstances.luau` in a fresh place (or recreate by hand). Structure is known;
**values marked `?` are lost and must be re-chosen.**

**`ReplicatedStorage.TerrainConfig`** (Folder) — read by BOTH client + server so `f(seed)` agrees:
- `seed` — IntValue — `?`
- `type` — StringValue — `?` (a WorldGen terrain type name)
- `period` — NumberValue — `?` (float)
- `amplitude` — NumberValue — `?` (float)
- `flatHeight` — IntValue — ~`12` (character landed on a flat height-12 surface in testing)
- `isInitialized` — BoolValue — `false` (server sets true on its last boot line; replaced the old
  `ReplicatedStorage.Loaded` BoolValue)

**`ServerStorage.WorldConstants`** (Folder) — server-only save settings:
- `saveType` — StringValue — `"PrivateServer"` (default). Valid: None / PrivateServer / Custom / Preview / SavePlaceAsync
- `customKey` — StringValue — `""`

**`ReplicatedStorage.RemoteSignals`** (Folder) — **did NOT exist** in the lost place; `ServerStates`
references it and errors without it. Create it (or fix `ServerStates` to ensure/create it — the
planned Phase-A fix).

**`ServerStorage.Storage`** (Folder) — organizing folder the user added; held `AxisModel`,
`ClientStates`, `ServerStates`, `LegacyVoxelTerrainDev`.

---

## 3. Deletions / renames / moves made in Studio (this session)

- **DELETED `ServerScriptService.LegacyVoxelTerrain.VoxelServer`** (the thin launcher). `src/server/
  VoxelServer.server.luau` is the OLD pre-refactor full server — **superseded by `TerrainServer.luau`**;
  keep it only as the reconstruction base / history.
- **DELETED `ServerStorage.LoadId`** (StringValue) — retired; replaced by the WorldConstants resolver.
- **MOVED `PersistenceService`** from `ReplicatedStorage.LegacyVoxelTerrain` → `ServerScriptService.
  LegacyVoxelTerrain` (server-only). `TerrainServer` requires it via `script.Parent`. (See §4.)
- **`ReplicatedStorage.Loaded` → `ReplicatedStorage.TerrainConfig.isInitialized`** (handshake gate),
  on both server and client.
- **`Initialize()` → split into `Initialize()` (boot reconcile) + `Load()`** in the terrain server
  (was going to be renamed to `Reconcile()` in the planned Phase A — NOT yet done; still `Initialize`).

---

## 4. `src/` sync actions to finish (mechanical, safe)

- **`PersistenceService`**: recovery copied `src/shared/PersistenceService.luau` → `src/server/
  PersistenceService.luau` to reflect the move. Content appears unchanged from the snapshot (spot-read
  this session matched). The `shared/` copy is left as history; the `server/` copy is the live one.
- **`VoxelClient`** (`src/client/VoxelClient.client.luau`) — the snapshot is VERY stale: it predates
  even the `Loaded` handshake (it has NO gate at all and its gen read `Constants.WORLD_SEED`). Two
  correctness edits are now APPLIED by this recovery (marked `[RECOVERED 2026-09-17]` inline):
  1. Added `local TerrainConfig = ReplicatedStorage:WaitForChild("TerrainConfig")`.
  2. gen now reads `WorldGen.new(TerrainConfig.seed.Value, { type, period, amplitude, flatHeight })`
     so client/server `f(seed)` agree (was `WorldGen.new(Constants.WORLD_SEED)` — a real mismatch bug).
  STILL MISSING (Studio-only, not recovered — must be ADDED, exact placement re-derived):
  3. Main gate before streaming: `repeat task.wait() until TerrainConfig.isInitialized.Value`
     (goes AFTER swim setup + `local store = VoxelStore.new()`, BEFORE the stream loop).
  4. setupCharacter reposition gate: `if hrp and hrp:IsA("BasePart") and TerrainConfig.isInitialized.Value then`
  Because the base predates the gate, don't expect a clean anchor — reconstruct the gate by hand.
- **Uncommitted working-tree edits** at loss time (`git status`): `src/shared/Constants.luau`,
  `src/shared/WorldGen.luau`, `src/shared/init.luau` were modified but uncommitted. Their relationship
  to the lost Studio state is UNCERTAIN — review before trusting. In particular `WorldGen.new` must
  accept `(seed, { type, period, amplitude, flatHeight })` (TerrainServer + VoxelClient call it that
  way); confirm the snapshot supports that signature or port it.

---

## 5. Tier 3 — Studio-only edits to SHARED modules NOT in `src` (re-implement)

These were made in Studio after 2026-07-23 (per `memory/`) and are **absent from `src` and from any
verbatim source**. Descriptions below are the spec; the code must be re-derived and re-verified.

1. **ChunkManager storage-budget retention** (2026-07-25) — REPLACED distance-unloading with budget
   retention. `_unloadFar` is GONE; add `_evictOverBudget`: keep every built chunk loaded, evict only
   the FARTHEST chunks (outside the active radius) once the loaded set exceeds `maxLoadedChunks`
   (default 2000). Live-tunable via the container's `MaxLoadedChunks` attribute (like `RenderDistance`).
   Runs every frame (reuse the HUD count loop; only sort when over cap). `unloadMargin` kept in Options
   for compat but unused. WHY: pacing across a chunk boundary no longer reload-thrashes.
   (See `memory/chunk-scan-perf-optimization.md`.)

2. **Explosion re-slope `reshape` flag** (2026-07-25) — spans `Autowedge.decide` → `Autowedge.region`
   → `EditService.autowedgeRegion` → `VoxelServer.detonate` (now `TerrainServer` — the detonate call
   is flagged inline in `TerrainServer.luau` as the pre-reshape version). `decide` gains a `reshape`
   flag: when true, re-derive already-shaped cells from CURRENT neighbours via the full ruleset (convex
   + inside-corner), reverting toward Solid when sides get walled, with a change-check
   (`packByte1(target) == currentByte1 -> nil`) suppressing no-op deltas. **ONLY `detonate` passes
   `reshape=true`**; base gen (ensureWorld/_wedgeOne) and the facade Autowedge calls keep default false
   (so base gen stays idempotent + identical client/server). Safe because the explosion pass is
   server-only and its deltas are broadcast. (See `memory/server-streaming-and-physics-foundation.md`.)

3. **Mesher corner-above-corner crest fix** (2026-07-25) — in `Mesher.forEachTriangle`, the corner
   branch (`t.face == 0`): `if not crest and shape == CornerWedge and upMat ~= WATER and
   unpackByte1(upByte1) == CornerWedge then crest = true`. A CornerWedge diagonally up-slope is set
   back from the slope plane and does NOT continue it, so the lower corner keeps its crest. ICW / solid
   up the diagonal still continue (crest cleared, unchanged). (See `memory/slope-texture-uv-solution.md`.)

4. **Possibly others** — the `memory/` files also mention camera-occlusion tagged colliders and
   licensing headers; verify against `memory/camera-occlusion-limitation.md` and others. Treat every
   `memory/*.md` entry dated after 2026-07-23 and marked "Studio-only edit via MCP" as a candidate
   divergence to check.

---

## 6. Lost with no recovery path (Tier 4)

- **`AxisModel`** (Model in `ServerStorage.Storage`) — binary geometry, not reconstructable.
- **Exact values** of `TerrainConfig` (seed/type/period/amplitude) and any world save data that lived
  only in the place / its DataStores / SavePlaceAsync StringValues.
- **The exact source** of the Tier-3 shared-module edits (only prose specs survive).

---

## 7. Verification checklist (before trusting the recovered tree)

- [ ] Recreate the config instances (§2) via `recovery/RecoverInstances.luau`.
- [ ] Finish the `src/` sync actions (§4): PersistenceService location, VoxelClient edits, review the
      three uncommitted shared files, confirm `WorldGen.new` signature.
- [ ] Re-implement the Tier-3 shared-module edits (§5) and re-run the test suite (`src/shared/Tests`).
- [ ] Boot-test the full path: `Initialize()` → `/load` (PrivateServer) → terrain streams, character
      lands, no console errors.
- [ ] Confirm `TerrainServer`'s detonate reshape gap (§5.2) before relying on explosion craters.
- [ ] Commit everything to git — the whole point is that the code no longer lives in a single `.rbxl`.

## 8. Planned next work (unaffected by the loss, still valid)

See `memory/worlds-and-runtime-update-plan.md` — the multi-world / runtime-update plan. Phase A
(StateService fixes + `isInitialized`→StateService + `Initialize`→`Reconcile`) now doubles as the
natural place to also land the StateService relocation/fixes noted in §2–3.
