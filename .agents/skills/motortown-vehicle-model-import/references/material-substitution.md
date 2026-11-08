# Making an imported mesh render with its own textures

Goal: a third-party model whose colours live in a base-colour **texture** (glTF palette atlas) should
look like the model in game, without shipping a custom `Material`.

## What does not work (both verified in game, same visible result)

- **Imported glTF material as-is.** The Interchange material instance parents to
  `/InterchangeAssets/gltf/MaterialInstances/MI_Default_Opaque`, editor-only → default checker.
- **Repointing that instance's `Parent` at a vanilla material** (`/Game/Cars/Materials/Body/M_Body`).
  The write succeeds and the import table verifies, but the cooked instance carries a static shader map
  compiled for its original parent, so the game still draws the default checker.
- **Authoring a `Material` in your own project and cooking it into the pak.** The asset cooks (shader
  map and all, ~16 KB `.uexp`) but its shaders reference library entries the shipped game does not
  carry → default checker again.

Diagnostic signature for all three: the body is solid and correctly shaped, but the surface is uniform
fine speckle. That is the engine default material. Do not go looking at UVs, textures or normals.

## What to do instead: rebind a vanilla instance

A `MaterialInstanceConstant` whose **parent is a vanilla material** renders, because the parent's
shaders ship with the game; only parameters differ. So:

1. Find a vanilla MIC whose parent samples a base-colour texture. `MI_PolygonTown_Master`
   (`/Game/PolygonTown/Materials/`) is one: texture parameters `BaseColor`, `Metallic`, `Normal`,
   `Roughness`, static switches `Use_MetallicTexture`, `Use_NormalTexture`, `Use_Roughness`,
   `Use_RoughnessTexture`, `Use_Wind`, scalars `GrassBendingDistance`, `Power`,
   `RefractionDepthBias`, parent chain `MI_PolygonMaster` → a vanilla `Material`. Its children
   (`MI_PolygonTown_01_A`) are 66-byte empty instances, so clone the **master**, not the child.
2. Cook your texture into the same package folder the material ships in. A 64×64 palette PNG is fine;
   import it with `srgb=True` for colour data and `srgb=False` for metallic/roughness data.
3. Rename-clone the MIC into the path the mesh's material slot already points at, so the mesh needs no
   edit at all:

```bash
# clone config: {"old_name":"MI_PolygonTown_Master",
#                "new_name":"M_<Mod>_Body",
#                "new_path":"/Game/Cars/Models/<V>/M_<Mod>_Body",
#                "import_replacements":[]}
bash uasset.sh --clone-asset clone_cfg.json MI_PolygonTown_Master.uasset out/
# → prints Written: .../M_<Mod>_Body.uasset + .uexp, FolderName = the new full object path
```

4. Rebind the parameters with `--set-mi-params` (config: `inDir`, `outDir`, `instances.<stem>` with
   `textures` / `scalars` / `static`, optional `parent`):

```json
{"inDir":"clones/", "outDir":"final/",
 "instances":{"M_<Mod>_Body":{
   "textures":{"BaseColor":{"pkg":"/Game/Cars/Models/<V>","name":"T_<Mod>_Base"}},
   "static":{"Use_MetallicTexture":false,"Use_NormalTexture":false,"Use_RoughnessTexture":false}}}}
```

5. Ship the clone at its path plus the cooked texture; drop the custom `Material` and any
   metallic/roughness texture you are not binding.

## Tool constraints worth knowing

- `--set-mi-params` handles **textures, scalars and static switches only — no vector parameters**, and
  it binds by *cloning an existing entry* of that type. An instance with no `VectorParameterValues`
  entry cannot gain one, so a flat colour cannot be injected this way even when the parent exposes a
  `Color` vector parameter (`M_Body` does: `Color`, `Metallic`, `Roughness`, plus decal parameters).
- Every bound parameter prints as `tex=N scalars=N statics=N` on success; `SKIP ...: no <type> entry to
  clone for <name>` means that instance lacks an entry of that type and the bind silently did nothing.
- `--clone-asset` on a MIC is a rename-only operation and is safe; the cooked `.uexp` is carried
  verbatim (it grew slightly here only because of the texture import added to the table).

## Confirmed in game

The `MI_PolygonTown_Master` route works: with `BaseColor` rebound to the model's palette texture and
`Use_MetallicTexture` / `Use_NormalTexture` / `Use_RoughnessTexture` switched off, the body renders the
palette instead of the checker. Shading is flat and stylised, as expected from a town-prop master —
which suits a low-poly car but is not car paint; if the user wants gloss, the open question is whether a
vanilla *vehicle* master (`M_Body` or a car-specific MIC) exposes a usable texture parameter. Check its
name map for `TextureParameter` entries before planning the build.

## Un-painting the interior: it renders in body paint

Both `M_<Mod>_Body` and `M_<Mod>_Interior` descend from the polygon master, and that master takes its
colour from the **vehicle paint** system — so every generated interior panel (dash, door cards, seats,
wheel) comes out in body colour. On screen that reads as a geometry fault: "a white thing is blocking
the bottom of my gauges", or a cockpit that merges into the bodywork.

Two dead ends before you start: `--set-mi-params` cannot inject a flat colour (it binds by cloning an
existing `VectorParameterValues` entry and a polygon instance has none), and repainting the base-colour
texture does nothing because the paint tint is applied above the texture sample.

Working route — repoint the interior instance's `Parent` at a vanilla **non-paint** material:

```json
{"output_filename": "M_<Mod>_Interior",
 "exports": [{"export_name": "M_<Mod>_Interior",
   "patches": [{"op": "set_or_create_import_ref", "path": "Parent",
     "class_package": "/Script/Engine", "class_name": "Material",
     "package_path": "/Game/Cars/Materials/Body/M_Gray", "asset_name": "M_Gray"}]}]}
```

```bash
bash uasset.sh --patch-named-exports mi_gray.json mifinal/M_<Mod>_Interior.uasset out/
```

- The config must be `{"exports":[{export_name, patches}]}`; a top-level `patches` array is rejected
  with `Config must have 'exports' array`.
- `--patch-named-exports` writes a MIC cleanly — the schema failure described in the SKILL.md is a
  *blueprint* problem, so do not fall back to a float patch for a material.
- **No cook.** Material assets travel as assets; ship the patched `.uasset|.uexp` over the old instance
  and rebuild the pak.
- Parameter entries inherited from the polygon parent (`BaseColor`, `Metallic`, `Normal`, `Roughness`,
  the `Use_*` switches) simply stop resolving against the new parent. Leave them; they are ignored.
- Available greys are a fixed menu, not a colour picker: `M_Gray`, `M_Body_Bottom`, `M_Wire`. A specific
  colour needs a vector parameter the chosen parent actually exposes — check its name map first.

Verify on the patched asset: the `Parent` import names `M_Gray` and its `Package` import reads
`/Game/Cars/Materials/Body/M_Gray`.

## Sequencing trap: winding looks like a material bug

Once a real material is on the mesh, a mesh with reversed winding shows only its interior faces — which
reads as "the paint is see-through" or "the material is wrong" and sends you back into the material
chain. It is geometry: the default checker material is two-sided, so the same mesh looked solid minutes
earlier. Before touching materials again, run the winding check in the SKILL.md "Facing" section; the
numbers (winding direction vs vertex normals) settle it in one pass and the fix is a single global
reversal plus one re-cook.
