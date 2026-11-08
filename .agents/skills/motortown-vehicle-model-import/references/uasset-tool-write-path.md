# UAssetTool write path (mt-pak-extract worktree)

How to run the C# asset tool and patch cooked assets without tripping the writer's limits. Verified
against the 0.7.19 worktree; the tool lives at
`csharp/UAssetTool/bin/Release/net8.0/UAssetTool(.dll)` with mappings at `Mappings.usmap`
(a symlink into `versions/v<ver>/`).

## Running it: env belongs in a script, never on the command line

The container has no dotnet on PATH. Inline `DOTNET_ROOT=… dotnet …` is an approval-gate CRITICAL
(see `approval-safe-execution`), so keep it in `scripts/uasset.sh` and call `bash scripts/uasset.sh …`.

Two details that cost time:

- `DOTNET_ROOT` must be **`$SDK/share/dotnet`**, not the store path itself — the apphost looks for
  `host/fxr` under it and otherwise reports "You must install .NET … Failed to resolve libhostfxr.so".
- Invoke the **`.dll` through `dotnet`** rather than the apphost binary; that skips the native-library
  dance (ICU/OpenSSL/gssapi) on the apphost entirely.
- Store paths get garbage-collected. Resolve the SDK at run time (`ls -d /nix/store/*dotnet-sdk-8*`,
  skip `.drv`, check for `share/dotnet/host/fxr`) instead of hardcoding a hash.

## Modes (arg order matters)

| mode | args | use |
|---|---|---|
| dump | `--dump <abs asset>` | imports/exports listing; the cheap ground-truth read |
| roundtrip | `--roundtrip <in> <out>` | writer smoke test — prints `identical=true/false` |
| patch rows | `--patch-rows cfg.json <template> <outdir>` | DataTable row edits |
| clone asset | `--clone-asset cfg.json <template> <outdir>` | new package from an existing asset |
| patch exports | `--patch-named-exports cfg.json <template> <outdir>` | per-export property edits |

## `--patch-named-exports` config

```json
{"output_filename": "Adder",
 "exports": [
   {"export_name": "Wheel0",
    "patches": [{"op": "set_vector", "path": "RelativeLocation", "x": 145.8, "y": 80.7, "z": 37.5}]}]}
```

- The key is **`export_name`**. `"export"` throws `KeyNotFoundException` from a bare
  `GetProperty` — a crash, not a validation message.
- Dotted paths resolve through structs only one level in practice: `RelativeLocation.X` reports
  *"Property 'RelativeLocation.X' not found"*. Patch the whole struct with `set_vector`
  (`{x,y,z}`) / `set_vector2d` instead.

**A patch on a property the export does not have is a silent no-op.** `set_vector` (and the other
setters) print `Patched export: <Name>` and the run ends with `Patched N exports` even when nothing was
written — the property simply is not there, and unlike `set` it does not create it. Always re-dump the
written asset and confirm the property now appears in its `Properties (N)` list, and compare the
`.uexp` against the source: a real `set_vector` shows one short run per vector, a no-op shows *no*
diff at all (file size identical either way, so size is not the test). Cooked component exports are
routinely this bare — a `StaticMeshComponent` can be 37 bytes holding only its mesh import and attach
parent. When the property is absent, look for a sibling property that *is* a vector (a mesh-offset field
on the owner component), an object property you can `null_ref`, or a parent component whose
`RelativeLocation` moves the child with it.

## Patch ops worth knowing

`set` (scalar; auto-creates a missing int/float/bool leaf), `remove`, `set_enum`,
`set_enum_array`, `set_string`, `set_name`/`set_name_array`, `set_vector`, `set_vector2d`,
`set_import_ref` / `set_or_create_import_ref` (`class_package`, `class_name`, `package_path`,
`asset_name`; add `use_existing_import: true` with `asset_name`+`class_name` for a zero
import-table delta, `add_cdo_import`, `dedupe_imports`), `set_soft_ref`, `set_soft_object`,
`null_ref`, `add_map_entry`, `set_map_entries`, `set_name_int_map`, `clear_map`, `clear_array`,
`append_struct_clone`, `append_import_to_array`, `add_gameplay_tags`, `clear_tags`,
`set_or_add_float`, `set_or_create_name`.

## `--clone-asset` config and its one trap

Keys: `new_name`, `new_path`, `old_name`, `rename_exports`, `rename_imports`, `fname_number`,
`import_replacements[]` (`match_class`, `match_name`, `new_package_path`, `new_name`,
`import_index`, `replace_all`), `export_patches[]` (`match_export`, `match_class`,
`match_occurrence`, `patches[]`).

**Step 4 rewrites every NameMap entry containing the old name unconditionally** — the
`rename_exports` / `rename_imports` flags gate steps 2 and 3 only. Cloning `Spider` therefore also
rewrites `/Game/Cars/Parts/Wheels/Spider_L` to `.../Barracuda_L`, i.e. it silently mutates paths to
*other* assets that merely share the substring. Check the printed `Renamed NameMap[...]` lines and
patch those imports back explicitly, or pick a clone strategy that never rewrites names.

Those prints are also **not** the package path: a clone can report
`Renamed NameMap[16]: /Game/PolygonTown/Materials/M_<Mod>_Body` while the asset's real `FolderName` is
the `/Game/Cars/Models/<V>/M_<Mod>_Body` you asked for. Judge placement by the `FolderName:` line in a
`--dump` of the written file (and by the pak entry you stage), never by the rename log, or you will
"fix" a path that was already correct.

## The wall

Any write whose export has a **blueprint class** as its parent or class fails at
`GenerateUnversionedHeader` with `Failed to find a valid schema for parent name <BPClass>_C`, because
`Mappings.usmap` contains C++ classes only. Confirmed for `--clone-asset`, `--patch-named-exports`,
and `--roundtrip` on a cooked vehicle blueprint, whose light components (`TaliLight_01_C`,
`BlinkerLight_01_C`, `FrontDomeLight_C`) and root parent (`MTVehicleBaseBP_C`) are blueprint classes.

The wall is **a missing sibling file, not a property of the asset**: put the parent blueprint
(`MTVehicleBaseBP.uasset` + `.uexp`) in the same working directory and the identical
`--patch-named-exports` run writes cleanly. Confirm the parent path from the target's own Package
import (`--dump`), not from a guess. Only a genuinely *new* blueprint class still needs editor
authoring; existing cooked blueprints are writable this way.

Writes re-serialise **every** export in the package, including the donor's inherited BP-class
components (`TaliLight_02_GEN_VARIABLE` prints a schema warning even on a clean run) — read the output,
but do not treat that warning as the cause of a downstream symptom. Check what actually moved by
diffing the `.uexp` against the source: a `set_vector` patch should show 4 bytes × 3 axes × one run per
export and nothing else.

## StringTables are not writable by the tool — splice the `.uexp`

`DataAsset/StringTables/<Table>` (e.g. `VehicleName`) parses as a `StringTableExport` with **zero
properties**; the entries are custom-serialised in the `.uexp`, so `--patch-named-exports`,
`--patch-export-props` and `--patch-rows` all have nothing to address and no `set_string` will reach
them. Patch the bytes:

- layout: `<FString table name>` then `int32 count`, then `count` × (`FString key`, `FString value`),
  each FString being `int32 len` (including the NUL) + chars + `\0`;
- replacing a value with a different-length string changes the file size, so **also bump that export's
  `SerialSize` int64 in the `.uasset`** by the same delta (find the old value as a little-endian int64;
  assert exactly one hit before writing);
- verify by re-parsing the patched `.uexp` (row count unchanged, the row reads the new value) **and again
after extracting it back out of the built pak**.

Verifying a pak payload: `pakextract <pak> <entry-name>` takes *entry names only* and drops each file at
`./server_extract/<basename>` — it does not accept an output directory, and passing one produces a
misleading `FAIL … No entry found at <path>`.

## `--patch-export-props` (single export, no export name needed)

`--patch-export-props cfg.json <template> <outdir>` patches the **first NormalExport** of the package,
so no `export_name` is required. Config shape: `{"output_filename": "out", "patches": [...]}` — the
output file is named from `output_filename`, the export keeps its original name, so rename the pair on
copy if the pak needs the canonical name.

Use it for the glTF material fix: an Interchange-imported material is a MaterialInstanceConstant whose
`Parent` points at the editor-only `/InterchangeAssets/gltf/MaterialInstances/MI_Default_Opaque`.

```json
{"output_filename": "out",
 "patches": [{"op": "set_or_create_import_ref", "path": "Parent",
              "class_package": "/Script/Engine", "class_name": "Material",
              "package_path": "/Game/Cars/Materials/Body", "asset_name": "M_Body"}]}
```

The class must be `Material` (not `MaterialInstanceConstant`) and the package is the one the vanilla
body imports — confirm with `--dump` on the vanilla asset instead of guessing. Verify by re-dumping the
written file: the import table should list the package plus `M_Body`, and the export name must be
unchanged. Note this only fixes the *asset*; whether the game then shades it correctly is a separate
test.

## Same-basename assets are a copy hazard

Cooked output is easy to copy around by filename, but packages that live in different folders can share
a basename (a body material and a wheel material, both `M_<Mod>_Body`, differing by a few bytes).
Enumerate cooked files as `<package path>` → bytes and move them by package path; a basename copy
silently substitutes one for the other and no tool will object.

## Collision is not writable from a commandlet

Interchange-imported meshes arrive with `get_simple_collision_count` `-1` and section collision
disabled. In a `-run=pythonscript` commandlet `get_editor_subsystem(unreal.StaticMeshEditorSubsystem)`
returns **None** (`AttributeError: 'NoneType' object has no attribute 'get_simple_collision_count'`),
and the deprecated `EditorStaticMeshLibrary.add_simple_collisions` returns `-1` for box/sphere/capsule
while `set_convex_decomposition_collisions` returns `False`. Neither raises, so a script can look
successful while changing nothing — always read the counts back. Collision has to be arranged at import
time or in the editor GUI.

**The failure is not confined to the exports you patch.** Writing re-serializes every export in the
package, so one unrelated BP-class component poisons the whole write: patching only `Mesh` and
`Wheel0..3` on the donor blueprints still aborts on the vanilla light components. Do not read a
short patch list as a small blast radius, and do not explain the failure to a user as "our mesh
has bad lights" — the offending exports are inherited from the donor, and the model under import
contributes no lights at all.
