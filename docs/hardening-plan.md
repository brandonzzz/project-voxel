# Code Hardening Plan — reducing theft exposure of the Legacy Voxel Terrain system

**Status: PLAN ONLY — nothing here has been implemented.**

## 1. The threat model, stated honestly

On Roblox, anything the **client** must execute is extractable. `ReplicatedStorage` and
`StarterPlayerScripts` contents are replicated to every client as bytecode; standard exploit tooling
decompiles that back into readable Luau. Comments and local names are lost, but algorithms, constants,
tuning values, and structure survive perfectly well. `ServerScriptService` is **never** replicated and
is genuinely safe.

So "hardening" here means exactly one thing: **move value out of the replicated half and into the
server half**, and accept that whatever must remain client-side is public.

### What is currently exposed

Everything in `ReplicatedStorage.LegacyVoxelTerrain` (the entire engine) plus
`StarterPlayerScripts.LegacyVoxelTerrain`. Ranked by how much of your IP it represents:

| Module | Value to a thief | Must it be client-side? |
|---|---|---|
| **Mesher** (cull → EditableMesh → bake → octant split, atlas UV mapping) | **Highest** — the hard-won part | **Yes** — rendering is client-side |
| **Shape** (hull triangles, orientation remap, face masks) | High | Yes — Mesher depends on it |
| **TextureAtlas** (calibrated slope/side/top UV math) | High — long calibration effort | Yes — needed to bake UVs |
| **WorldGen** (the actual world algorithm + seed) | **High — this is your *world*, not just an engine** | **No** — see Tier 2 |
| **Autowedge** (slope decision rules) | Medium-high | No, if results ship as data |
| **Collision** (greedy boxing) | Medium | Yes — client collision is client-built |
| **WaterRender / WaterPhysics** | Medium | Yes |
| **VoxelStore / Rle / Constants** | Low (format plumbing) | Yes |
| **ChunkManager / CollectPool** (streaming + Actor pool pacing) | Medium | Yes |

The uncomfortable conclusion up front: **the Mesher — the most valuable module — cannot be protected**
without abandoning client-side rendering, and client-side rendering is exactly the thing you already
A/B-tested and kept because server-render gave no client gain.

## 2. The structural tension

Your performance architecture requires:
- clients to **generate base terrain locally** from `f(seed)` (so only sparse edits replicate), and
- clients to **mesh and collide locally** (server-render was built, measured, and abandoned).

Both requirements force the corresponding code onto the client. Every hardening option below is a
trade of *bandwidth or performance* for *secrecy*. There is no free move.

## 3. Tiered plan

### Tier 0 — Free wins (do these regardless) — LOW effort, LOW-MEDIUM protection

1. **Stop shipping what the client never runs.** `Tests/` (8 modules) and `Demo/ShapeDemo` currently
   live under `ReplicatedStorage` and replicate to every client. They are pure development aids and
   hand a thief a labelled, executable spec of the whole format. Move them to `ServerStorage` (or a
   dev-only place). *Zero* functional cost.
2. **Move `PersistenceService` server-side.** The client never persists anything; the save format
   (region sharding, delta-chunk sentinel encoding, base64) is currently public for no reason. Only
   `Rle` needs to stay shared if the client decodes streamed chunks.
3. **Strip the docs.** Every module carries a detailed header comment explaining the design, plus
   inline rationale. Comments are stripped by compilation, *but* keep them out of any client-shipped
   copy you distribute in model form.
4. **Remove the debug surface.** `_G.VoxelChunkManager` / `_G.VoxelStore` / `_G.VoxelWorldGen` are
   handed to any client script, and the HUD advertises internals. Drop the `_G` exports.

**Tradeoff:** none worth mentioning. Do this first.

### Tier 1 — Server-authoritative edits (mostly already done) — LOW effort

You already removed client→server edit remotes; the client is a read-only consumer via `EditDeltas`
and the read-only `GetOverlay`. Keep it that way. Finish by ensuring the **client bind cannot mutate
shared state**: today `VoxelClient` binds the API with a live `store`, so `LegacyVoxelTerrain.SetCell`
on the client rewrites the local replica. That is not an authority hole (it's cosmetic and local), but
it *is* a free griefing/visual-desync vector and it demonstrates your API surface. Consider binding
the client with a read-only façade (`GetCell`/`rayMarch`/`sampleVoxel` only).

**Tradeoff:** your own client tooling (the Stamper preview) uses `sampleVoxel`/`ghostVoxel`, so keep
those; only remove the client-side *mutators*.

### Tier 2 — Move `WorldGen` server-side — MEDIUM effort, HIGH protection of *your world*

This is the highest-value realistic move. Today every client holds the generator and the seed, so
anyone can reproduce **your exact world** offline — arguably worse than losing the engine.

**How:** the server generates chunks and streams them to clients as compressed payloads. You already
have the entire codec: `Rle.encode`/`decode` over the 8192-byte chunk buffer, plus base64 if needed.
The client keeps `VoxelStore` and applies received chunks; `WorldGen`, `Autowedge`, and the seed all
move to `ServerScriptService`.

**Tradeoffs:**
- **Bandwidth.** This is the real cost. Today base terrain is free (computed locally) and only sparse
  edits replicate. After this change every streamed chunk is a network payload. An RLE'd uniform chunk
  is tiny (tens of bytes); a mixed surface chunk is the concern. Mitigations: send only `Mixed`
  chunks (uniform ones collapse to a flag — your `FillState` already models this), cache per-client so
  a revisited chunk isn't resent, and rate-limit to the streaming radius.
- **Latency.** Terrain can no longer appear before the round-trip completes. With a 3D streaming
  sphere at radius 6 this is noticeable on join and when moving fast.
- **Server CPU.** Generation moves onto the server for *every* player rather than being distributed
  across clients. With many players in different regions this is a real cost.
- **Autowedge must move too**, or clients could still derive the shape rules.

**Verdict:** worth it if the *world* is the product. Not worth it if the *engine* is the product,
because the engine still ships.

### Tier 3 — Obfuscation of the remaining client half — LOW effort, LOW protection

Rename modules/locals to opaque identifiers, inline constants, flatten module boundaries, strip the
`--!strict` type annotations that document intent. Optionally split the Mesher across several
meaningless module names.

**Tradeoff:** this is the classic bad deal — it meaningfully hurts *your* maintainability and
debuggability, and buys hours (not days) against a motivated thief. Recommend only for a final
shipping build produced by a script, never in your working source.

### Tier 4 — Full server-render — NOT RECOMMENDED

Would protect the Mesher, but you already built, A/B-tested, and reverted this: no client gain, and
collision + water + generation stayed client-side anyway (~25 ms/chunk). It also multiplies server
cost and mesh replication. Listed only for completeness.

## 4. Recommendation

1. **Do Tier 0 immediately.** It is free and removes a surprising amount of exposure (the test suite
   alone is a complete, executable specification of your voxel format).
2. **Do Tier 1** — small, tightens an already-good posture.
3. **Decide Tier 2 on this question:** *is the product the world, or the engine?*
   - If the **world** — do Tier 2. Protecting the generator + seed protects the thing players come for,
     and the bandwidth cost is manageable because your RLE + uniform-chunk collapse already exist.
   - If the **engine** — Tier 2 buys little, because the Mesher/Shape/Atlas still ship and that is what
     an engine thief wants. Spend the effort on licensing/DMCA posture instead.
4. **Skip Tier 3** except as an automated final-build step. **Skip Tier 4.**

## 5. The honest bottom line

You can protect **your world** (Tier 2) and you can stop **gift-wrapping** the system (Tier 0/1). You
cannot protect the renderer while rendering on the client. Any plan that claims otherwise is trading
real performance for the appearance of security. If full protection of the meshing pipeline is a hard
requirement, the only coherent path is server-render — and you already have measurements showing what
that costs.
