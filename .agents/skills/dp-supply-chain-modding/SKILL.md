---
name: dp-supply-chain-modding
description: Runtime delivery point injection, supply chain configuration, and delivery system internals for Motor Town
---

# Delivery Point & Supply Chain Modding

Inject custom delivery points at runtime via UE4SS Lua mod, configure cargo acceptance, and understand the Motor Town delivery system internals.

## Overview

The Motor Town delivery system manages cargo production, storage, and delivery between delivery points (DPs). Each DP is an `AMTDeliveryPoint` actor with properties that define what it produces, stores, and accepts. The delivery system (`AMTDeliverySystem`) orchestrates delivery missions between DPs.

### Key Actors

| Actor | Role |
|-------|------|
| `AMTDeliverySystem` | Singleton orchestrator — owns `DeliveryPoints`, `SupplyAndDemands`, `Deliveries` arrays |
| `AMTDeliveryPoint` | Individual delivery point — defines cargo production, storage, and acceptance |

### Runtime Injection vs PAK Mod

| Approach | Pros | Cons |
|----------|------|------|
| **Runtime Lua injection** (this skill) | No PAK needed, hot-reloadable, works with existing Blueprints | Must copy `Net_InputInventory` from reference DP, limited to existing Blueprint classes |
| **PAK mod** (see `cargo-mod` skill in mt-pak-extract) | Custom Blueprint subclasses, baked CDO configs, full control | Requires build pipeline, server restart to load |

## Runtime Delivery Point Injection

### Quick Reference

```lua
-- 1. Spawn the actor
local actor = SpawnActor("/Game/Objects/Mission/Delivery/DeliveryPoint/Farm_Corn.Farm_Corn_C", location, rotation, tag)

-- 2. Generate GUID
actor:GenerateDeliveryPointGuid()

-- 3. Register with delivery system
ds.DeliveryPoints[#ds.DeliveryPoints + 1] = actor
ds.SupplyAndDemands[#ds.SupplyAndDemands + 1] = actor

-- 4. CRITICAL: Copy Net_InputInventory.Entries from reference DP
refDP.Net_InputInventory.Entries:ForEach(function(idx, elem)
  actor.Net_InputInventory.Entries[#actor.Net_InputInventory.Entries + 1] = elem:get()
end)
```

### Complete Implementation Pattern

The injection must happen at the right time in the boot sequence. The delivery system populates `Net_InputInventory.Entries` during its `BeginPlay` init, and a runtime-spawned DP misses that step.

**Timing**: Use `RegisterBeginPlayPreHook` on `AMTDeliverySystem` to catch the delivery system's `BeginPlay`, then defer `SpawnActor` to the next game tick via `ExecuteInGameThread`.

```lua
if os.getenv("MOD_AUTO_INJECT_DP") then
  local injectDone = false

  local function doInject()
    if injectDone then return end
    injectDone = true

    local ds = GetDeliverySystem()
    if not ds:IsValid() then return end

    local assetManager = require("AssetManager")
    local assetPath = "/Game/Objects/Mission/Delivery/DeliveryPoint/Farm_Corn.Farm_Corn_C"
    local location = {X = -289988, Y = 201790, Z = -21950}

    -- SpawnActor needs UGameEngine::Tick initialized, so defer via ExecuteInGameThread
    local spawned, assetTag, actor = assetManager.SpawnActor(assetPath, location, {Pitch=0,Roll=0,Yaw=0}, "DP_AutoInject")
    if not spawned or not actor or not actor:IsValid() then return end

    -- Verify it's a delivery point
    local dpClass = StaticFindObject("/Script/MotorTown.MTDeliveryPoint")
    if not actor:IsA(dpClass) then return end

    -- Generate unique GUID
    pcall(function() actor:GenerateDeliveryPointGuid() end)

    -- Find a reference DP of the same Blueprint class to copy from
    local farmClass = StaticFindObject(assetPath)
    local refDP = nil
    if farmClass and farmClass:IsValid() then
      ds.DeliveryPoints:ForEach(function(i, elem)
        local ref = elem:get()
        if ref and ref:IsValid() and ref:IsA(farmClass) then
          refDP = ref
          return true  -- stop iteration
        end
      end)
    end

    -- Register with delivery system
    ds.DeliveryPoints[#ds.DeliveryPoints + 1] = actor
    ds.SupplyAndDemands[#ds.SupplyAndDemands + 1] = actor

    -- CRITICAL: Copy Net_InputInventory.Entries from reference DP.
    -- Without this, the DP gets 0 receiver deliveries because the delivery
    -- system uses Net_InputInventory (not StorageConfigs) to match cargo.
    if refDP and refDP:IsValid()
      and refDP.Net_InputInventory:IsValid()
      and refDP.Net_InputInventory.Entries:IsValid()
      and actor.Net_InputInventory:IsValid()
      and actor.Net_InputInventory.Entries:IsValid()
    then
      refDP.Net_InputInventory.Entries:ForEach(function(idx, elem)
        actor.Net_InputInventory.Entries[#actor.Net_InputInventory.Entries + 1] = elem:get()
      end)
    end
  end

  -- Hook AMTDeliverySystem's BeginPlay (pre-hook fires before the system's own init)
  RegisterBeginPlayPreHook(function(Context)
    local actor = Context:Get()
    local dsClass = StaticFindObject("/Script/MotorTown.MTDeliverySystem")
    if not dsClass:IsValid() or not actor:IsA(dsClass) then return end
    -- Defer to next game tick — UGameEngine::Tick must be ready for SpawnActor
    ExecuteInGameThread(function() doInject() end)
  end)
end
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MOD_AUTO_INJECT_DP` | (unset) | Set to `1` to enable auto-injection at boot |
| `MOD_INJECT_DP_ASSET` | `Farm_Corn.Farm_Corn_C` | Blueprint asset path (package.object format) |
| `MOD_INJECT_DP_LOC_X` | `-289988` | X coordinate |
| `MOD_INJECT_DP_LOC_Y` | `201790` | Y coordinate |
| `MOD_INJECT_DP_LOC_Z` | `-21950` | Z coordinate |
| `MOD_INJECT_DP_TAG` | `DP_AutoInject` | Actor tag for identification |

## Delivery System Internals

### What Controls Cargo Acceptance

A delivery point's cargo acceptance is determined by **three layers**:

| Layer | Property | Purpose | Populated When |
|-------|----------|---------|----------------|
| **CDO** (Blueprint) | `StorageConfigs` | Defines what cargo types the DP can store | Baked into Blueprint at build time |
| **CDO** (Blueprint) | `ProductionConfigs` | Defines production recipes (input→output) | Baked into Blueprint at build time |
| **Runtime** | `Net_InputInventory.Entries` | Active inventory slots the delivery system uses for matching | Populated during delivery system's `BeginPlay` init |

**Critical**: The delivery system uses `Net_InputInventory.Entries` (not `StorageConfigs` or `ProductionConfigs`) to determine what cargo to send to a DP. A runtime-spawned DP has empty `Net_InputInventory.Entries` and will receive **zero** receiver deliveries until entries are populated.

### StorageConfigs

Array of `FMTDeliveryStorageConfig` — defines what the DP can store.

```json
[
  {"MaxStorage": 10, "CargoType": 3, "CargoKey": "None"},   // Generic pallet storage
  {"MaxStorage": 3,  "CargoType": 2, "CargoKey": "None"},   // Generic box storage
  {"MaxStorage": 5,  "CargoType": 0, "CargoKey": "Fuel"},   // Specific: Fuel (Tanker)
  {"MaxStorage": 0,  "CargoType": 0, "CargoKey": "QuicklimePallet"}  // Specific: Quicklime
]
```

| Field | Description |
|-------|-------------|
| `MaxStorage` | Maximum units of this cargo the DP can hold |
| `CargoType` | Enum: `0=Specific`, `2=Box`, `3=Pallet` |
| `CargoKey` | FName — specific cargo key (e.g. `"Fuel"`) or `"None"` for generic |

### ProductionConfigs

Array of `FMTProductionConfig` — defines production recipes.

```json
{
  "ProductionTimeSeconds": 600.0,
  "ProductionSpeedMultiplier": 2.0,
  "InputCargos": {"Fuel": 1},
  "InputCargoTypes": {},
  "OutputCargos": {},
  "bHidden": false,
  "bStoreInputCargo": false
}
```

| Recipe Type | InputCargos | OutputCargos | SpeedMult | Description |
|-------------|-------------|--------------|-----------|-------------|
| **Source** | `{}` | `{"CornPallet": 1}` | 1.0 | Produces cargo from nothing |
| **Sink (catalyst)** | `{"Fuel": 1}` | `{}` | 2.0 | Consumes input, boosts production speed |
| **Transform** | `{"IronOre": 2}` | `{"IronIngot": 1}` | 1.0 | Converts input to output |

### Net_InputInventory.Entries

Array of `FMTInventoryEntry` — the runtime inventory state the delivery system uses for cargo matching.

```json
[
  {"CargoKey": "Fuel", "Amount": 0},
  {"CargoKey": "BoxPallete_02", "Amount": 0},
  {"CargoKey": "QuicklimePallet", "Amount": 0}
]
```

Each entry represents a cargo slot the DP can receive. The delivery system matches sender output cargo against receiver `Net_InputInventory.Entries` to create delivery missions.

### DemandConfigs (NOT used for cargo matching)

Despite the name, `DemandConfigs` is **not** what controls whether a DP receives fuel/quicklime. For corn farms, `DemandConfigs` is always empty. Cargo acceptance comes from `StorageConfigs` + `ProductionConfigs` (CDO) and `Net_InputInventory.Entries` (runtime).

### Other Important Properties

| Property | Type | Description |
|----------|------|-------------|
| `bIsSender` | bool | Can generate outbound deliveries |
| `bIsReceiver` | bool | Can receive inbound deliveries |
| `bUseAsDestinationInteraction` | bool | Shows as interactive destination on map |
| `MaxDeliveries` | int32 | Max concurrent delivery missions |
| `MaxDeliveryDistance` | float | Max distance for outbound deliveries |
| `MaxDeliveryReceiveDistance` | float | Max distance for inbound deliveries (0 = unlimited) |
| `DemandPriority` | int32 | Priority for receiving deliveries (higher = more preferred) |
| `GameplayTags` | FGameplayTagContainer | Tags for cargo matching queries |
| `DeliveryPointGuid` | FGuid | Unique identifier |
| `SupplyAndDemands` | TArray | Delivery system's list of DPs that participate in supply/demand |

### TArray Operations

UE4SS TArray access for delivery point properties:

```lua
-- Count elements
local count = #actor.DeliveryPoints

-- Read by index (1-based)
local dp = actor.DeliveryPoints[1]

-- Append (correct for TArray)
actor.DeliveryPoints[#actor.DeliveryPoints + 1] = newDP

-- Iterate
actor.DeliveryPoints:ForEach(function(index, element)
  local dp = element:get()  -- RemoteUnrealParam → UObject
  -- ...
end)

-- Write to index
actor.DeliveryPoints[1] = someDP
```

> **Note**: `arr:Add(key, value)` works for TMap but **NOT** for TArray. Use `arr[#arr + 1] = value` for TArray append.

## API Endpoints

### Mod API (port 5001)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/delivery/points` | GET | All delivery points with full property details |
| `/delivery/points/{guid}` | GET | Single delivery point by GUID |
| `/test/spawn_dp` | POST | Spawn and register a new delivery point |
| `/test/copy_inventory` | POST | Copy `Net_InputInventory.Entries` from reference DP |

#### Get delivery point details

```bash
ssh root@amc-peripheral 'curl -s "http://localhost:5001/delivery/points?password=&filters=DeliveryPointGuid,DemandConfigs,StorageConfigs,ProductionConfigs,Net_InputInventory,bIsSender,bIsReceiver" | python3 -m json.tool'
```

#### Get single delivery point

```bash
ssh root@amc-peripheral 'curl -s "http://localhost:5001/delivery/points/{guid}?password=" | python3 -m json.tool'
```

#### Copy InputInventory from reference DP

```bash
ssh root@amc-peripheral 'curl -s -X POST "http://localhost:5001/test/copy_inventory?password=" \
  -H "Content-Type: application/json" \
  -d "{\"RefGuid\": \"D11ED5CE44A72EB3F1D171BDC8E7E070\"}" | python3 -m json.tool'
```

### Native Game API (port 8081)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/delivery/sites` | GET | All delivery sites with InputInventory, OutputInventory, Deliveries |

#### Find deliveries TO a specific DP

The native API lists deliveries on the **sender's** site entry, not the receiver's. To find deliveries TO a DP, search all sites:

```bash
ssh root@amc-peripheral 'curl -s --max-time 10 "http://localhost:8081/delivery/sites?password=" | python3 -c "
import json, sys
data = json.load(sys.stdin)[\"data\"]
target = \"YOUR_DP_GUID_HERE\"
for idx, s in data.items():
    for d_idx, d in s.get(\"Deliveries\", {}).items():
        if d.get(\"receiver_point\") == target:
            print(\"  #%s type=%s from=%s\" % (d[\"id\"], d[\"cargo_type\"], s.get(\"name\",\"?\")))
"'
```

#### Check InputInventory at a site

```bash
ssh root@amc-peripheral 'curl -s "http://localhost:8081/delivery/sites?password=" | python3 -c "
import json, sys
data = json.load(sys.stdin)[\"data\"]
for idx, s in data.items():
    if s.get(\"guid\") == \"YOUR_DP_GUID_HERE\":
        for k, v in s.get(\"InputInventory\", {}).items():
            cargo = v.get(\"cargo\", {})
            print(\"%s: %dx %s\" % (cargo.get(\"cargo_key\",\"?\"), v.get(\"amount\",0), cargo.get(\"name\",\"?\")))
"'
```

## Blueprint Asset Path Format

SpawnActor requires `PackagePath.ClassName` format with `_C` suffix:

```
/Game/Objects/Mission/Delivery/DeliveryPoint/Farm_Corn.Farm_Corn_C
```

Not just `/Game/.../Farm_Corn_C` — this fails with "Name wasn't long" error.

Common delivery point Blueprints:

| Blueprint | Asset Path | Role |
|-----------|-----------|------|
| Farm_Corn | `Farm_Corn.Farm_Corn_C` | Produces CornPallet/CornBox, consumes Fuel/Quicklime |
| Farm_Hemp | `Farm_Hemp.Farm_Hemp_C` | Similar to corn farm |
| Warehouse | `Warehouse.Warehouse_C` | General storage hub |
| Factory_* | `Factory_*.Factory_*_C` | Various factories |

## Reference Data: Corn Farm (Namwon)

Complete property dump for a base game corn farm delivery point:

**StorageConfigs** (what it can store):
| MaxStorage | CargoType | CargoKey |
|-----------|-----------|----------|
| 10 | 3 (Pallet) | None |
| 3 | 2 (Box) | None |
| 5 | 0 (Specific) | Fuel |
| 0 | 0 (Specific) | QuicklimePallet |

**ProductionConfigs** (what it produces/consumes):
| OutputCargos | InputCargos | InputCargoTypes | Time (s) | SpeedMult |
|-------------|-------------|-----------------|----------|-----------|
| CornPallet: 1 | — | — | 300 | 1.0 |
| CornBox: 1 | — | — | 30 | 1.0 |
| — | Fuel: 1 | — | 600 | 2.0 |
| — | — | Type 3 (Pallet): 1 | 600 | 2.0 |
| — | QuicklimePallet: 1 | — | 1200 | 2.0 |

**Net_InputInventory.Entries** (runtime inventory — what the delivery system uses):
| CargoKey | Amount |
|----------|--------|
| Fuel | 0 |
| BoxPallete_02 | 0 |
| BoxPallete_01 | 0 |
| BoxPallete_03 | 0 |
| QuicklimePallet | 0 |

**Key GUIDs** (Jeju Island corn farms):
| Farm | GUID |
|------|------|
| Namwon Corn Farm | `D11ED5CE44A72EB3F1D171BDC8E7E070` |
| Sangdo Corn Farm | `3C357C2B48DEC93BBAEA52A75A92622A` |
| Gapa Golden Corn Farm | `E6E84AE24AAC69F998502CBDB090C6AB` |

## Critical Gotchas

### 1. SpawnActor Timing

`SpawnActor` requires `UGameEngine::Tick` to be initialized. It fails during:
- `NotifyOnNewObject` callbacks (too early)
- `RegisterBeginPlayPreHook` callbacks directly (tick not ready)
- `RegisterInitGameStatePostHook` callbacks (too early)

**Solution**: Use `RegisterBeginPlayPreHook` to catch `AMTDeliverySystem`'s `BeginPlay`, then defer `SpawnActor` to the next game tick via `ExecuteInGameThread`.

### 2. RegisterBeginPlayPreHook Params

`RegisterBeginPlayPreHook` callback params are `RemoteUnrealParam` — must use `Context:Get()` to unwrap to `UObject` before calling `:IsA()`.

```lua
RegisterBeginPlayPreHook(function(Context)
  local actor = Context:Get()  -- unwrap RemoteUnrealParam
  local dsClass = StaticFindObject("/Script/MotorTown.MTDeliverySystem")
  if not actor:IsA(dsClass) then return end
  -- ...
end)
```

### 3. Net_InputInventory Must Be Manually Populated

The delivery system populates `Net_InputInventory.Entries` from `StorageConfigs` during its `BeginPlay` init. A runtime-spawned DP misses this step and has empty `Net_InputInventory.Entries`, resulting in **zero receiver deliveries**.

**Solution**: Copy entries from a same-class reference DP after spawning.

### 4. Never Use ExecuteWithDelay / LoopAsync

These run on background threads. UObject access from non-game threads causes crashes.

| Safe | Unsafe |
|------|--------|
| `ExecuteInGameThreadWithDelay(ms, fn)` | `ExecuteWithDelay(ms, fn)` |
| `LoopInGameThreadWithDelay(ms, fn)` | `LoopAsync(ms, fn)` |
| `ExecuteInGameThread(fn)` | — |

### 5. Hot-Reload Must Deploy to Both Locations

When SCP'ing Lua files to the staging server, deploy to both:
- **Live dir**: `/var/lib/motortown-server/MotorTown/Binaries/Win64/ue4ss/Mods/MotorTownMods/Scripts/` (immediate hot-reload)
- **Cache dir**: `/var/lib/motortown-server/.mod-cache/extracted-server-v<VERSION>/ue4ss/Mods/MotorTownMods/Scripts/` (survives restart)

The `mods.nix` install script uses `cp -r` (not `rm -rf` + `cp`) so hot-reloaded files survive service restarts.

## Key Files

| File | Purpose |
|------|---------|
| `MTDediMod/Scripts/CargoManager.lua` | Delivery point injection, HTTP endpoints for DP management |
| `MTDediMod/Scripts/AssetManager.lua` | `SpawnActor()` implementation |
| `MTDediMod/Scripts/Helpers.lua` | `ExecuteInGameThreadSync`, utility functions |
| `MTDediMod/types/MotorTown.lua` | Type annotations: `AMTDeliveryPoint` (line 429), `AMTDeliverySystem` (line 494) |
| `MTDediMod/AGENTS.md` | Build pipeline, known issues, deployment guide |
| `motortown-server-flake/mods.nix` | NixOS mod installation, hot-reload preservation |
| `motortown-server-flake/motortown-server.nix` | Game server systemd service, environment variables |
| `.agents/skills/cargo-mod/SKILL.md` (mt-pak-extract) | PAK-based cargo mod creation |
