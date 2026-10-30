---
name: motortown-strap-points
description: How Motor Town makes an actor strap-able/winch-able (WheelStrapPoint tag, MTStrapComponent) and how third-party attachment paks replicate it
---

# Strap points and winch-able actors in Motor Town

## When to use

Building or auditing an attachment/carrier mod pak that needs to hold a vehicle
down (flatbed, rollback, car hauler, tow dolly), or answering "how does this pak
make X strappable". Companion to `mt-mod-update` (pak shipping) and
`motortown-upgrade` (game binary).

## The vanilla hook: a component tag, not a property

The game finds strap anchors through `ComponentTags`, not through a bool or a
dedicated component class. Any component on the actor whose tags include
`WheelStrapPoint` is treated as a strap anchor for that actor.

Verified in the 0.7.19 client pak (dumps below):

- `Trailer_SPT1` — the `MTVehicleRootComponent` named `Body` carries
  `ComponentTags: [WheelStrapPoint]`; a second component carries
  `[LightMaterial, WheelStrapPoint]`.
- Same tag present on `Longhorn_Rollback`, `Kira_Rollback`, `Lomax`, `Carry`.
- Vanilla carriers use **no** `PhysicsConstraintComponent` of their own — the
  strapping is native C++ (`MTStrapComponent`), so a vanilla vehicle is
  strap-able purely by being a vehicle with tagged anchors.

Native classes involved (all present in `Mappings.usmap`, i.e. real engine-side
API, not mod convention): `MTStrapComponent`, `MTTowingComponent`,
`MTWinchComponent`, `MTTowRequestComponent`, `MTTowRequestFlags`,
`MTVehiclePartWinch`, `MTConstraintOwner`, `MTPlayerDataWheelStrap`,
`MTSaveGameWorldVehicleWheelStrap`.

The player-facing entry points are item-row enums
(`EMotorTownInteractableType::AttachWinch`, `::StrapCargo`) plus the row fields
`InteractionType`, `InteractionTargetActorClasses`,
`InteractionTargetComponentClasses` — an item that "straps" targets the actor
classes named there.

## How a third-party pak (Slides_Attachments) implements it

A plain `Actor` blueprint cannot use the vehicle-only C++ strap stack, so that
pak re-implements the behaviour in blueprint. Confirmed by dumping the BPs:

**`BP_PXS_CarHauler`** (SuperStruct = `Actor`) — hand-rolled strap model:
- Deck anchors are `BoxComponent`s each tagged `WheelStrapPoint`:
  `StrapDeckL`, `StrapDeckR`, `StrapTailL`, `StrapTailR`.
- Deck collision volumes for the load: `FloorL/R`, `FloorRampL/R`,
  `FloorTailL/R`, `WalkDeck`, `WalkFlap`.
- 11 `PhysicsConstraintComponent` references; the graph reads
  `GetPhysicsLinearVelocityAtPoint` / `GetPhysicsAngularVelocityInDegrees` at
  the anchors and calls `BreakConstraint` when the load tears off.
- Author properties that parameterise it: `StrapMassKg` (double, mass budget
  per strap), `StrapEach` (double), `bShareStrapBody`, `bConstrainStraps`,
  `bConstrainFloors`, `bConstrainTail`, `bWeldFloors`, `Welded`, `WeldRel`,
  `TailConCount` / `TailConFails` / `TailConLost` / `TailConstrained`.
  None of these are in the vanilla usmap — they are the author's own fields.

**`BP_PXS_TowBed850` / `BP_PXS_Underlift`** — do not reimplement; the graph
casts to the host vehicle's native `MTWinchComponent`, `MTTowingComponent` and
`MTVehiclePartWinch` and drives them (winch the car up and hold it). This is the
cheap path when the attachment is mounted on a tow-capable vehicle.

**`BP_PXS_TowDolly`** — polls its tick graph with `ComponentHasTag` against the
`wheel_hubs` component tag to track the carried vehicle's wheels.

**Item registration** — attachments are listed in the pak's own
`Items_SlidesAttachments` DataTable, which is merged into the vanilla `Items`
composite parent (the merged parent still lists `Items_Drones`, `Items_Etc`,
`Items_Foods`, `Items_Furnitures`, `Items_Module`, `Items_Building` plus
`Items_SlidesAttachments`, `Items_SlidesDashboards`, `Items_MajasDetailWorks`).
Shop availability comes from the two overridden vendor BPs
(`Vendor_Cafe`, `Vendor_FlowerShop`), which gain the attachment class refs.

**Strap plate** — that pak's Items table references
`Attachment_SSP_StrapPlate` / `/Game/SlidesStrapPlate/Blueprints/BP_StrapPlate`
but the file is **not shipped in the pak**: it is a bolted-on plate from a
companion Slides pak. That is the general-purpose answer to "make an arbitrary
attachment strap-able" — ship a plate attachment that carries the
`WheelStrapPoint` tag, mount it on the thing, and the native strap logic finds
it. It could not be inspected here because it is not in this pak.

## Recipe for our own attachment

1. Add a Scene/Box component at each anchor position and set
   `ComponentTags = ["WheelStrapPoint"]`. Vanilla density: 1 anchor on a plain
   trailer root, 3–4 on rollbacks (deck + tail).
2. If the carrier is a real vehicle blueprint, that is all that is needed — the
   native `MTStrapComponent` does the rest.
3. If the carrier is a plain Actor (attachment), the native component will not
   run on it: either parent it to a vehicle class, or replicate the model —
   physics constraint per anchor, mass budget, break-on-tear — the way
   `BP_PXS_CarHauler` does.
4. For a car to be *picked up* rather than strapped, drive the host vehicle's
   `MTWinchComponent` / `MTTowingComponent` instead of writing new physics.
5. Register the row in the Items composite table and add the class to the
   vendor BP buy list; keep the row out of `Items_Furnitures` or other child
   tables other AMC paks already patch.
6. Boot-test — tags alone do not prove the interaction prompt appears.

## Verification commands

Extract + dump (container paths used by AMC pak work):

```bash
R=/opt/data/workspace/mt-pak-extract-wt-fmt/target/release
LD_LIBRARY_PATH=$R:/nix/store/*-gcc-13*-lib/lib $R/mod_explore MyMod.pak --list
LD_LIBRARY_PATH=$R:/nix/store/*-gcc-13*-lib/lib $R/mod_explore MyMod.pak --extract-all
# libstdc++ must be on the loader path or Oodle init fails ("Oodle loader error")

D=/nix/store/*-dotnet-sdk-8.0.416
cd <scratch-root>/csharp/UAssetTool   # cwd matters: RootDir = ../../, Mappings.usmap at <root>/
DOTNET_ROOT=$D $D/bin/dotnet UAssetTool.dll --dump /abs/path/Asset.uasset
```

Fast checks:
- `grep -c WheelStrapPoint <dump>` — anchors on the actor.
- `grep -c PhysicsConstraintComponent <dump>` — 0 means the game straps it
  natively; >0 means the pak hand-rolls the constraint.
- `grep -a -c <Name> Mappings.usmap` — 0 means the identifier is the author's,
  not engine API. (Tags never appear in a usmap, so a tag's absence proves
  nothing — check vanilla assets for the tag instead.)

## Caveats

- `Slides_Attachments_P.pak` (sha256 `580f8a7f…d53e01`) is **built for the
  0.7.20 test update**; the dumps above were read with 0.7.19 mappings, so its
  Items rows did not parse (`unknown property at schema index 56 in MTItemRow`)
  and per-row values are unverified.
- Tag semantics are inferred from vanilla assets plus native class names. The
  consumer is C++ (`MTStrapComponent`); nothing here comes from decompiled
  engine code.
