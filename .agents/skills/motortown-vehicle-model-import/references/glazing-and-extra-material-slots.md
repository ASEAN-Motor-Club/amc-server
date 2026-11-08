# Glazing a car whose shell has no window holes, and the third-material-slot route

Two jobs in one file because they meet: glazing needs its own material, and extra materials need a
third slot.

## 1. Find out whether the shell has holes at all before modelling glass

Low-poly car bodies are often **solid** across the greenhouse — the sides, windscreen and rear deck are
painted panels, not openings. Glazing quads placed where you *assume* the windows are then float over
bodywork or sit invisible inside it.

Do not eyeball this, and do not project the shell onto a plane (both sides' triangles land on the same
2D cells, so a hole on the near side is covered by the far side and every region reads solid). Sample
per side instead: bin the body verts by X and print the Z (height) intervals present for `|Y| > 45`.
A side that is occupied from the sill to the roof has no side windows. In practice the only glazed
surface on such a model is the windscreen band, and that is the honest thing to tell the user.

## 2. Take the glazing from the SOURCE model's own material assignment

A Sketchfab-style low-poly car does not ship a glass material — it paints its windows **one flat
colour** in a tiny palette atlas (64×64, a few dozen colours). That colour *is* the artist's window
selection, including side glass that no geometric rule reliably finds, so it is the primary method:

```bash
# list the atlas's top colours + select the window colour, in the source's own space
python3 scripts/glass_from_source.py <dir-with-scene.gltf> glass_tris.npy
#  glass tris: 36 of 1690
#    lat -0.67..0.66 m   up 1.03..1.23 m   fwd -1.43..0.40 m
```

The selector samples the base-colour texture at each triangle's three UVs and keeps triangles whose
**corners all land on the colour** — requiring all three avoids edge bleed from neighbouring texels.
Vertex count and order normally match our own export exactly, so the resulting triangle **indices
transfer straight onto our body primitive**; assert that (compare the exported index table against the
source's) before relying on it.

What this buys over the heuristic below: on the same body the angle rule selected 32 triangles and
stopped at the windscreen, while the source colour selected 36 spanning the side glass too — the user's
complaint was exactly "windows aren't there".

### Fallback: derive the glazing from the body's own triangles

Instead of fitting quads to imagined openings, select the shell's greenhouse triangles and duplicate
them slightly outboard. They conform to the shape exactly — no overshoot past the pillars, no gap at
the A-pillar curve.

Selection that worked (axes: X forward, **height on axis 1**, lateral on axis 2 — verify with a bounds
print before trusting it):

```python
c = triangle centroids; n = triangle normals
aligned_cabin = (c[:,0] > -145) & (c[:,0] < 25)     # cabin in X
above_belt    = c[:,1] > 97                         # height axis
below_roof    = c[:,1] < 119                        # keeps the roof panel out of the glass
steep         = np.abs(n[:,1]) < 0.62               # forget roof/bonnet/deck
band          = (np.abs(c[:,2]) > 28) | (c[:,0] > 4) | (c[:,0] < -70)   # sides + screens
sel = aligned_cabin & above_belt & below_roof & steep & band
tri = tri[sel] - (n[sel] * 1.0)[:, None, :]          # 1 cm OUTWARD
```

- **The offset sign is the opposite of what the winding suggests.** These shells are authored with
  normals pointing *into* the cabin (which is exactly why the body primitive needs a winding flip to be
  visible from inside), so outward is `-n`. Getting it backwards hides the glazing inside the shell and
  the only tell is that a cockpit render shows it while an exterior render shows nothing.
- **Print the selected count and extent, and confirm the roof is not in it.** A selection that spans
  the full lateral range at the highest Z is glassing the roof.

Cheap numeric acceptance test instead of a cook: render the exterior views with the glazing primitive
in a garish colour and count matching pixels. Zero visible pixels from outside = offset in the wrong
direction or the geometry is inside the shell. Thousands = it is drawing.

## 3. Third material slot: imports null, must be retargeted after the cook

A GLB with three materials imports fine and the mesh really does get `StaticMaterials[2]` — but
`MaterialInterface` is **null**, because the editor project has no asset at that name. Consequences and
the working sequence:

```bash
# 1. clone a vanilla translucent instance OUT of the game pak, renamed into the vehicle's package
dash mtextract.sh MotorTown/Content/Env/Materials/MI_GlassTrans
bash uasset.sh --clone-asset clone.json MI_GlassTrans.uasset out/
#    clone.json : {"new_name": "M_Mod_Glass", "new_path": "/Game/Cars/Models/<V>",
#                  "old_name": "MI_GlassTrans", "rename_exports": true, "rename_imports": false}
#    rename_imports MUST stay false or the Parent link to the vanilla master is renamed away

# 2. FIX THE INTERNAL PACKAGE PATH -- the clone still claims the SOURCE folder
dash uasset.sh --retarget-package out/M_Mod_Glass.uasset out2/M_Mod_Glass.uasset \
      /Game/Env/Materials/M_Mod_Glass /Game/Cars/Models/<V>/M_Mod_Glass
#    (out is a FILE path here; a directory aborts with a FileStream ctor stack trace)

# 3. bind the null slot on the COOKED mesh
dash uasset.sh --retarget-materials cooked/Cars/Models/<V> retarget.json out/
#    retarget.json : {"rules": [{"mesh": "Body", "slot": "M_Mod_Glass",
#                                "mi_package": "/Game/Cars/Models/<V>", "mi_name": "M_Mod_Glass"}]}
#    expect: "Added imports: Package [n] / Asset [n+1]" then "RETARGET Body M_Mod_Glass -> ... x1"
```

Then ship the retargeted `Body.uasset|uexp` plus `M_Mod_Glass.*` (`--retarget-materials` only wrote the
mesh, it does not ship the material for you).

### The retarget can be cosmetic: check the package import, not the slot name

`--retarget-materials` rewrites the slot's object name and appends package imports for the new
material, but **an import for the material the mesh already referenced stays in the table**, and the
engine follows that surviving import. The slot then reads `MI_MatteBlack_01` while the car keeps
rendering the old grey asset: `changed=1 problems=0`, a rebuilt pak, and an identical screenshot.

```bash
strings out/Body.uasset | grep '^/Game/'
# /Game/Cars/Models/Spider/Body
# /Game/Cars/Models/Spider/M_Barracuda_Body
# /Game/Cars/Models/Spider/M_Barracuda_Interior   <- stale: the old MIC is still referenced
# /Game/Env/Materials/Color                      <- the new material's package
```

The new package appearing proves nothing — both are present and the old asset wins. Cross-check the
shipped MIC itself: a polygon-master clone whose own `/Game/` strings still include
`/Game/Cars/Materials/Body/M_Gray` is the grey material whatever the mesh calls it; a clone of
`MI_MatteBlack_01` references `MI_BaseColor` instead.

Fix it **without a cook** by replacing the shipped asset rather than the slot — clone the instance you
want, rename it to the name the mesh already points at, patch its internal path, and stage over the
existing pak entry:

```bash
# 1. clone the material you actually want, named as the slot expects
#    clone.json: new_name=M_Barracuda_Interior, new_path=/Game/Cars/Models/Spider,
#                old_name=MI_MatteBlack_01, rename_exports=true, rename_imports=false
bash uasset.sh --clone-asset clone.json MI_MatteBlack_01.uasset intclone/

# 2. fix the internal path (still /Game/Env/Materials/Color after the rename)
bash uasset.sh --retarget-package intclone/M_Barracuda_Interior/M_Barracuda_Interior.uasset \
     intclone_fix /Game/Env/Materials/Color/M_Barracuda_Interior /Game/Cars/Models/Spider/M_Barracuda_Interior
#    intclone_fix is a FILE (the patched .uasset), not a directory -- take the .uexp unchanged
#    from intclone/M_Barracuda_Interior/

# 3. stage BOTH over the pak's existing M_<Mod>_Interior.uasset|uexp, keep the mesh as cooked
```

Motor Town has no car-interior material set: glass lives in `Cars/Materials/Windows/`, but cabin trim
and body colour use `Env/Materials/Color` instances (`MI_MatteBlack_01`, `MI_GlossyDarkGray_01`,
`MI_GlossyBlack_01`). Also separate the two complaints a dark interior answers — "still grey" is a
material swap, "grey abyss" is the cowl filling most of the frame, which colour alone cannot fix.

**Every primitive's `material` index must exist in the GLB's `materials` array.** Adding a primitive at
material index 2 while the materials list holds only two entries still imports — but the slot never
materialises, so the retarget reports `changed=0 problems=1` and `--dump` of the resulting mesh aborts
with a core dump. Edited the `MATS` list (e.g. while trying the two-slot fallback) and came back to the
third slot? Restore the entry and print the materials list plus every primitive's index before the cook.

### The failure you will hit if you skip step 2

An asset whose internal `FolderName`/NameMap still says the old package path, but which the pak mounts
somewhere else, does not merely fail itself — the whole package's material table stops resolving. In
game the car renders entirely in the engine default checker, wheels included. That is identical to the
"shaders did not come from the game" symptom, so **check the package path before blaming the cook**:
`--dump` the clone and read `FolderName` and `NameMap[1]`.

Diagnostic that isolates it fast: md5 the whole staging tree against the last known-good build. If only
the mesh and the new material differ, the material binding is the cause and no amount of re-cooking will
help.

### When to skip the third slot entirely

If the extra material cannot be bound before the cook, fold the extra triangles into an existing slot in
the GLB instead (`prims[1] = interior ∪ glazing`, all with material index 1). Two slots keep the proven
shape — our own cook, our own instances, zero post-cook patching. It only reads as glass if that slot's
material is dark enough to contrast with the paint; a light grey interior against a white body reads as
a solid white shell from outside, and the user will say so.

### Dead end: the glazing can NEVER show from inside while the shell panels are still there

On a solid-shell body the glazing sits 1 cm *outboard* of bodywork that is itself visible from the
cabin (the body primitive is flipped so it draws from inside). So the driver is looking at the shell,
with the glass behind it: changing the glass material twice in a row changes nothing on screen and every
build comes back "still milky". Two wasted paks is the tell — when a material swap produces an
identical image, stop swapping materials and ask **whether the surface in view is that material's
surface at all**.

The fix is to remove the window faces from the body primitive so the glazing is the only surface there:

```python
# glass_tris.npy holds the source-selected window triangles, in body-primitive index order
gt = np.load('glass_tris.npy')
t0 = I.reshape(-1, 3)              # body indices, shape (1690, 3)
keep = np.ones(len(t0), bool); keep[gt] = False
prims[0] = (fed, Nf, UV, t0[keep].reshape(-1), 0)     # 1690 -> 1654 tris
```

Two follow-ons, both required:

- **Double-side the glazing ONLY if its material is opaque** (`tri = np.concatenate([tri, tri[:, ::-1]])`,
  normals negated to match). It now fills a hole, so it is seen from the cabin as well as from outside,
  and a single-sided opaque material would vanish from one of the two. **Never duplicate a translucent
  glazing**: two alpha surfaces 1 cm apart compound (0.3 alpha twice ≈ 0.5), so the windows read
  distinctly milkier than any vanilla car's and the difference looks like a material fault. One layer
  for translucent glass, two only for an opaque panel.
- **Split the glazing by window only when you must mix translucent and opaque.** Prefer one material for
  the whole set — `/Game/Cars/Materials/Windows/MI_Glass_Base` gives the vanilla-car look in one slot and
  no split. The split exists for the case where the user wants dark side/rear glass AND a usable view
  ahead: then the **windscreen** stays translucent and everything else takes an opaque dark instance
  (`MI_GlossyBlack_01`). An opaque dark instance over the whole set reads perfectly from outside and
  makes the car undrivable — the user gets a black wall where the road should be and says so
  immediately. Deciding which triangles are the windscreen is a geometry question, not a convention:
  see "Which cluster is the windscreen" below.

```bash
# find the vanilla instance and its real pak path before writing a retarget rule
ls out/ | grep -iE '^MI_.*(black|rubber|plastic|dark|glass)' | sed 's/\.uasset//' | sort -u
mtextract.sh --search MI_GlossyBlack_01        # -> MotorTown/Content/Env/Materials/Color/MI_GlossyBlack_01
```

Binding a **vanilla** instance needs no shipped material and no cook of its own: retarget the slot with
`mi_package=/Game/Env/Materials/Color`, `mi_name=MI_GlossyBlack_01`, then rebuild the pak — the mesh
change itself is the only thing that needs a cook.

### Which cluster is the windscreen (do not assume +Z is the nose)

The source glTF's front axis is not guaranteed, and the two glazing clusters look alike. Resolve it from
the body's own height profile rather than a convention:

```python
# max height and lateral width per Z slice, source space
for z0 in np.linspace(-2.3, 2.3, 24):
    m = np.abs(pos[:, 2] - z0) < 0.12
    print(z0, pos[m, 1].max(), pos[m, 0].ptp())
roof = pos[pos[:, 1] > 1.25]          # roof Z range tells you where the cabin sits
```

On the model that bit us the roof spanned `z −1.03..+0.11` and the glazing sat at `z −1.43..−1.08`
(22 triangles, lateral ±0.54) and `z +0.20..+0.40` (8 triangles, ±0.29). The **small forward cluster is
the windscreen** — it sits just ahead of the roof's front edge, exactly where a windscreen does — and the
big one behind the cabin is the fastback's rear glass. The cockpit camera confirms it: eye at UE
`X −70` looking `+X` puts the windscreen ~100 cm ahead.

In our own axes that is `nose = +X`, roof front edge at `X +11`, and the windscreen is the glazing at
`X > 10`. Split on that threshold into two primitives and let each become its own slot:

```python
front = tri.mean(1)[:, 0] > 10.0                  # windscreen mask, per triangle
for slot, mask in ((2, GFRONT), (3, ~GFRONT)):    # 2 = clear, 3 = opaque dark
    sub = GP[mask]
    ...                                            # weld + normals as usual, material = slot
```

Getting this backwards puts the black panel where the road should be, which looks like the split failed
rather than being inverted — print the per-cluster triangle counts and extents before cooking.

State the trade-off in the handover: an opaque panel over the **windscreen** means the driver cannot see
out, so keep that surface translucent and opacity only for the side and rear glass — which is what the
source model's flat near-black actually depicts, since it never had real glass.

## 5. Milky-from-the-cabin triage ladder

When the user says the glass is "still milky" after the panels are cut out and the material is right,
stop building and hand over a **ranked cause list with a discriminating test each**, then work down it
one build at a time. Two rules make this cheap:

- **Eliminate from builds already done before spending a new one.** Each past build is evidence about
  several causes at once; state which causes it killed before proposing the next change.
- **One build tests one cause.** Never bundle, or the answer is again "still milky" with no attribution.

| # | Cause | Discriminating observation |
|---|-------|----------------------------|
| 1 | Duplicate layer stacking alpha | already **eliminated** if a single-layer build was also milky |
| 2 | Wrong material / unset runtime params | **eliminated in practice** — the car-window family renders correctly on one outward pane, so identical results across two instances point at geometry, not the material |
| 3 | No UVs (all UV 0,0 → one flat texel) | needs real UVs from the source; flat wash vs. gradient |
| 4 | Pale cabin behind the glass | retarget the interior slot to a dark instance — pak-only, no cook |
| 5 | Normals / winding lit head-on | single-sided inward test: clear inside + holes outside ⇒ faces inward |
| 6 | Grazing angle at the outer skin | only moves if the pane moves; needs geometry |

**A single-layer build that is milky inside *and* invisible outside is two facts, not one**: the layer
faces **inward** (hence culled from outside) *and* the duplicate-layer cause is dead (one layer was
already milky). Do not "fix" the invisible exterior by duplicating — that is exactly the sequence that
re-creates the milkiness the rule above forbids. Reverse those triangles' index order so the layer stays
single, then re-judge.

**Both symptoms at once are one geometry fault, not a material fault.** `MI_Glass_Base` and
`MI_Glass_SunRoof` showing open holes outside *and* milk inside is not the family missing
`Window`-component parameters — it is the pane they were bound to being **duplicated and wound inward**.
With the duplicate gone and the single layer facing out, `MI_Glass_Base` gives the vanilla result:
tinted from outside, clear from the cabin (verified in game). So when two instances in the family behave
identically, suspect the geometry before the material, and finish the ladder rather than jumping to the
split/opaque fallbacks.

Say in the handover which cause each build tested, so the user can see the ladder moving rather than
another identical screenshot.

## 6. What good looks like on screen

Verified in game with a translucent instance in slot 2: the windscreen shows as a dark band against the
paint from outside, and the view from the driver's seat is completely clear and untinted. That
combination is the proof it is real glass and not an opaque sheet — if the cabin view goes dim, the
instance is opaque.

Do not try to judge glass from a night-time interior screenshot; a smoked band against a dark sky is
invisible by definition. Ask for a daylight exterior three-quarter shot.

### Use the CAR window materials, not the environment ones

Milky grey does **not** mean the game has no usable glass. Motor Town ships a dedicated car-window set
and it is not where the prop/building glass lives:

```
MotorTown/Content/Cars/Materials/Windows/  M_Glass, M_Glass_Base, MI_Glass_Base,
                                           MI_Glass_SunRoof, M_Internal_Glass, M_Glass_LightCase
MotorTown/Content/Env/Materials/           MI_GlassTrans, MI_GlassNonDirection   <- props/buildings
MotorTown/Content/Env/Materials/Master/    M_GlassTrans, M_GlassTint               <- env masters
```

`MI_Glass_Base` at `/Game/Cars/Materials/Windows` is what every vanilla car uses, so binding it makes
the car look like "every other car in the game" — the thing the user actually asks for. The env
instances render pale milky grey in daylight and carry **zero** parameter overrides (so nothing is
settable from outside: `strings` on the master shows `GlassTint`/`Opacity`/`Use_BaseColor`, but the
wrapper tool has no vector-parameter writer).

**Generalise the search rather than guessing between instances**: when a game asset renders wrong, ask
the pak where that *asset class* keeps its materials. `mtextract.sh --search "Glass" | grep -E 'M(I)?_'`
printed both sets in one shot and the `Cars/Materials/...` path was the answer; the same holds for
wheels, lights and trim, which all have car-specific material folders separate from `Env/`.

**Two identical "still milky" screenshots in a row is the signal to stop swapping instances** and check
the folder you are sourcing from instead.

If genuinely no suitable vanilla instance exists, the fallbacks are: point the side/rear slot at a dark
vanilla paint instance (`MI_GlossyBlack_01` under `Env/Materials/Color`) and keep the windscreen
translucent, or bake the window colour into the paint like the source model does — say which one you are
doing, and never present the milky grey as the model's intent.
