---
name: motortown-vehicle-model-import
description: "Use when importing a 3rd-party car mesh into Motor Town."
metadata:
  hermes:
    tags: [motortown, unreal, vehicle, mesh, gltf, import, pak]
    related_skills: [motortown-pak-mod-build, unreal-mod-pak-envelope, motortown-vehicle-gltf-extract, motortown-character-modding, motortown-vehicle-tuning]
version: "2026-11-06"
author: yumemi
license: internal
---

# Importing a third-party vehicle mesh into Motor Town

## When to Use

- The user hands over a car/truck/bike model (Sketchfab zip, GLB, FBX, OBJ) and wants it in game.
- "Can we add this car?", "what format do you need?", "jork this model into Motor Town".
- Any new-vehicle work that needs a mesh, as opposed to a data-only vehicle variant.

Adding a new vehicle, as opposed to extracting one (`motortown-vehicle-gltf-extract`) or building a
data-only pak (`motortown-pak-mod-build`). Vehicles are **static mesh components on a blueprint**
(`MHWheelComponent` per wheel), not skeletal — no rigging step, which makes this materially easier
than `motortown-character-modding`.

## Order of work (do not reorder)

1. **Licence first.** Sketchfab zips carry `license.txt` beside `scene.gltf`. Read it before one build
   is spent: CC-BY / CC0 / commercial matters on a public server, CC-BY owes a credit line in the mod
   README and ideally the in-game description, and a ripped model should be flagged now rather than
   after the cook.
2. **Inventory the archive** before converting — node names, triangle counts, material count, texture
   sizes. Wheels must arrive as **separate nodes**; a welded body+wheels mesh needs hand-splitting in
   Blender before anything else works.
3. **Prepare one GLB per part for UE's importer** — split body and wheels into separate files, wheels
   pivoted at their hubs, and feed **raw glTF metres with the axes reordered**, not pre-converted
   centimetres (see the importer section; baking the conversion double-applies it).
4. **Pick the donor vehicle** — ideally the same real car the model depicts, so body, suspension and
   parts clone sensibly. `motortown.info/vehicles` lists every vanilla vehicle with its real-world
   counterpart; the AMC wiki `vehicle_comparison` page carries mass, drivetrain and level.
5. **Read the donor's wheel ground truth** out of the extracted pak (recipe below) and compare it to
   the imported mesh. This comparison decides the build; do it before opening the editor.
6. **Cook on the Windows cook host** at the engine version the live game runs: import one static mesh
   per part, verify triangle counts and bounds against the source, disable Nanite, cook from a
   throwaway map holding the meshes. **Import each mesh straight into the package path it must ship
   at** (`/Game/Cars/Models/<Vehicle>/Body`, `/Game/Cars/Parts/Wheels/<Part>_L|R`) so the cooked
   output is already pak-ready — see "Never re-serialize a cooked static mesh". Then add **data rows,
   not blueprint bytes** — clone the donor row
   into the child table and clone the donor's wheel **part** row with your own wheel meshes (see "Where
   the meshes actually live" and "Blueprint bytes cannot be written"). Build the pak following
   `motortown-pak-mod-build` and the envelope rules in `unreal-mod-pak-envelope`.
7. **Verify by extracting the assets back out of the built pak**, then client + server install — both
   sides need the pak, a client without it cannot see the vehicle.

## Convert: glTF (Sketchfab, Y-up metres) → UE (Z-up centimetres)

The target is a pure rotation, no mirroring: `UE = 100 * (gz, gx, gy)` — glTF +Z (model front) becomes
UE +X (forward), glTF +Y (up) becomes UE +Z. Sketchfab wraps the scene in **two opposite ±90° X
rotations** (`Sketchfab_model` then `GLTF_SceneRootNode`) that cancel; convert from the original glTF
axes and ignore the wrapper, or the result comes out double-rotated.

**Do not bake that formula into the GLB.** UE's Interchange glTF importer does not do a Y-up→Z-up
rotation: it maps `ueX = glTF_x`, `ueY = glTF_z`, `ueZ = glTF_y` and scales by 100. Hand it metres
with the components pre-swapped as `fed = (src_z, src_y, src_x)` and the importer's own mapping
produces the formula above. Feeding already-converted centimetres applies the swap a second time —
the model arrives 100× too large and lying on its side (a 464 cm car reports a 23,189 cm extent),
while feeding plain raw glTF puts its length along Y. Verify by bounds after import: a car should
read length on X, width on Y, height on Z, in centimetres.

## Facing: check winding before the first cook

A Sketchfab-style asset usually declares `doubleSided: true`, which means the artist never had to keep
face orientation consistent — and it is often reversed **globally**. That stays invisible while the car
renders with the engine's default material (the fallback checker is two-sided) and appears the instant a
normal one-sided material goes on: the outside vanishes and you see the underside of the bonnet, the
floor pan and the interior, reported as "only the inside of the model shows".

Measure, never eyeball. For each triangle compare two directions against the vector from the mesh
centroid: the geometric normal from the winding (cross of two edges) and the average vertex normal. If
the counts are roughly complementary — e.g. 1090 faces winding-inward while 1090 of 1690 vertex normals
point outward — the winding is uniformly reversed and the fix is to reverse **every** triangle, not to
flip the ones that look wrong. Reverse the index pairs in the source GLB (rewrite the index buffer in
place, same file size), re-import, re-cook. Flipping per-face by centroid heuristic is wrong: concave
regions legitimately face inward, and a majority-inward count misleads.

The same check applies to procedurally authored geometry you add (a cockpit primitive): it is authored
in the same GLB and inherits the same reversal, so assert its winding before cooking rather than
assuming your generator got it right.

**Do not flip the whole file when only the body is reversed.** The flip operates per primitive: flip the
body primitive only, and leave your authored interior alone. Flipping both turns an outward-wound
interior inside out, so every panel is culled from the cabin and the donor gauge cluster appears to
float in an open shell ("no seats, no dash, no wheel, you can see the street around you"). That reads
exactly like a deleted interior and is a winding sign error.

**Better: stop reasoning about facing for authored geometry — emit it double-sided.** A procedurally
generated primitive costs nothing to duplicate (`INT = np.concatenate([INT, INT[:, ::-1]])`), and the
result renders from either side, which retires the whole invisible/inside-out/mirrored class of bug in
one step. 684 extra triangles is cheaper than another cook cycle per guess.

**But do not double-side the BODY shell to close the cabin.** Doubling the body duplicates every panel
of the whole car (1,690 → 3,380 triangles, `Body.uexp` 293 KB → 474 KB), draws every panel twice, and
reads as murkier rather than enclosed. What the user is actually asking for is *not to see the street
through the roof and doors* — the cheap answer is a handful of panels in the authored interior
primitive: a headliner under the roof peak, a parcel shelf behind the rear bulkhead, and the door cards
and floor that are usually already there. That is ~48 triangles against 1,690 duplicates. Reach for
body double-siding only when individual panels are visibly missing and you cannot name them.

## Wheels: override the wheel ASSET (confirmed on screen)

Rename a donor wheel package into the wheel path the vehicle already references (`--clone-asset`,
`new_path=/Game/Cars/Parts/Wheels/Spider_L`, `new_name=Spider_L`) and ship
`Cars/Parts/Wheels/Spider_L.uasset|uexp`. Donor geometry renders and the donor's collision travels with
the rename, so the car drives. Then set the wheel components' `RelativeScale3D` to the **target
diameter in metres** — donor meshes are authored ~1.0–1.1 m and the host's factor was tuned for its own
mesh (a 74.6 cm wheel needs `0.746` on a 1 m mesh, `0.70` on the Tuscan's ~1.07 m one).

Two routes that write cleanly and change **nothing in game**: repointing `Wheel0..3`'s `StaticMesh` in
the blueprint, and patching the base `VehicleParts` row (the mesh is resolved from parts data at
runtime). Wheel components also generate no collision headless, so imported wheels give "won't drive,
spinning tyres screeching" — vanilla donors bring theirs. Full route comparison, donor dimension table,
corner mapping and the scale-convergence trick: `references/wheel-substitution.md`.

Run `scripts/gltf_to_ue.py <dir-with-scene.gltf>`: it prints a per-part table (tris, hub, size) plus
derived length/width/height, wheelbase, track and wheel radius, then writes `<Model>_MT_UE.glb`.

**Mixed-source assemblies are where this bites twice.** When one primitive comes from the source glTF
(already fed metres) and another is authored by you in UE centimetres (e.g. a procedural interior),
only the authored one needs converting. Running the source primitive through the same UE→fed helper
permutes it a second time *and* divides by 100, so the car imports at **1/100 scale**: the body becomes
a 4.6 cm sliver next to a correctly-scaled interior. In game that reads as "only the interior of the car
loaded", and the wrecked vehicle asset also stops the showroom populating and breaks the dealership's
entry trigger — it looks like a broken pak, not a scale mistake. The same mistake in the other
direction (dividing an already-metres source vector) leaves the car readable in bounds but still wrong.
Always assert post-import bounds in cm (body ≈ ±232 × ±92.9 × 25.4…135 for a 4.6 m car) rather than
trusting a triangle count, which is identical either way.

Treat that GLB as a **preview/measurement artifact** — it is already converted, so it is the wrong
input for the importer. For the import, split the parts and emit raw metres with axes reordered
(`fed = (src_z, src_y, src_x)`, `scripts/split_glb.py` in the project dir does this per part).
Needs numpy — `uv venv .venv && uv pip install --python .venv/bin/python numpy` (container has no pip
and no system numpy).

**A mesh node's transform lives on its PARENT.** Sketchfab nests
`Sketchfab_model > root > GLTF_SceneRootNode > Wheel_FL_0 > Object_6`, with the mesh on the leaf and
the translation on the node above. Reading each mesh node's own `translation` returns zeros for every
wheel and every derived number (wheelbase 0, track 0) — accumulate the parent chain, as the script does.

## What a working replacement-vehicle pak contains

A pak that replaces a vanilla vehicle (ours replaced `Spider`) and is confirmed in game ships exactly:

```
Cars/Models/<V>/Body.uasset|uexp          # our body, cooked straight into the target path
Cars/Models/<V>/M_<Mod>_Body.*            # paint instance: clone of a VANILLA MIC, texture rebound
Cars/Models/<V>/M_<Mod>_Interior.*        # interior material
Cars/Models/<V>/<Blueprint>.uasset|uexp   # float-only patch: wheel hub positions + scale
Cars/Parts/Wheels/<V>_L|R.uasset|uexp     # donor mesh renamed into the vehicle's wheel package
DataAsset/StringTables/VehicleName.*      # display-name splice
```

That is ~12 files, ~440 KB. Anything else in the pak is a variable you did not intend to test. Note the
split: meshes arrive by path, the blueprint by same-size float patch, the wheels by rename, the name by
byte splice — **no single mechanism covers this job**, which is why bisecting beat guessing.

## Where the meshes actually live (read before planning the patch)

- **Body** is the blueprint component named `Mesh` (`StaticMesh = /Game/Cars/Models/<V>/Body/Body`).
  The component named `Body` is the `MTVehicleRootComponent` root and serialises **no** properties —
  patch `Mesh`, or you edit nothing and get a clean-looking run that changed nothing.
  **That `.../Body/Body` notation is package+object, not a directory pair.** The asset's `FolderName`
  is the full object path `/Game/Cars/Models/Spider/Body` and its file is
  `Cars/Models/Spider/Body.uasset`. Staging the override at `Body/Body.uasset` yields package
  `/Game/Cars/Models/Spider/Body/Body`, matches nothing, and the engine silently keeps the vanilla
  body while blueprint-bytes patches still apply — the symptom is "wheels moved, body did not load",
  which reads like a broken mesh import and is really a path mistake. Wheels are the same shape:
  `Cars/Parts/Wheels/Spider_L.uasset`. Confirm the file name with
  `bash mtextract.sh MotorTown/Content/Cars/Models/Spider/Body`, which writes `Body.uasset` — that is
  exactly how the pak must name it. For `--clone-asset`, `new_path` is the full object path and
  `new_name` the object name.
- **Wheels are not effectively on the blueprint.** They are *declared* on the VehicleParts row the
  vehicle's `Parts` map points at (`EMTVehiclePartSlot::Wheel0..3 -> "<part>"`, `PartType: Wheel`,
  `Wheel.LeftWheelMesh` / `RightWheelMesh` / …), and the mesh is resolved from there at runtime — which
  is why a blueprint mesh swap, and a whole-base-table row edit, both change nothing on screen. The
  working route is to rename a donor wheel package into the path the vehicle already references; see
  "Wheels: override the wheel ASSET". Read both places for ground truth, edit neither.
- **Most cars leave `RearLeftWheelMesh`/`RearRightWheelMesh` as `None`** — the Left/Right meshes cover
  all four corners. When that is the case, a *replacement* pak needs only those two wheel mesh assets
  overridden: no part row clone, no DataTable write. Check the donor's part row before planning rows.
- **An in-game wheel set is the cheap, drivable option — and often the right one.** Imported wheel
  meshes carry no collision, and the wheels are what touch the road, so a car on them will not move.
  Substituting an existing wheel row whose real tyre matches the model's wheel size costs no mesh work
  and brings collision with it: match by dimension, then clone the part row. Recipe, donor table and
  the symptom table in `references/wheel-substitution.md`.
- **Display name lives in `DataAsset/StringTables/VehicleName`**, keyed by **blueprint name**
  (`Spider`), value is the shop/UI name. There is no `<RowName>_VehicleName` key and the real car's name
  appears nowhere in that table or in `locres/en/Game.locres` — the donor wears its blueprint name
  in-game, so check the table before telling the user it is "still called <real car>". **The asset
  writers cannot touch it**: a StringTable export carries zero properties (entries are
  custom-serialised), so splice the `.uexp` and bump that export's `SerialSize` by the length delta —
  recipe in `references/uasset-tool-write-path.md`.
- **Vehicle rows** live in `DataAsset/Vehicles/Vehicles` (master) plus `Vehicles_1` (child); the game
  loads both. Vanilla RowNames are often **numeric** — the C7 is RowName `"4"` with `VehicleName
  "4_VehicleName"` and blueprint `Spider`. Never look for a row named after the blueprint.
- Adding a vehicle = one row in the child table cloned from the donor. The fields that must change are
  `RowName`, `VehicleName` and `VehicleClass {package, asset}`; the body slot's default part is the
  generic `DefaultBody`, which carries no mesh — that is why the blueprint component is the only body.

## Blueprint writes need the parent schema beside the asset

`Mappings.usmap` ships **C++ classes only**. Cooked component exports serialise their unversioned
property header by name index and need the *parent blueprint class* schema, so writing aborts with
`Failed to find a valid schema for parent name MTVehicleBaseBP_C`. Retrying with different flags does
not fix it — the fix is to supply the schema: extract the parent blueprint from the pak and put it in
the same working directory as the asset you are patching.

```bash
# the parent path is the blueprint's own Package import (e.g. /Game/Cars/MTVehicleBaseBP)
bash mtextract.sh MotorTown/Content/Cars/MTVehicleBaseBP
mkdir -p bpwork && cp Spider.* MTVehicleBaseBP.* bpwork/     # target + parent side by side
bash uasset.sh --patch-named-exports cfg.json bpwork/Spider.uasset out/
```

With the parent present the same `--patch-named-exports` run that aborted now writes cleanly, and it can
change **structural** things the float patcher cannot — including mesh references (see the wheel
substitution reference). The failure is not a property of the asset, it is a missing sibling file, so a
`strings Mappings.usmap | grep -x <BPClass>_C` probe is still the right pre-flight but no longer means
"unwritable".

**But it can also abort with the identical message on an asset that patched fine before** — same file,
same mappings, `Patched 3 exports.` printed, then the schema exception, and the output directory stays
**empty**. Never trust the "Patched N exports" line: check the output dir is non-empty and the `.uexp`
round-trips before staging. When it does abort, don't chase flags — fall back to
`scripts/patch_bp_vectors.py` (float64 in-place), which needs no schema at all.

Only a genuinely **new** blueprint (a new class, not a new value in an existing one) still needs editor
authoring with the game's BP parents available, or synthesised BP schemas in the usmap. Prefer a
DataTable-only route over a blueprint edit when the change is pure data.

## Editing a blueprint you cannot write: patch the floats in place

The writer needs a schema; the *bytes* do not. UE5 large-world `FVector` is three float64 contiguous
in the export's serial data, so any `RelativeLocation` is rewritable in place — same property, same
size, header untouched, no schema involved. This is the cheapest way to move wheels, lights or mirrors on
a cooked blueprint. Changing a **mesh reference** is also writable, but not this way — that is an import
table edit and needs the parent schema present (`--patch-named-exports`, see above). Adding or removing
components, openables and gauges remain structural: those still need editor authoring, so the asset has
to arrive by overriding an existing package instead.

Runner: `scripts/patch_bp_vectors.py <cfg.json>` — require **exactly one hit per pattern** (refuse on
0 or >1), patch a copy, then assert unchanged length and re-read the triples. Offsets are relative to
the combined stream (`uexp_off = SerialOffset - len(<Vehicle>.uasset)`), values are centimetres in
vehicle-local space (`+X` forward, `+Y` right, `+Z` up), and exports with a `SerialSize` around 10
bytes carry no vector at all. Full recipe and pre-flight checks:
`references/blueprint-float-patching.md`.

## Never re-serialize a cooked static mesh — cook it into the target path

The in-place float patch above is safe because it preserves size *and* header. **A full
re-serialization of a cooked static mesh is not.** These assets carry bulk render data (LOD
resources, position/index buffers, body setup, nav collision) and the byte writer round-trips
properties round-trips property headers, not that payload. **A rename-only clone of a vanilla mesh is
the one exception that works** — the name map changes and the mesh payload is left alone (the wheel
clone kept its `.uexp` at 49,056 B and rendered correctly in game). What breaks is anything that
round-trips the mesh payload, which is what happens to an Interchange-imported mesh.
`--clone-asset` on a cooked mesh appears to work — it prints
`Written:`, the file sizes look plausible, the pak builds, and `mod_explore` lists every entry —
but the mesh is invalid in game.

Failure signature, all at once: the overridden body draws nothing while geometry *inside* it still
renders, the dealership does not populate around the car, an interior trigger or door stops
working, and the player rubber-bands as the streamer stalls on the bad asset. Four symptoms that
read as unrelated bugs and are one bad mesh.

Correct route: put the mesh where it must end up **at import time**. Set the Interchange task's
`destination_path` / `destination_name` to the game's own package
(`/Game/Cars/Models/<Vehicle>/Body`, `/Game/Cars/Parts/Wheels/<Part>_L|R`), cook from the throwaway
map, then copy the cooked `Content/Cars/...` tree directly into the pak staging dir. The cooked
output path **is** the pak entry path, so nothing needs retargeting and no mesh touches the writer.
The only byte-patched asset is the blueprint, and that patch is same-size.

Before blaming anything else for a broken game, remove the pak and confirm recovery. A pak whose
meshes went through the writer must not be handed over as "tested" — and if any were rewritten, say
so explicitly in the handover.

Handover discipline: one change per test cycle. When the user says they will test first, stop — do
not bundle a rename, a tuning tweak or a second fix into the same pak, or a bad result cannot be
attributed to anything. **Unless he has pinned the filename for a tweak series, never overwrite, rename or rebuild under the name of a pak already handed
over** — each iteration is a new file, so the user always tests exactly what he thinks he is testing
and can tell old from new. A pinned name is the one exception — rebuilding in place is deliberate when builds are
being tweaked in quick succession. **The name must end `_P.pak`** — UE only mounts patch paks carrying
that marker, so a request to "call it `Barracuda_dash`" ships as `Barracuda_dash_P.pak`, and say so
rather than silently adding or dropping the suffix. If the requested name already exists, move the old
file aside (`<name>_v<N>_archived_P.pak`) and put the new build at the asked-for name — never overwrite
and never refuse the name; the user is managing which files he drops in, not the bytes. The cook host is usually the user's own desktop, so say what a cook will
cost them before starting one, and do not start one while they are mid-test. When symptoms pile up
(no body, no collision, won't drive), stop fixing and **bisect**: ship the smallest pak that can
discriminate — shell only, vanilla wheels, vanilla blueprint — so one test separates "bad mesh" from
"bad blueprint edit" instead of guessing across several changes at once.

Housekeeping when the user asks for a cleanup: scratch is shared with unrelated projects (one map
project can account for nearly all of the disk), so delete only **your** artifact trees — the superseded
staging dirs, cooked trees, blueprint dirs and throwaway configs for this vehicle — and leave everything
else alone. Move superseded paks into an `archive/` subdir rather than deleting them; report the real
numbers (what was big, what was yours) instead of implying you freed the bulk of the space.

Diagnostics are visual: the shipping client writes no UE log — `%LOCALAPPDATA%\MotorTown\Saved\Logs`
contains only Coherent `cef3` logs — so engine material/asset errors are simply not available. Ask for
an in-world screenshot (not the dealership hologram, which is a preview material and looks broken by
design) rather than requesting a log. **Open every screenshot with the vision tool before answering** —
diagnosing from the one-line caption is wrong often enough to be a rule, and the user expects evidence
that the image was actually looked at. Ask it where a part sits in frame, what occludes it, and whether
it is cut off: those three answers pick the fix (height vs X vs a panel in the way) without a cook.
**Trust it for what is in frame, not for what things are.** Screenshot descriptions regularly
misidentify the game and the car and invent a confident explanation for a surface (a flat grey panel is
called a door card, a building wall, a rendering bug); repeating such a guess as fact earns "what the
hell are you on about". Name the object only when geometry or a numeric check backs it — bounds, pixel
counts of a tinted render, or the mesh's own triangle occupancy — and otherwise ask which of two
candidates the user means.

**The reference model sets the shape; the vanilla game sets the behaviour.** When a visual detail comes
back wrong and the ask is "I want it like every other car in the game", the target is what vanilla
vehicles do — their materials, their camera, their glass — not the source mesh's flat art. Matching the
reference model's painted-on look can satisfy the eye and still be the wrong answer, so say which one a
proposed change aims at before spending a cook. And once one detail has been round-tripped three times,
restate the goal in a single sentence and get it confirmed ("dark from outside and see-through from
inside") before the next build — iterating blind is what turns one complaint into five.

**"Is anything broken on our model?" is answered by diffing material slots, not by eye.** Read the
vanilla body mesh's slot table straight out of the cooked asset (`strings Body.uasset | grep -E
'^/Game/|^M_'`) and compare: vanilla cars carry `M_Body` (paint), `M_Glass_Base` + `M_Internal_Glass`,
four lamp materials (`M_HeadLight`, `M_TailLight`, `M_TurnSignalLight`, `M_ReverseLight`) and
`M_Palette`. Each missing slot is a lost function, not a cosmetic gap — no lamp slots means headlights
and indicators stay body paint and never light or switch, a private paint MIC instead of `M_Body` means
resprays do nothing, and no palette plus zero UVs means every authored face samples one texel, which is
why colour swaps keep coming back "still flat". Report the diff as capability gaps plus the cheapest
in-game test for each, and pair it with the non-material ones (collision still the donor's, no
replaceable part meshes, seat/mirror counts inherited). Procedure, verified Tuscan slot table and the
row-lookup-by-`VehicleClass.package` trick: `references/vanilla-parity-audit.md`.

Uploads to the cook host must be staged under `/opt/data/`: `win_put.sh` resolves the
source path on the *host* (the same `/opt/data` tree), so a path the container can see but the host
cannot fails with `SRC_NOT_ON_HOST`. `win_run.sh` is the opposite shape — it takes a **local** script
path and base64-encodes that file's contents into the remote command line, so passing it a
`D:/...ps1` host path produces a PowerShell usage dump instead of running anything. Create the remote
directory first (a `New-Item -Force` one-liner through `win_run.sh`) before uploading into it, and
prefer one small `.ps1` per job over editing existing ones — a re-import run also overwrites the
editor's material instances, so keep import, material patching and cook as separate runner scripts
in that order.

## Donor wheel ground truth (the decisive step)

The extracted pak already carries every vanilla vehicle blueprint, parsed:

```
mt-pak-extract-wt-<ver>/out/<Vehicle>_parsed.json
  Data.Exports[] where ExportName starts with "Wheel"   (class MHWheelComponent)
    Properties.RelativeLocation.RelativeLocation -> {X, Y, Z}    # cm, vehicle-local
```

Four entries give wheelbase (`X_front - X_rear`), track (`2 * |Y|`) and hub height (`Z`) directly.

**Rule: move the wheels, not the mesh.** Vanilla MT cars are deliberately wider-tracked and
longer-wheelbase than the real cars they depict (the `Spider`, a 2014 Corvette C7, sits at 298 cm
wheelbase / 196 cm track against the real car's 271 / 161). A dimensionally honest imported model
will look inboard and short next to its donor. Once you have a blueprint you can author, set
`Wheel0..3.RelativeLocation` to the imported mesh's own hub values and leave the body at true scale;
uniformly scaling the body to reach the vanilla track stretches length by ~20% and reads as a limo.

If the blueprint is one you **cannot** write (see the wall above), the donor's stance wins: hub
positions and the 0.79-ish vanilla wheel scale are fixed, so a dimensionally honest body will show
wrong arch alignment. Do not paper over it with per-wheel mesh offsets baked into the wheel geometry —
the wheel spins about its axle, so any offset with a component off that axis wobbles. Either author
the blueprint properly or say plainly that the stance will be wrong.

## Pitfalls

- **The pak needs a `MotorTown/Content/` prefix under the `../../../` mount.** `mod_pack`'s default
  mount is `../../../` and it does *not* add the project folder, so staging `Cars/...` at the root of
  the input dir produces entries like `Cars/Models/...` that the game silently ignores. Stage
  `<input>/MotorTown/Content/Cars/...`. Confirm against a known-good shipped mod pak with
  `mod_explore` (expect `Mount point: ../../../` and `MotorTown/Content/...` entries) before shipping.
- **A floating interior has to live inside the body mesh.** Adding a cockpit component needs a BP
  write (blocked above), so build the interior as a second primitive with its own dark material on the
  body static mesh — dashboard, binnacle, console, door cards, bucket seats with bolsters and
  integrated headrests, steering wheel on a column that penetrates the dash. Check the signed volume
  of the generated soup is positive (outward winding) and that seats clear the console before cooking.
- **Anything whose shaders did not come from the game renders as the default checker.** The signature
  is uniform fine speckle that reads as "static noise" over an otherwise solid body — that is the
  engine's default material, not a bad texture, a UV problem or a broken mesh. Three mechanisms, all
  seen on one build: (a) the glTF importer parents each imported material to
  `/InterchangeAssets/gltf/MaterialInstances/MI_Default_Opaque`, an editor-only asset the game cannot
  resolve; (b) repointing that instance's `Parent` at a vanilla material (e.g. `M_Body`) **writes
  cleanly, verifies cleanly in the import table, and still renders checker** — the instance was cooked
  with a static shader map for its original parent and that map is not valid for the new one; (c) a
  (c) a `Material` authored in your own project and cooked there also renders checker, because its shader map
  references shader-library entries the shipped build does not carry; (d) **a cloned instance whose
  internal package path still points at the folder it was cloned FROM**, while the pak mounts it
  elsewhere — the mismatch takes down the whole package's material table, so body *and* wheels go
  checker at once. Dump the clone and compare `FolderName`/`NameMap[1]` against its shipping path
  before believing anything else; the fix is `--retarget-package` (recipe in
  `references/glazing-and-extra-material-slots.md`).
  The safe shape is an instance of a **vanilla** parent, because the parent's shaders already ship: clone
  a vanilla `MaterialInstanceConstant` that samples a base-colour texture, rebind its texture parameter
  to your cooked texture, and ship the clone at the exact path the mesh's material slot already points
  at — then the mesh itself needs no edit. Recipe, parameter names and the parts not yet confirmed in
  game: `references/material-substitution.md`.
- **Paint is still a part-row job.** Garage colour selection is driven by
  `BodyMaterialNames`/`ColorSlots` on the part row, and the generic `DefaultBody` row carries **neither**
  — both maps are empty, so the picker has nothing to write to. A texture-driven material ignores paint
  entirely (it is not reading the colour parameter at all). Say this up front rather than letting the
  user discover an "unpaintable" car.
- **Two assets can share a basename across packages.** `Models/<V>/M_<Mod>_Body` and
  `Parts/Wheels/M_<Mod>_Body` are different files with different bytes. Copy, patch and stage cooked
  output by full package path, never by basename — a basename copy silently puts the wheel material in
  the body slot.
- **PowerShell `Compress-Archive` flattens directory separators, and `-Path <dir>\*` drops a level.**
  Extracting the cooked zip on Linux yields flat filenames with embedded backslashes
  (`Models\Spider\Body.uasset`), so `os.walk` sees one directory and a rel-path stage writes nothing (or
  raises `FileNotFoundError` on the copy). Rebuild the tree explicitly: `rel = name.replace('\\','/')`,
  prefix the `Cars/` level back, `makedirs(dirname)` before `copy`.
- **Interchange import produces no usable collision, and a headless editor cannot add any.** An
  imported mesh arrives with `get_simple_collision_count` `-1` and every section's collision disabled.
  In game the vehicle then will not drive and the body renders as stretched garbage — which reads like
  a corrupt mesh and is not. From a `-run=pythonscript` commandlet the repair is unavailable:
  `get_editor_subsystem(StaticMeshEditorSubsystem)` returns **None**, and the deprecated
  `EditorStaticMeshLibrary.add_simple_collisions` / `set_convex_decomposition_collisions` return `-1`
  / `False` rather than raising. So settle collision *before* importing (import options) or plan a
  one-off GUI pass — Collision → Add Box Simplified (or Convex Decomposition), Save — with the user at
  the keyboard, and never hand over a build without asserting that collision exists.
  The wheel-specific signature is worth memorising: body draws fine, wheels spin, tyres screech, and
  the car never moves — that is missing wheel collision, not a physics-row problem. Prefer an in-game
  wheel of matching size (`references/wheel-substitution.md`) over authoring collision headless.
- **Model the interior — and remember the donor blueprint carries its own.** Cockpit camera, functional
  dash gauges and adjustable mirrors are core to this game's feel; a hollow shell is visibly wrong the
  first time someone drives it. But a replacement vehicle inherits the donor's cockpit components too:
  dump the blueprint's export list and look for `SteeringWheel` (a `StaticMeshComponent`, e.g.
  `3Spoke_01`) and `Dashboard` (class `MTDashboard`) alongside `CockpitCamera`, `DriverSeat` and the
  mirror components. They are positioned for the donor's cabin, so on a smaller or lower body they can
  end up at vehicle origin — which is ground level, i.e. the wheel and gauges sit under the car and
  scrape terrain. Note that `SteeringWheel` and `Dashboard` carry **no** `RelativeLocation` (37-byte and
  412-byte exports: mesh reference, attach parent, gauge config), so `set_vector` on them silently
  changes nothing — but do not conclude the parts cannot be fixed: `Dashboard.DashboardMeshLocation` is
  a real vector property, and `null_ref` on `SteeringWheel.StaticMesh` deletes the stray wheel outright.
  `CockpitCamera` and `DriverSeat_GEN_VARIABLE` do carry vectors and move normally. Treat "duplicate
  cockpit parts in the wrong place" as a distinct fault from your own interior sitting low, and converge
  the eye point and the cluster **one number per test pak** — the donor cluster is a large panel that
  blanks the view when lifted to eye height, while the donor's high camera puts an authored wheel rim
  outside the vertical FOV. Component
  inventory, working config and the coordinate mapping from your authored interior:
  `references/cockpit-components.md`.
- **A "missing" authored steering wheel is usually a torus AXIS error, not a visibility problem.** In a
  torus generator `axis` is the ring's *normal*: `(sin 20°, 0, cos 20°)` is only 20° off vertical, so the
  ring lies flat like a pancake and shows a ~4 cm edge from the driver's eye — every build reads as "no
  steering wheel" while the geometry is present and correctly placed. The wheel must face the driver, so
  the normal needs a large X component: `(cos 20°, 0, −sin 20°)`. Sanity-check the generated block's
  bounds before cooking — a steering wheel rim must span roughly its own diameter vertically (a 37 cm
  wheel gives `Z ± 19.6 cm`); a Z extent of a few centimetres means flat, regardless of what the
  histogram of vertices suggests.
- **The rake SIGN decides whether the wheel reads inside-out.** `(cos 20°, 0, +sin 20°)` tilts the rim's
  top edge back toward the driver: the wheel shows its top nearest the camera and gets reported as
  "slanted, top towards the camera" / "flipped 180?". A real column descends toward the driver's chest,
  so the top rim must sit FARTHER away — the in-plane up vector gains +X, i.e. the normal gains `−sin`.
  Rotate the spokes about the wheel centre by the same angle (`rot_y(spokes, +20°, centre)`) or the flat
  spoke boxes poke through the raked rim, and put the single vertical spoke at **6 o'clock**: one at 12
  reads as an upside-down wheel to anyone who drives.
- **Cockpit part placement is judged on screen — compute the projection before cooking, not after.**
  With the eye at `(X_eye, Z_eye)` and a part `d = X_part - X_eye` ahead, its normalised vertical position
  is `sy = (Z_part - Z_eye)/d`, and the frame edge is about `±0.5` for a 55–60° vertical FOV. A wheel
  only 48 cm from the eye and 28 cm below it lands at `sy ≈ -0.58` — below the bottom edge, rim clipped,
  which the user reports as "no steering wheel" while the mesh is perfect (this is the same symptom as a
  torus-axis error and half the cook cycles are spent telling them apart: check bounds FIRST, then `sy`).
  Keep the rim's projected span inside the frame, keep the rim top below the dash top line so it does not
  eat the road view, and put the cluster above that line so it reads over or through the rim. When the
  user asks for two parts to move, expect opposite directions in one pak ("gauges come down, wheel comes
  up") rather than a single-axis nudge — and give the tradeoff in the handover, because raising the rim
  towards eye height re-covers the cluster behind it. When the feedback arrives as one vague adverb
  ("too far", "a bit"), disambiguate **which part and which axis** before spending a cook — after a Z
  move, "too far" can mean *too far down* or *too far away*, and in practice the eye judges size/distance
  (the X gap) more often than height. Name both candidates and ask; a wrong guess costs a full
  test round-trip.
- **Both material slots usually resolve to the same vanilla parent, so the cockpit renders in body
  paint.** `M_<Mod>_Body` and `M_<Mod>_Interior` cloned from the same `M_Body` parent leave the dash,
  door cards, seats and wheel all painted body colour, which reaches the user as "a white thing is
  blocking the bottom of my gauges". Before hunting geometry, count the **body** primitive's vertices
  in that region — a handful of stray verts means the blocker is your own authored panel, not the
  shell. Making the interior read as an interior is a change to the interior instance's PARENT material — a polygon-master instance carries no `VectorParameterValues` entry to clone, so `--set-mi-params` cannot tint it, and repointing `Parent` at a vanilla non-paint material (`/Game/Cars/Materials/Body/M_Gray`, alternates `M_Body_Bottom`, `M_Wire`) is the route that works, shipped with no cook (recipe: `references/material-substitution.md`) —
  not a mesh change; say which of the two you are doing.
- **`--retarget-materials` can print `changed=2 problems=0` and change nothing on screen.** It rewrites the slot's object name and appends a package import for the new material, but an import for the material the mesh already referenced survives in the table and the engine follows that one — so a slot labelled `MI_MatteBlack_01` still renders your grey `M_<Mod>_Interior`. Verify before shipping: `strings <retargeted>/Body.uasset | grep '^/Game/'` must list the new material's package, and cross-check the shipped MIC itself (`strings M_<Mod>_Interior.uasset | grep -E 'M_Gray|MI_BaseColor'` — `M_Gray` means it is still the grey one). When it is stale, stop retargeting the slot and **replace the shipped MIC asset instead**: clone the vanilla instance you want, rename it to the name the mesh already points at, `--retarget-package` its internal path, stage both files over the existing pak entry — no mesh edit, no cook. `--retarget-package <in.uasset> <outpath> <old> <new>` writes a **single patched `.uasset` file** at `<outpath>`, not a directory — pair it with the clone's `.uexp` and stage that pair. Because the cooked mesh resolves slots by the paths the editor held at cook time, push both MICs into the UE project (`win_put.sh` to the model's `Content/...` folder) **before** the next cook, or the newly split slots import unresolved. Cars keep glass under `Cars/Materials/Windows/` but have **no** dedicated interior set; cabin trim uses `Env/Materials/Color` instances (`MI_MatteBlack_01`, `MI_GlossyDarkGray_01`). And remember a blank cowl filling two-thirds of the cockpit view is a **framing** problem as much as a colour one — say which of the two a change addresses. Recipe: `references/glazing-and-extra-material-slots.md`.
- **Size authored interior parts against the shell, never by eye.** The body primitive's side vertices
  (`|Y| > 60`, cabin X range) give the beltline and roof-edge Z directly — sides clustering at
  `Z 85–100` with the roof edge near `125` put the dash top at the beltline, so panels a hand's width
  below that read on screen as "too low". **Roof panels need the roof's profile per X slice, not its
  bounding box**: a fastback's crown can peak at `Z 135` while the shell only reaches `Z ≥ 128` between
  `X −75…+11`, so a headliner stretched to the roof's global X extent hangs out through the rear glass
  ("the headliner is extended past around the roof"). Keep each panel inside the X band where the
  shell's top at that X is above the panel's own Z, a few cm under the crown — a bounding box is a
  rectangle, a car is not. **The cabin floor is the shell too.** Looking down between the seats you see
  the body's own floor pan wearing body paint (white on a white car), which reads as a stray pale patch
  once the interior is dark; lay a black floor plate over it (thin box under the footwell, `Z` just
  above the pan, spanning sill to sill) as part of the interior primitive. Raise in one pass, then expect **independent** final positions: lifting dash, door cards and wheel as a unit fixes the dash and overshoots the other two,
  and the correction comes back as "dash is right, door cards too high, the wheel shouldn't have
  moved". Move only the parts actually named, and prefer the half-step over the full delta on a
  "seems too high/low" follow-up.
- **An all-black cabin reads as a void; give the vertical surfaces their own material.** Matte black
everywhere makes the interior look like empty space — the driver cannot tell where the door ends and the
floor begins ("it's black, but still a void", "make the walls brighter than the floor so I can see the
edges"). Do not add geometry for this: split the authored interior primitive by **face orientation**
(`vertical = np.abs(face_normal[:,2]) < 0.6`) and put door cards, kick panels and the dash face on a
second slot one shade brighter (`MI_GlossyDarkGray_01`), leaving floor, ceiling and dash top matte
black. Verticals catch light and horizontals do not, so the orientation split is the whole rule, and
contrast — not overall brightness — is what makes the edges legible. Rebinding both interior slots is a
material swap plus one cook for the extra primitive.

**The cabin you can see may be the BODY mesh, not your authored interior — measure before touching materials.**
On a shell that models its own tub, the inner surfaces are body triangles wearing body paint, and they sit
in front of every panel your interior primitive adds; recolouring the interior then changes literally
nothing on screen and each round trip looks identical. Measure it: ray-cast the driver's eye against the
mesh and report hit share **per material**. On the build that bit us 98.7% of the eye's frame was the body
primitive and 1.3% the interior — the material work had been painting a wall from the wrong side for four
builds. `scripts/cabin_split.py` does the measurement and the fix in one pass: cast a fan from the cabin
eye points, cast again from a sphere of outside viewpoints counting **front-face hits only**, and take
faces hit from inside but not outside as cabin-only. Reassign those (split by the same
`abs(normal_z) < 0.6` orientation rule) to the interior slots, leaving the skin untouched — re-run the
ray-cast afterwards and expect the interior share to dominate before spending a cook. Two conditions guard
it: a face seen from both sides is the roof/skin and must keep body paint, and the reassigned triangles
still follow the shell's winding, so flip them along with the body primitive and not by primitive index
written earlier.

**Read a GLB's axes off its bounding box before any geometric analysis.** Part GLBs are authored as
fed metres `(x = length, y = up, z = lateral)`, so the UE round-trip is `(fed_x, fed_z, fed_y)` →
`(X length, Y lateral, Z up)` — not the `(z, x, y)` you would guess from the importer's own mapping.
A swapped axis puts the "driver's eye" outside the car and returns nonsense (one face visible from
outside, everything visible from the cabin); assert the bbox reads roughly `X ±230, Y ±93, Z 25..135`
for a 4.6 m car before believing any ray-cast percentage.

**Dark-on-dark is ambiguous, so probe the lighting with a bright instance.** When two dark tones come
back "nope" with no visible difference you cannot tell a too-subtle albedo step from a cabin that
receives no light at all, and the two need opposite fixes. Bind the second slot to something loud for
one no-cook build (`MI_GlossyCream_01`). Bright cream means the slot mapping and the lighting are both
fine and only the tone was too grey — pick a mid tone (matte brown reads period-correct); still black
means the cabin is unlit and the answer is an emissive `_E` instance, not another colour.
- **Never author dash geometry in the donor cluster's own box.** The `Dashboard` component's mesh
  occupies roughly `X 0..18` at its local Z, so any panel spanning that band draws *in front of* the
  gauges: they vanish entirely ("gauges buried", "no dials at all") with the mesh present and the
  blueprint correct, and a leftover binnacle/vent box reads on screen as a floating cube the user will
  ask about. Build the dash **around** the cluster instead — a wall behind it (`X ≥ 18`), a fill below
  it (`Z` under the cluster's floor), a cowl above it (`Z` over its top) — and leave the cluster's own
  `X`/`Z` window empty. If it still fights, delete the authored dash outright: the donor
  `Dashboard` mesh is a complete dashboard, and the cabin reads sparse but correct. Lifting the cluster
  to clear a cowl is the wrong lever whenever the cowl is yours — it just puts the dials somewhere the
  user never asked for.
- **Blueprint-only changes need no cook.** When the mesh is unchanged, rebuild the pak from the last
  cooked tree and swap in the patched `<Blueprint>.uasset|uexp` — the cook re-emits identical meshes
  and costs minutes for nothing. Reserve cooks for mesh edits, and say in the handover which of the
  two you did.
- **`glTF`/`GLB` imports natively in UE5 (Interchange) — no FBX conversion needed.** Ask for FBX only
  when the source is already FBX or the user's toolchain can emit nothing else.
- **Trademark.** Ship under a fictional name like the rest of the roster; the real badge is not ours to
  use even when the mesh is licensed.
- **Physics is not the mesh.** The vehicle drives like whatever donor row it clones; engine /
  suspension / part work is separate (`motortown-custom-engine-parts`, `motortown-vehicle-tuning`).
- **Version lock.** Paks are cooked per game version and a wrong-version pak crashes the dedicated
  server, so a new vehicle is a rebuild on every game update plus client distribution. Say so before
  the user assumes it is fire-and-forget.
- **Nanite defaults ON for imported static meshes in UE 5.5.** `get_num_triangles(0)` then reports the
  proxy count (a 1,690-tri body reads as 1,248) and the cook carries a fallback mesh. A count that does
  not match the source means Nanite, not a bad import: set `nanite_settings.enabled = False`, resave,
  and re-check before cooking.
- **Cook from a throwaway map, not `-run=cook -map=` on the whole project.** One map referencing the
  imported meshes cooks in well under a minute and emits only `Content/Mods/<Mod>/...`; the cooked
  tree lands in `Saved/Cooked/Windows/<Project>/Content/`.
- **A cook re-emits whatever the editor holds at that path — re-stage offline-patched assets after it.**
  The cook map references package paths, so every asset at `/Game/Cars/Models/<V>/...`
  and `/Game/Cars/Parts/Wheels/...` is rewritten from the editor's copy, including ones you replaced by
  hand. Keep the deliberately-patched replacements (donor wheel clones renamed into the vehicle's wheel
  package, vanilla-MIC paint clones) staged outside the cook output and copy them in **after** extracting
  the cooked zip, or the cook silently swaps collision-less editor meshes back over the drivable ones.
  Drop the cooked copies of those paths from the pak staging and keep your own.
- **Tri count and bounds are the import's acceptance test.** "Exit 0" only means the editor did not
 crash; a wrong-axis or Nanite import also exits 0. Read the runner's JSON `errors` array rather than
 the exit code alone — an `rc=1` caused by a leftover optional block (e.g. a material bind for a slot
 that no longer exists) sits next to `cook rc=0` and reads as a failed import. Delete dead blocks from
 the import script so `rc` stays a real signal. Also assert every primitive's GLB `material` index exists
 in the `materials` array: a primitive pointing at a deleted material still imports, but the slot never
 appears, so the post-cook retarget reports `changed=0 problems=1` and dumping that mesh aborts with a
 core dump.

## Previewing without an engine

To show the user the mesh before any cook, render orthographic views with numpy + matplotlib
(`uv pip install matplotlib`): project triangles onto the chosen axis pair and fill flat-shaded.
**Sort triangles by centroid depth along the view axis before drawing** — an unsorted painter's pass
renders a shapeless blob and reads as a broken model. Colour wheels distinctly from the body; a dark
body on a dark background hides them completely.

For **inside-the-cabin** views also **near-plane clip**: drop any triangle with a vertex closer than a
few cm to the camera, or vertices behind it project to enormous screen coordinates and one sliver of
geometry paints over the whole frame. Clamp-based projection instead of clipping yields "the interior
fills the entire screen", which will send you hunting a geometry bug that does not exist.

**The renderer only reads glTF, so the donor `Dashboard` cluster cannot be drawn** — it is a cooked
`UStaticMesh` inside the game pak. Do not fake dials. Draw a **stand-in plate** at the component's own
transform (`DashboardMeshLocation` at `(8, −33, 78)`, ~44 × 26 cm) in a distinct colour and say plainly
that it marks where the cluster sits, not what it looks like; that is enough to judge "inside the rim
opening / above it / behind it" without a cook. Keep the plate's coordinates in sync with the `.uexp`
whenever the cluster moves, or the preview starts lying.

**Orange/odd colour showing through the body in a preview is the cabin seen through the windows**, not
geometry poking out: the shell is single-sided and the model ships no glass, so every window is an open
hole into the interior. Prove it numerically before touching geometry — interior primitive `|Y| max 58`
against the body's `87` in the same X band, interior top `Z 130` under a `135` roof — and then answer
with the real options (glass planes, or accept it) instead of "fixing" a mesh that is inside the shell.

**Glazing: ask the source model which triangles are windows before inventing a rule.** A low-poly car
usually ships no glass material — it paints its windows one flat colour in a tiny palette atlas, and that
colour is the artist's own selection (side glass included) which no angle heuristic reliably recovers: on
one body the angle rule found 32 triangles stopping at the windscreen while the source colour found 36
spanning the doors. Sample the source texture at each triangle's UVs and reuse the indices (they transfer
straight to our export — assert the index tables match): `scripts/glass_from_source.py`.

**Glazing: do not model windows where the shell has none.** Most of these bodies are solid right up to
the roof — the sides and rear deck are painted panels, so quads placed at imagined openings either
float over bodywork or hide inside it. With no source colour to read, fall back to the body's **own
greenhouse triangles** and duplicate them
1 cm outboard (offset `-n`, because the authored normals point *into* the cabin) — they conform to the
pillars and the A-pillar curve for free. Prove it drew by rendering the glazing in a garish colour and
counting matching pixels in an exterior view; zero visible pixels means the offset sign is backwards.
A new material for it means a third slot, which imports with a **null** `MaterialInterface` and has to be
bound on the cooked mesh — full sequence, the `--clone-asset`/`--retarget-package`/`--retarget-materials`
commands, and the two-slot fallback: `references/glazing-and-extra-material-slots.md`. **On a solid shell
also CUT those window triangles out of the body primitive** and double-side the glazing — otherwise the
driver is looking at the body panel with glass hidden behind it, and every material change comes back
"still milky" with an identical screenshot. Then **split the glazing by window**: the windscreen stays
translucent (`MI_GlassTrans`) and only the side/rear glass takes an opaque dark instance
(`MI_GlossyBlack_01`), one slot each. Opacity everywhere reads right from outside and makes the car
undrivable — a black wall where the road should be — and swaps one complaint for a worse one. Decide
which cluster is the windscreen from the source body's height profile and roof extents, not from a
"+Z is forward" assumption; on the model that bit us the nose was `+X` and the small forward cluster was
the windscreen while the big one behind the cabin was the fastback's rear glass. Judge the result from a
**daylight exterior** shot; a smoked band against a night sky is invisible and proves nothing.

**Bind the CAR window materials, not the environment glass.** Autonomous milky grey windows are almost
always the wrong material family, not an unfixable default: `/Game/Cars/Materials/Windows/MI_Glass_Base`
is what every vanilla car uses, while `/Game/Env/Materials/MI_GlassTrans` is prop/building glass and
renders pale grey with no overrides (`MI_GlassNonDirection` behaves the same). When a material renders
wrong, ask the pak which folder that asset class keeps its materials in
(`mtextract.sh --search "Glass" | grep -E 'M(I)?_'`) instead of trying sibling instances — cars keep
their own material sets apart from `Env/`, and that holds for wheels, lights and trim too. Two identical
"still milky" screenshots in a row means stop swapping instances.

**Never double-side a translucent glazing.** Duplicating it to fill a cut hole stacks two alpha surfaces
1 cm apart, which reads milkier than any vanilla car; duplicate only opaque panels. Give the surfaces a
**single layer** and judge the result from a **daylight exterior** shot — a smoked band against a night
sky is invisible and proves nothing.

**"Transparent from the inside only" is backface culling, not a broken material.** When the user says the
windows are visible from the cabin and read as open holes from outside, the glass triangles are wound
inward and a one-sided material culls them from every exterior angle. That is a winding fact about the
source's glazing selection, not a reason to duplicate it — duplicating fixes the exterior and re-creates
the doubled-alpha milkiness. The correct lever is reversing those triangles' index order once, so the
layer stays single and faces out; then judge it from a daylight exterior shot.

**`MI_Glass_Base` on one outward-facing pane IS vanilla parity — verified on screen.** The car window
materials (`/Game/Cars/Materials/Windows/`) need no `Window`-component parameters: bound straight into a
mesh section they read tinted from outside and clear from the cabin, provided the glazing is a **single
layer wound outward**. What makes them look wrong is always one of two geometry faults — a duplicated
coplanar pane (doubled alpha = milk) or a pane wound inward (culled from outside, milky from inside).
When both symptoms show at once (open holes outside *and* milky inside) it is the inward winding, never
the material family; swapping instances in the family changes nothing and burns a build each time. Do
not reach for the split (translucent windscreen, opaque dark sides/rear) until one clean outward pane on
`MI_Glass_Base` has actually been tested.

**When a visual detail has failed three times, stop building and work a ranked cause list instead.**
Write the causes out with the observation that discriminates each, mark the ones already eliminated by
builds already done, and spend one build per cause — never a bundled "maybe it's this". A single-layer
build that is milky inside *and* invisible outside proves the layer faces inward **and** kills the
duplicate-layer cause at once; report both facts rather than reacting to the visible half by duplicating
(the exact move that re-creates the milkiness). Ladder with the tests and recorded eliminations:
`references/glazing-and-extra-material-slots.md`.

The rest of the glazing sequence — taking the window triangles from the source's palette colour, cutting
them out of the body primitive so the driver is not looking at the panel behind the glass, splitting
windscreen from side/rear glass by the source body's height profile, and the third-slot / `--retarget-*`
machinery: `references/glazing-and-extra-material-slots.md`.

## Sources of truth

- Running the C# asset tool, its config/op schemas, the `--clone-asset` rename trap and the
  blueprint-write wall: `references/uasset-tool-write-path.md`. Runner: `scripts/uasset.sh` — always
  invoke that, never hand-roll an apphost wrapper: the apphost needs `DOTNET_ROOT=<sdk>/share/dotnet`
  (not the SDK root) or it dies with `Failed to resolve libhostfxr.so` / "You must install .NET", and
  hardcoded store SDK hashes get GC'd.
- Real-car inspiration per vehicle: `motortown.info/vehicles`, plus IGCD for chassis/series detail.
- Per-vehicle modeller credits: **not published anywhere**. The only per-model attributions ever
  shipped are in the 0.6.4 patch notes (Cora by 7HC; Essam and SCM Kart One by scailman); pre-2022
  vehicles came from Marketplace asset packs before P3 had custom modelers. Never invent an
  authorship list for a community question.
- Donor blueprint internals: `out/<Vehicle>_parsed.json` in an extracted-version worktree.
