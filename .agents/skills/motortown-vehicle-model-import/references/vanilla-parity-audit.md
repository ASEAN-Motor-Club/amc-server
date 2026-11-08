# Auditing a finished mod car against a vanilla car

Use when the ask is "what's different about ours compared to a normal car" / "is anything broken on
our model". The answer is an asset-level diff, not an opinion: inventory what a vanilla body mesh
carries, then say which of those functions the mod car cannot have.

## 1. Read the vanilla body mesh's material slot table

No dump needed — the material references are strings in the cooked `.uasset`:

```bash
cd mt-pak-extract-wt-<ver>
bash /opt/data/scripts/mtextract.sh MotorTown/Content/Cars/Models/<Vanilla>/Body
strings -n 6 Body.uasset | grep -E '^/Game/|^M_|^MI_' | sort -u
```

Verified inventory for `Tuscan` (v0.7.19), 8 slots:

| slot | package | purpose |
|---|---|---|
| `M_Body` | `/Game/Cars/Materials/Body/` | the paint — driven by the colour system |
| `M_Glass_Base` | `/Game/Cars/Materials/Windows/` | glazing (the MASTER, not an instance) |
| `M_Internal_Glass` | `/Game/Cars/Materials/Windows/` | interior-facing glass |
| `M_HeadLight` | `/Game/Cars/Materials/` | lamp faces |
| `M_TailLight` | same | lamp faces |
| `M_TurnSignalLight` | same | lamp faces |
| `M_ReverseLight` | same | lamp faces |
| `M_Palette` | `/Game/Cars/Materials/Palette/` | palette atlas for interior/detail |

Also worth reading on the vanilla BP: `/Game/DataAsset/StringTables/VehicleBodyColorSlot` (paint slot
map) and the dome-light part refs (`Cars/Parts/InteriorLight/DomeLight`, `FrontDomeLight`).

## 2. Diff against the mod body

The typical mod body carries 3–4 slots: a private paint MIC, one or two interior materials, glass.
Every vanilla slot that has no counterpart is a missing FUNCTION, not a cosmetic nicety:

- **No lamp materials** → headlights, tail lights and indicators stay body paint: they never glow and
  never change with the light switch. This is a real behavioural gap, not a texture problem, and cannot
  be fixed by recolouring — the faces have to be split onto lamp slots and bound to the vanilla
  materials.
- **Private paint MIC instead of `M_Body`** → respray/garage colour does nothing. The paint path is
  `M_Body` + `BodyMaterialNames`/`ColorSlots` on the part row (see the paint pitfall in SKILL.md).
- **No `M_Palette` and zero UVs** → every authored face samples one texel; the cabin is flat colour no
  matter which instance is bound. This is the root cause behind "still flat / still grey" loops: a
  colour swap can never add detail that has no UV coordinates to land on.
- **One glass material for both sides** → vanilla uses `M_Internal_Glass` for the cabin face; a single
  outward pane is still the right call for a one-off mod mesh (see the glazing section), but say that it
  is a deliberate simplification rather than parity.

## 3. Non-material differences worth reporting

- **Collision is still the donor's.** A body mesh swap does not change the physical hull; the BP root,
  mirror aim and seat anchors are the donor's, so the car collides like the vehicle it replaced.
- **No replaceable parts.** Vanilla cars have part rows and separate meshes for bonnet / bumpers /
  spoilers / skirts (`PartType` in `VehicleParts_parsed.json`). A mod body has nothing to fit.
- **Seat and mirror component counts** come from the donor BP (e.g. `MTSeatComponent` ×4 on Tuscan vs
  ×2 on a two-seater donor). Comparing the `Data.Exports[]` class histogram of the two
  `out/<Vehicle>_parsed.json` files is a one-command structure diff:
  `Counter(e.get('ObjectClass') for e in d['Data']['Exports'])`.
- **LODs**: a single authored mesh is one LOD; do not claim vanilla has more without checking.

## 4. Finding the row that actually owns a blueprint

RowNames are often numeric, so search by the class package rather than by name:

```python
for r in rows:                      # walk Vehicles_parsed.json
    vc = r.get('VehicleClass') or {}
    if '<Model>' in str(vc.get('package','')):
        print(r['RowName'], vc)     # e.g. Spider -> RowName "4", /Game/Cars/Models/Spider/Spider
```

Same for `VehicleParts_parsed.json` when checking wheel/part rows (`Spider`, `Tuscan_01`).

## 5. Reporting shape

Give the user the diff in two blocks — "what vanilla has that ours cannot do" and "what is verified
fine" — and end with the cheapest tests that would confirm the functional gaps in game (light switch at
night, a respray, walking into a front corner for the collision mismatch). Do not pad the list with
cosmetic wishes; the value of the audit is that each line is a real capability difference.
