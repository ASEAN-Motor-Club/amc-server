# Donor cockpit components on a replacement body

A replacement vehicle keeps the donor's cockpit rig. On a body of a different size or height those
parts end up in the wrong place — most often exactly at the vehicle origin, which is **ground level
between the axles**, so the donor's steering wheel and gauge cluster sit underneath the car and scrape
terrain while driving.

Dump the blueprint's export list first (`--dump`, or `out/<Vehicle>_parsed.json`):

- `SteeringWheel` — `StaticMeshComponent`, a shared part mesh (e.g. `3Spoke_01`), `AttachParent` = the
  body `Mesh` component.
- `Dashboard` — class `MTDashboard`, holds `DashboardMesh` plus a **`DashboardMeshLocation`** vector.
- `CockpitCamera`, `DriverSeat_GEN_VARIABLE` (`MTSeatComponent`), `TrailCamera`, the mirror components,
  seat interaction spheres.

## Which of them can be moved

Only components whose export **serialises a `RelativeLocation`** are reachable with `set_vector`. In the
vanilla `Spider` blueprint that is `CockpitCamera` and `DriverSeat_GEN_VARIABLE` (and `Wheel0..3`, the
lights). `SteeringWheel` and `Dashboard` serialise **no** location — their exports are ~37 and ~412
bytes of mesh reference, attach parent and gauge config — so `set_vector` on them reports
"Patched export" and changes nothing (see the silent-no-op rule in
`references/uasset-tool-write-path.md`).

Check `Export[N] … SerialSize` and the dumped `Properties` list before promising a move: an export
under ~50 bytes cannot be carrying a vector.

## Levers that do work

1. **`Dashboard.DashboardMeshLocation`** — an existing vector property, so `set_vector` relocates the
gauge cluster mesh without touching the component transform. Coordinates are vehicle-local cm.
2. **`null_ref` on `SteeringWheel.StaticMesh`** — sets the object property to package index 0, so the
   stray wheel renders nothing while the component stays intact. Use it when your own interior already
   models a wheel; removing the donor's duplicate is cleaner than trying to place it.
3. **`CockpitCamera` / `DriverSeat_GEN_VARIABLE` `RelativeLocation`** — real vectors, so the eye point
   and the seat move into the built cabin.

```json
{"output_filename": "Spider", "exports": [
  {"export_name": "SteeringWheel", "patches": [{"op": "null_ref", "path": "StaticMesh"}]},
  {"export_name": "Dashboard", "patches": [{"op": "set_vector", "path": "DashboardMeshLocation",
                                           "x": 6, "y": -33, "z": 70}]},
  {"export_name": "DriverSeat_GEN_VARIABLE", "patches": [{"op": "set_vector", "path": "RelativeLocation",
                                           "x": -62, "y": -33, "z": 50}]},
  {"export_name": "CockpitCamera", "patches": [{"op": "set_vector", "path": "RelativeLocation",
                                           "x": -64, "y": -33, "z": 106}]}]
}
```

## Where the numbers come from

Take them from the interior you authored, not from the donor. For a cockpit built as a second primitive
in the body mesh (floor pan 27–31, dash 46–78, seat squab 33–44 / backrest 44–96 / headrest to 108,
steering-wheel rim centred at `(0, -33, 76)`), the donor's `(-38, -45, 49)` seat and `(-53, -42, 125)`
camera land in front of the seat squab and 12 cm outboard of it: seat to the squab centre, camera ~30 cm
behind it at eye height just under the roof, gauge cluster at the dash face.

## Verification (offline)

Dump the written asset and confirm `StaticMesh (Object): Index=0` on the wheel and that the three
vectors appear in the property list; then diff the `.uexp` against the source — expect one small run per
patched vector and **no size change** (5,027 B for `Spider`). A size change means the writer re-serialised
something it should not have.

## Placement in practice (seen in game)

All three levers write and take effect in game. What they do *not* do on their own is produce a usable
cockpit view, because the donor gauge cluster is a **large panel mesh**, not a small dial face:

- Cluster at dash height (`z 66–70`) with the eye lowered to driving height (`z ~106`) put a solid dark
  panel across the middle of the frame — the cluster mesh is tall enough to reach eye level, so the view
  reads as "camera stuck inside the dashboard".
- Reverting the eye to the donor's `z 125` and leaving the cluster just clear of the ground (`z 30`) puts
  the gauges low and out of the way — but then **no steering wheel appears at all**, because the authored
  rim (`z 76`, `x 0`) sits ~43° below the view axis when the eye is at 125: outside a typical 60–70°
  vertical FOV.

So the two numbers interact and must be converged deliberately:

1. Fix the **eye** first, at driving height — roughly the headrest top minus 5–10 cm (here `z 110`),
   `x` about a hand's length behind the rim, `y` on the driver's seat centre, not the donor's outboard
   offset. At that eye point an authored rim 50–70 cm ahead lands ~25–30° below the view axis, i.e. in
   frame, with the cluster visible below it.
2. Only then place the cluster, at the dash face just under the rim's lowest point, and keep it low
   enough that its top stays below the eye line.
3. Change **one** of those numbers per test pak. Moving eye, seat and cluster in a single pak produced a
   worse view than the starting state and, worse, made it impossible to tell which value did it — the
   user's report was only "it ain't fixed but it's definitely different".

Seat and camera are independent for the same reason: the seat decides where the character sits and the
camera is the fallback view, so an unprompted seat move changes two behaviours at once.

## Closing the cabin: panels, not a double-sided shell

From the driver's eye a single-sided body shell is culled on every panel around you — roof, doors,
firewall — so the cabin reads as open to the street. The instinct to make the whole body double-sided is
the wrong tool: it doubles the whole car's triangle count and fill cost for a problem that lives inside
the cabin. Add planar panels to the authored interior primitive instead, and keep the body single-sided
(flipped, prim 0 only):

- **headliner** — spans the cabin just under the roof peak (roof peak 135 → slab at `z 125–129`),
  `y` inside the door cards (`±44` inside a `±62` roof), and `x` limited to the range where the roof
  ACTUALLY supports that height — see below, not "rear bulkhead to windscreen header" by name;
- **parcel shelf** — behind the rear bulkhead, `z ~92–95`, so the boot does not show through;
- door cards, floor pan and bulkheads are normally already authored; if the user still sees daylight,
  ask *which* panel rather than reaching for a global fix.

`Body.uexp` grew 293,762 → 474,100 B on the double-sided route and the user rejected it; the two panels
above cost 48 triangles and were accepted on the first try. Panels are also safer than winding: they
cannot be inside-out because they are closed boxes.

**Derive a roof panel's X extent from the roof's height PROFILE, not from its bounding box.** A
fastback's roofline drops aft of the cabin, so the box that contains the whole roof is much longer than
the part of it that is actually roof-height. On a 4.6 m body the crown peaks at `Z 135`, but the shell
only reaches `Z ≥ 128` between `X −75` and `+11`; a headliner built to the roof's global extent
(`X −104 … +4`, taken as "rear bulkhead to windscreen header") hangs its aft third out through the rear
glass, which the user reports as "the headliner is extended past around the roof". Sample the body
vertices in X slices and keep each band's top `Z` — then place the panel only where the shell's top at
that X is above the panel's own Z, and leave a few cm under the crown. Working value for that body:
`X −72 … 0, Y ±44, Z 125–129`. The same profile check applies to any authored panel that is supposed
to sit against an outer surface (parcel shelf, door cards, cowl) — a bounding box is a rectangle, a car
is not.

## Interior heights: measure the shell, and move parts independently

Authored interiors are usually built to a guessed cabin and sit low against the real shell. Measure the
body primitive instead of eyeballing: take its side vertices (`|Y| > 60`) within the cabin X range and
look at the Z histogram — the beltline/window sill and the roof edge fall out as two clusters (for a
4.6 m body: sides at `Z 85–100`, roof edge `~125`, roof peak `135`). A dash topping out at `Z 78`
against that shell reads on screen as "the dash and door cards are too low".

Lifting the dash, door cards and the wheel that hangs off them together fixes the dash and overshoots
the rest — the correction comes back as "dash is right, door cards too high, the wheel shouldn't have
moved". Expect three separate positions and apply the follow-up as a half-step (a full +12 raise
answered with "too high" wants +6, not a revert), and treat the wheel as its own part: it does not
inherit the dash's position even though it visually sits on it.

A "white thing blocking the lower half of the gauges" is usually **your own** dash cowl, not the shell:
confirm by counting body-primitive vertices in that region (near zero) — and it is white because
`M_<Mod>_Body` and `M_<Mod>_Interior` are both clones of the same `/Game/Cars/Materials/Body/M_Body`
parent, so the whole cockpit renders in body paint. Making it read as interior is a parameter override
on the interior instance; until then, colour is not evidence of which mesh a surface belongs to.

## Making the interior read as interior: repoint the instance's Parent

The polygon-master instance carries no `VectorParameterValues` entry to clone, so `--set-mi-params`
cannot tint it. What works is repointing `M_<Mod>_Interior`'s `Parent` at a vanilla **non-paint**
material — `/Game/Cars/Materials/Body/M_Gray` (alternates `M_Body_Bottom`, `M_Wire`) — which leaves
`M_<Mod>_Body` on the paint path so the shell still takes garage colour while the cockpit goes dark. It
ships with **no cook** (materials are assets, the mesh is untouched) and was accepted in game.

The config shape is `exports`, not a bare `patches` list — a top-level `patches` array aborts with
`Config must have 'exports' array with {export_name, patches} entries`:

```json
{"output_filename": "M_<Mod>_Interior",
 "exports": [{"export_name": "M_<Mod>_Interior",
   "patches": [{"op": "set_or_create_import_ref", "path": "Parent",
                "class_package": "/Script/Engine", "class_name": "Material",
                "package_path": "/Game/Cars/Materials/Body/M_Gray", "asset_name": "M_Gray"}]}]}
```

A successful run prints `Added imports: Package … / Asset …` and `Patched export:`, and writes both
`.uasset` and `.uexp` — with the parent present this op does *not* hit the blueprint schema wall. The
leftover `BaseColor`/`Metallic`/`Normal` texture parameters on the instance simply go unused against a
material that has no such parameters; they do not break anything.

## Editing the vector without the C# patcher

When `--patch-named-exports` aborts with the `MTVehicleBaseBP_C` schema error (prints `Patched 3
exports.` and writes nothing), the same edit lands as a direct `struct.pack_into` on the cooked `.uexp`:
these `FVector`s are **three float64**, so a float32 search finds nothing. In the 5,027-byte `Spider`
cockpit variant: `CockpitCamera.RelativeLocation` at 1016/1024/1032 and
`Dashboard.DashboardMeshLocation` at 1828/1836/1844 (`X`/`Y`/`Z`). Rewrite in place, assert the length
is unchanged, and re-read all three doubles to confirm.

## Previewing the cockpit without the donor cluster

The offline renderer reads glTF only, so the donor `Dashboard` mesh (a cooked `UStaticMesh`) is not
renderable. Draw a stand-in plate at `DashboardMeshLocation` — 44 × 26 cm, `±2 cm` thick in X, in a
colour no other primitive uses — and label it as a marker, never as dials. Where it lands answers the
only questions worth asking before a cook: inside the rim opening (usual, correct), above the rim (dash
cowl too low or cluster too high), or hidden behind a panel (occlusion). Keep the plate's numbers in the
script identical to the `.uexp` doubles; a stale marker produces a confident, wrong layout answer.

## The cluster owns a box: build the dash around it, or don't build one

Every "gauges buried / no dials at all" round in this class comes from authored dash geometry
overlapping the cluster's own space. Treat `DashboardMeshLocation` as the centre of a **reserved box**
(roughly `X 0..18` deep, `±12` in Z around the Y location) and never author a panel through it:

- a panel whose face sits inside that box draws *in front of* the dials — the cluster exists, is
  correctly placed, and is simply invisible;
- a leftover box such as a procedural "instrument binnacle" renders as a **solid cube floating on the
  dash**, and the user will ask what it is. If you added it and cannot see it in the render, it is still
  there in game.

Working construction (accepted on screen): main dash wall **behind** the cluster (`X ≥ 18`), a lower fill
**below** it (up to the cluster's bottom edge), a cowl **above** it (`Z` just over the top of the
cluster). Nothing spans the reserved box, so the dials cannot be swallowed by any of the three.

If it still does not read right, delete the procedural dash entirely — the donor `Dashboard` mesh is a
complete dashboard with its own top and sides. The cabin looks sparse, and the user will notice ("no dash
but eh"), which is a far better place to iterate from than an invisible cluster.

Do not use cluster-Z as the escape hatch for an authored cowl. Raising the dials to clear your own panel
moves them somewhere the user never asked for ("the wheel and gauges shouldn't have moved"), and the next
report is a placement complaint instead of an occlusion one.

## Gauges hide behind the wheel when the cluster sits below the rim centre

Once the authored wheel is visible it occludes anything behind and below its centre. A cluster at dash
height (`z 66`) with a rim centred at `z 82–92` is completely hidden from an eye at `z 110`, and reads
as "the gauges disappeared" even though nothing moved in the pak. Keep the cluster's centre **at or
above the wheel centre** (`z 88` against a rim at `z 82`) so it shows through the upper rim opening, and
keep the rim's top roughly level with the dash top (`z ~101` against a dash top of 78) rather than 30 cm
proud of it — a rim that stands that high dominates the frame and buries both the cluster and the road.
Beware the follow-on complaint: raising the cluster above the rim can still read as "too far"; that is a
*Z-forward position* judgement (gap between eye and cluster), not a height one, so offer a closer
`x` (e.g. `8 → -14`) instead of moving it again in Z.

**The same ambiguity strikes a Z drop.** Lowering the cluster (`z 78 → 70`) answered with a bare
"TOO FAR" meant *too far away*, not too far down: the dials had shrunk into the distance behind the rim
opening. The fix was `x → -16` (54 cm from the eye, 6 cm behind the wheel plane) with a small `z` lift
back to 74, not a reversal of the Z move. When a height change is answered with a distance complaint,
close the X gap first; only move Z again if the report names height.

**Never drop the cluster into the lower dash fill.** The fill under the cluster occupies `X 0..18` up to
`Z 64`, so a pure Z reduction from `78 → 70` at `x 8` puts the dial's bottom (`~57`) inside that panel
and the gauges vanish again — the same occlusion as the reserved box, entered from below. Every Z move
below the fill's top edge must be paired with a forward move (`x` negative) so the cluster sits in the
gap between fill and wheel.
