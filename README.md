# Legacy Voxel Terrain

A from-scratch **classic, blocky voxel terrain engine for Roblox** (Luau) — the old-school
destructible, editable, chunk-streamed terrain look, built entirely without Roblox's built-in Terrain.

## What it does

- **Deterministic base terrain** — the world is `f(seed)`, so every client regenerates the same base
  independently; only player *edits* are stored, as a sparse overlay on top of the base.
- **Custom surface meshing** — surfaces are built with `EditableMesh` against a calibrated texture
  atlas, with material-based slope / wedge / corner shaping (an "autowedge" pass).
- **3D chunk streaming** — render and collision stream around the player in a vertical (3D-sphere)
  radius, with a worker-`Actor` pool offloading the render cull off the main thread.
- **Server-authoritative edits** — the server owns the voxel store + edit overlay; edits and explosion
  craters replicate server → client only (clients have no edit authority).
- **Water** — rendered water with swim physics and shoreline handling.
- **Data-driven no-clip** — pushes a character out of solid voxels purely from voxel occupancy, with
  no world-space surface assumptions.
- **Persistence with swappable backends** — `None` / `PrivateServer` (DataStore) / `Custom` /
  `Preview` / `SavePlaceAsync`, chosen from in-game config.
- **Loose-part streaming** — top-level parts stream with their chunk and survive terrain unloads.

## ⚠️ Status: reconstruction after data loss

The authoritative Roblox Studio place file for this project was **lost**. Because the project had
stopped syncing to disk before then, this `src/` tree was **reconstructed afterward** from a
work-session transcript, the pre-loss source snapshot, and notes. As a result:

- Some files are exact, some are reconstructed, and **some Studio-only changes could not be recovered**
  and still need to be re-implemented.
- Expect **bugs, and incomplete or partially-wired features** — this is not a clean, runnable release.

See **[`RECOVERY.md`](RECOVERY.md)** for the full breakdown: what's exact vs reconstructed vs missing,
the DataModel instances that need recreating, and the edits still to be redone.

## Layout

| Path | DataModel location |
|---|---|
| `src/shared/` | `ReplicatedStorage.LegacyVoxelTerrain` — shared engine + module API facade |
| `src/server/` | `ServerScriptService.LegacyVoxelTerrain` — authoritative server, collision + loose-part streaming, persistence |
| `src/client/` | `StarterPlayer.StarterPlayerScripts` — client render / collision / water streaming |
| `src/serverscriptservice/`, `src/serverstorage/` | files whose real location is outside the three main folders (see `RECOVERY.md`) |
| `recovery/` | a script to recreate the lost config instances |

The original Rojo sync is no longer used; the paths above are documented placement, not a live build.

## Using this

Published **source-available, for learning and reference** — read it, see how the pieces fit together,
and take ideas for your own terrain systems. Individual files keep their original headers.
