# Moving components on a cooked blueprint without a schema

Why: the writer (UAssetAPI) needs the parent blueprint class schema, which `Mappings.usmap` does not
carry (C++ classes only), so `--clone-asset` / `--patch-named-exports` / `--roundtrip` all abort on
vehicle blueprints. The *bytes* need no schema, so positions can still be rewritten.

UE5 large-world coordinates store `FVector` as **three float64**, contiguous (24 bytes) inside the
export's serial data. Overwriting that triple changes `RelativeLocation` with the same property, same
size and an untouched header.

## Recipe

1. Get current values from `out/<Vehicle>_parsed.json` when the export parsed. Exports that print
   `parse failed` (BP-class parent) serialise no properties, so scan the export's serial range for a
   plausible coordinate triple and unpack it exactly.
2. Convert serial offsets to `.uexp` offsets: `SerialOffset` is relative to the combined stream, so
   `uexp_off = SerialOffset - len(<Vehicle>.uasset)` (C7: `0x42C1`). Slice the export's
   `SerialOffset`/`SerialSize` pair, never the whole file.
3. **Require exactly one hit per pattern** before writing. Refuse on 0 or >1 — a stray two-hit vector
   silently relocates the wrong component. Sibling components differ only by sign (left/right), so
   their triples stay unique.
4. Patch a copy, then prove it: assert the file length is unchanged, re-unpack the triples at the
   patched offsets, and confirm the `.uasset` half is byte-identical to the source.

Values are centimetres in vehicle-local space: `+X` forward, `+Y` right, `+Z` up.

Runner: `scripts/patch_bp_vectors.py <cfg.json>` — enforces step 3 and the step 4 assertions.

## What it unlocks

`Wheel0..3`, `HeadLight_Left/Right`, `BlinkerLight_01/02`, `TaliLight_01/02`, `Mirror`s, `RoomMirror`,
seats, camera spring-arm positions.

## What it does not

Adding or removing components, changing mesh *references* (import indices), openable doors, gauges.
Those are structural: the asset has to arrive by overriding an existing package instead, and a wheel
swap is a part-row data job (see `wheel-substitution.md`).

## Pre-flight checks

- Exports whose `SerialSize` is ~10 bytes (e.g. `ReverseLight_01/02`) carry **no** vector: check the
  export table and skip them instead of hunting for a triple that is not there.
- Identify exports from the `.uasset` export table dump, not from the parsed JSON's array index — the
  two orders differ, so index-aligning them attributes meshes to the wrong component.
