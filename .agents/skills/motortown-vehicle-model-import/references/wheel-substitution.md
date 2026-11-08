# Swapping a vehicle's wheels for an in-game set

Why this exists: a wheel mesh you import arrives with **no collision**, and the game's wheels are what
contact the road. A car on imported wheels idles fine, revs, the tyres screech — and it does not move,
because there is no contact. Collision cannot be added from a headless commandlet (see the collision
pitfall in SKILL.md), so the cheap correct route is to keep the game's own wheel meshes and only change
*which* ones.

## Symptom → cause table

| Behaviour | Cause |
|---|---|
| Body renders, wheels spin, tyre screech, car never moves | wheel meshes have no collision — no ground contact |
| Body renders as stretched garbage, no collision anywhere | the body mesh's collision is missing too (same root cause) |
| Drives and collides, but stance/wheels look wrong | vanilla wheels on a dimensionally honest body — the donor's track/wheelbase is wider/longer |

Bisect before fixing: ship **shell only** (vanilla wheels, vanilla blueprint) first. If that drives, the
mesh and the pak pathing are sound and the fault is confined to your wheel/blueprint changes.

## Matching by dimension, not by eye

In-game wheels are modelled 1:1 against the real car they depict, so match the model's wheel to the
real tyre of an equivalent-era vehicle instead of guessing from screenshots.

1. Measure your part: `scripts/gltf_to_ue.py` prints per-part size and wheel radius. Diameter =
   `2 * radius`; width comes off the same table (`Y` extent of the wheel part).
2. Convert to a tyre size (a 74.6 cm wheel is a 225/70R15, i.e. period American 15-inch).
3. Pick the donor whose real car ran that tyre and whose rim style suits the body.

Worked example — a 1963-67 sports car with 74.6 cm / 22.8 cm wheels:

| Donor | Wheel part / meshes | Real tyre | Ø | Verdict |
|---|---|---|---|---|
| Stinger ('69 Camaro) | `Stinger_FL/FR`, `Stinger_RL/RR` | F70-15 | ~73.7 cm | within 1 cm, ~2 cm narrower |
| Tuscan ('69 Nova) | `Tuscan_01_L/R`, `Tuscan_02_L/R` | F70-15 | ~73.7 cm | two rim styles to choose from |
| Cervos ('64 Impala) | `Classic_01_L/R` | 8.20-15 | ~76 cm | slightly bigger, more sidewall |
| Duke ('87 GNX) | `Duke_L/R` | 215/65R15 | ~68.6 cm | too small |
| Vista / Zino | `Vista_L/R`, `Zino_L/R` | 15-16" | 65-69 cm | too small for a large body |

## Showing the user the candidates before committing

The user usually picks by look, and the rim design is not in the parsed data. Official renders are on
the Motor Town Fandom pages, but `static.wikia.nocookie.net` answers a plain `curl` with a Cloudflare
"Just a moment..." challenge page (HTML saved under a `.png` name — check the first bytes, not the exit
code). Two-step workaround, no browser needed:

```bash
# 1. the original image URL from the wiki API
curl -sS "https://motortown.fandom.com/api.php?action=query&format=json&prop=pageimages\
&piprop=original&titles=Stinger%7CTuscan"
# 2. fetch the bytes through a rendering proxy
curl -sSL -o stinger.png \
  "https://images.weserv.nl/?url=static.wikia.nocookie.net/motortown/images/3/3e/MT-Stinger-Front.png&w=1000"
```

Then crop to the wheel and upscale before sending — a 1000 px car shot hides the rim. Two candidates
that recur for 60s-70s American bodies: **Stinger = chrome five-spoke alloy** (matches a modelled
five-spoke almost exactly), **Tuscan = flat styled-steel wheel with a hubcap**, no visible spokes.
Send both and let the user choose; do not pick on their behalf when the difference is purely visual.

## Finding the meshes and the rows

Every wheel in the game is a VehicleParts row with `PartType: "Wheel"` (~93 rows in 0.7.19) carrying:

```json
"Wheel": { "LeftWheelMesh":  {"Path": "/Game/Cars/Parts/Wheels/Stinger_FL/Stinger_FL"},
           "RightWheelMesh": {"Path": "/Game/Cars/Parts/Wheels/Stinger_FR/Stinger_FR"},
           "RearLeftWheelMesh": null, "RearRightWheelMesh": null,
           "DRWLeftWheelMesh": null, "QuadWheelMesh": null }
```

Enumerate candidates from `out/VehicleParts_parsed.json` rather than hardcoding names — families are
shared (`Classic_01_L/R` serves several 60s cars), variants use `_01`/`_02` suffixes for trim levels, and
the path is package+object, never a directory pair.

## Route A: the part row (writes fine; no observed effect in game)

Wheel meshes hang off the **part row** the vehicle's `Parts` map points at, so the vanilla-shaped
substitution looks like a data job:

1. Clone the donor's wheel row into the child VehicleParts table.
2. Point `Wheel.LeftWheelMesh` / `RightWheelMesh` at the meshes you chose (keep the vanilla import
   refs where they already match — a row with zero import delta is the safest kind).
3. Point the vehicle row's `Wheel0..3` part slots at the cloned row.

**Status: not sufficient on its own.** Rewriting the vehicle's own wheel row on the *base*
`VehicleParts` asset (768 rows, ~418 KB `.uexp`) writes cleanly — import indices in the row change,
row count intact, pak builds, game boots — and the car still wears the vanilla wheels. The base table
is therefore not the override point. Probe these next, cheapest first, and confirm each on screen
before building the next:

- **(a) Delta table.** Ship the cloned row in `VehicleParts0` (~24 KB, the table mods append to) rather
  than the base. Does not contain a wheel row for an existing vehicle today, so the row must be
  constructed/cloned rather than patched in place.
- **(b) Wheel package override.** See the last section.

Do not re-ship the base-table variant hoping for a different result.

## Route B: retarget the blueprint's wheel meshes (valid write, inert for the visual)

Patch the `StaticMesh` reference on the four `MHWheelComponent` exports. This *does* write, provided
the parent blueprint is beside the target (see "Blueprint writes need the parent schema beside the
asset"), and the write verifies structurally: new package + `StaticMesh` imports appear in the
table, the row's index bytes move, the asset loads, and the component's other float edits in the same
asset demonstrably apply (moved wheels sit where you put them). The wheels still render as the
vanilla meshes, so the game reassigns the wheel mesh from the parts data at runtime — this route alone
never changes what you see. Config shape per export:

```json
{"output_filename":"Spider","exports":[
 {"export_name":"Wheel0","patches":[
   {"op":"set_import_ref","path":"StaticMesh","class_package":"/Script/Engine",
    "class_name":"StaticMesh","package_path":"/Game/Cars/Parts/Wheels/Tuscan_01_R",
    "asset_name":"Tuscan_01_R"},
   {"op":"set_vector","path":"RelativeScale3D","x":0.746,"y":0.746,"z":0.746}]}]}
```

Two numbers decide whether it looks right, and neither is the donor's:

- **Which component is which corner.** `Wheel0..3` are not consistently ordered across the fleet. Read
  each export's `RelativeLocation` out of the parsed JSON, or locate the float64 triples in the `.uexp`
  and attribute them by `SerialOffset - len(<Vehicle>.uasset)`: for the `Spider`, `Wheel0`/`Wheel2` are
  right (`Y > 0`) and `Wheel1`/`Wheel3` left. Getting this backwards mirrors the rims.
- **Scale.** Wheel meshes are authored at roughly **1 m**, and each vehicle's wheel components scale them
  to the real tyre: `Spider` 0.79, `Cervos` 0.78, `Stinger` 0.72 front / 0.78 rear, `Tuscan` 0.595. So set
  the scale to the **target diameter in metres** (`0.746` for a 74.6 cm wheel) rather than carrying the
  donor's factor across — a straight mesh swap at the donor's scale renders at the wrong size. Verify the
  write by diffing the `.uexp` bytes against the source; the value stores as a float-precision double
  (`0.74599999…`), so searching for an exact `0.746` triple finds nothing and looks like a failed patch.

**The blueprint's wheel meshes are not necessarily that vehicle's own.** The `Tuscan` blueprint mounts
`Stinger_FL/FR/RL/RR`; `Tuscan_01_L/R` exist only as optional part rows. Read the blueprint's wheel
components for what actually ships and the parts table for what is available, and never assume
`<Vehicle>_L` is what `<Vehicle>` wears.

## Route C: override the wheel package asset — CONFIRMED ON SCREEN, use this one

Mesh overrides at `Cars/...` demonstrably load — an overridden `Cars/Models/<Vehicle>/Body` renders —
so the one path the game cannot ignore is the wheel asset itself. Take a vanilla wheel mesh and rename
it into the vehicle's own wheel package:

```json
{"old_name":"Tuscan_01_L","new_name":"Spider_L",
 "new_path":"/Game/Cars/Parts/Wheels/Spider_L","import_replacements":[]}
```

```bash
bash uasset.sh --clone-asset clone_L.json Tuscan_01_L.uasset out/   # -> out/Spider_L/Spider_L.{uasset,uexp}
```

Why it is worth a shot: only the name map is rewritten (path and object name), so the `.uexp` comes out
byte-identical — the vanilla mesh's collision and render data travel with it, which is exactly what an
imported wheel lacks. Stage it at `Cars/Parts/Wheels/Spider_L.uasset` / `Spider_R.uasset`.

**Result in game: wheels render as the donor, and the car drives** — the donor's collision travels with
the renamed package. This is the route to use; Routes A and B are the two dead ends that preceded it.
The clone is safe here because it rewrites the name map only (the `.uexp` stays byte-for-byte the same
size, 49,056 B for a Tuscan wheel) — that is a rename, not the payload round-trip the "never
re-serialize" rule forbids.

**Then fix the size with the component scale.** The swapped mesh keeps the host blueprint's
`RelativeScale3D`, which was tuned for the host's own mesh, so the first look is reliably the wrong
diameter (a Tuscan mesh under the C7's 0.79 renders visibly oversized against a 74.6 cm target). The
donor's authored size is not published, so converge by eye and **ship two paks that differ only in that
number** (e.g. 0.70 and 0.62, 11% and 22% down) rather than guessing one at a time; the 12 changed
bytes (4 wheels × 3 axes) are the proof that nothing else moved. Once the user picks, back out the
implied authored diameter (`observed_ok_scale` × target diameter − here 0.70 × 74.6 cm ⇒ mesh is
~1.07 m) so the next donor does not need the same iteration.

The scale patch itself adds **no imports**, so the blueprint that carries it stays loadable — unlike the
mesh-reference swap in Route B.

## When the user insists on their own wheel mesh

Say the cost plainly: it needs collision authored in the editor GUI (Collision → Add Box Simplified, or
Convex Decomposition, per mesh, Save) before the car will drive, and that step cannot be done from a
headless commandlet. Ship the in-game wheel version first so the vehicle is drivable, and treat custom
wheels as a later pass.
