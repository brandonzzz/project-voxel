# Feature Request Draft — Allow applying baked mesh `Content` to a `MeshPart` without the fixed-cost, main-thread `CreateMeshPartAsync`

> Draft for DevForum → Platform Feedback → Engine Features. Finalize wording/links before posting.

## Summary

`AssetService:CreateMeshPartAsync()` costs a **fixed ~22 ms of blocking main-thread time per call**,
essentially independent of mesh complexity. For any system that continuously rebuilds runtime geometry
(voxel terrain, destructible meshes, procedural worlds), this single call is the hard floor on frame
time. It cannot be parallelized, batched, amortized, or bypassed. I am requesting a way to hand an
already-baked mesh `Content` to a `MeshPart` without paying that cost on the main thread.

## Background

I maintain a runtime voxel terrain engine built entirely on `EditableMesh`. The per-chunk pipeline is:

1. Cull the chunk's voxels into a triangle list (pure Luau).
2. Fill an `EditableMesh` and bake it:
   `AssetService:CreateDataModelContentAsync(Content.fromObject(editableMesh))` → immutable `Content`.
3. Turn that `Content` into geometry:
   `AssetService:CreateMeshPartAsync(bakedContent, {CollisionFidelity = ...})` → `MeshPart`.
4. `existingPart:ApplyMesh(newPart)` to swap geometry into the persistent per-chunk part, then destroy
   the temporary part.

## Measurements (my project, play mode, fresh distinct meshes, linear fit over triangle count)

| Step | Cost |
|---|---|
| `CreateDataModelContentAsync` (bake) | ≈ **7 ms fixed** + 3.6 ms per 1k triangles |
| `CreateMeshPartAsync` (apply) | ≈ **22 ms FIXED** + 0.27 ms per 1k triangles (essentially flat) |
| `MeshPart:ApplyMesh(src)` | ≈ **0.01 ms** (free) |

So a ~1k-triangle chunk costs roughly 11 ms to bake and **22 ms to turn into a MeshPart** — the apply
step dominates, and it does **not** shrink as the mesh shrinks. At 60 fps the entire frame budget is
16.7 ms, so a single `CreateMeshPartAsync` blows the frame on its own.

## Why this cannot currently be worked around

I have tried each of these and hit a wall:

- **Parallelism / Actors.** `AssetService` is not usable from a parallel context. I already moved the
  pure-Luau cull (~21 ms/chunk, ~27% of per-chunk cost) into a worker `Actor` pool successfully — that
  part parallelizes fine. The two `AssetService` calls cannot follow it; they must run on the main
  thread and they block it.
- **`ApplyMesh` with a `Content`.** `MeshPart:ApplyMesh()` requires another **`MeshPart`** as its
  source. It rejects a `Content`. Since the only way to obtain that source `MeshPart` is
  `CreateMeshPartAsync`, `ApplyMesh` being free does not help — the 22 ms is already spent producing
  its argument.
- **Assigning `MeshPart.MeshContent` directly.** This is script-write-gated: assigning it raises
  *"The current thread cannot write 'MeshContent' (lacking capability)"*, the same way `Script.Source`
  is gated. This is the single most natural workaround and it is closed off.
- **Making meshes smaller.** Because the cost is *fixed per call*, splitting a chunk into smaller
  meshes makes things strictly worse (more calls × 22 ms). I verified the inverse too: larger 32³
  chunks reduce call count but every other per-chunk cost is volume-bound, so total spikes got far
  worse (p99 ~235 ms vs ~38 ms at 16³).
- **Time-slicing.** The call is atomic from Luau's perspective; it cannot be split across frames.
- **Caching/reuse.** Works only for repeated identical geometry. Terrain chunks are unique and change
  on edit, so there is nothing to reuse.

Net: after moving everything movable off the main thread, `CreateMeshPartAsync` is the irreducible
remainder and the sole cause of the residual hitch when streaming or editing terrain.

## Request

Any **one** of the following would solve it (listed in order of preference):

1. **Make `MeshPart.MeshContent` assignable from a normal script context** when the value is an
   immutable `Content` previously produced by `CreateDataModelContentAsync`. The content is already
   baked and validated at that point; this would let `ApplyMesh`-style geometry swaps cost ~0 ms.
2. **Let `MeshPart:ApplyMesh()` accept a `Content`** in addition to a `MeshPart`, with the same
   semantics as today (in-place geometry swap, keep transform/Size).
3. **Provide a parallel-safe / non-blocking variant of `CreateMeshPartAsync`** — either callable from
   an `Actor` in parallel, or one that yields while the expensive work happens off the main thread and
   resumes with the finished `MeshPart`.

Option 1 or 2 is preferable because the expensive work (validation, GPU-resident mesh creation) has
arguably already been done by `CreateDataModelContentAsync`; the second call appears to redo it.

## Impact

This is the difference between "runtime `EditableMesh` geometry is viable for streaming worlds" and
"it is not." With a ~0 ms apply path, a chunk rebuild would drop from ~33 ms to ~11 ms and would fit
inside a frame. Every category of experience that builds geometry at runtime — voxel/blocky terrain,
destruction, procedural generation, user-generated building tools, marching-cubes/CSG systems —
benefits directly.

## Notes for the reader

- All numbers above are from my own profiling in play mode, not Studio edit mode.
- `CollisionFidelity.Box` is the cheapest fidelity; `Default`/`Hull` add roughly another 10 ms. The
  ~22 ms figure is with `Box`, i.e. the floor is not collision-geometry generation.
- Happy to supply a reproduction place file on request.
