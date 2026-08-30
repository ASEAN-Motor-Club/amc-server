---
name: ue4ss-cpp-cross-compile
description: Cross-compile UE4SS C++ mods (and UE4SS itself) Linux→Windows via the Nix toolchain — UEPseudo bootstrap, host RAM constraints, cargo/PDB gotchas, symbols
---

# UE4SS C++ Mod Cross-Compiling (Linux → Windows)

How UE4SS-based C++ mods (MTDediMod and anything derived from UE4SSCPPTemplate) are
cross-compiled on the AMC Linux hosts: `clang-cl` targets `x86_64-pc-windows-msvc`,
Windows CRT/SDK headers+libs come from `xwin` (Microsoft servers), linking via `lld-link`,
Rust components via a fenix toolchain. Everything is provisioned by the mod repo's flake.

Companion skills: `mtdedimod-deploy` (release/deploy flow, versioning, tags) and
`mtdedimod-debugging`. This skill covers the **build toolchain and environment**.

## 1. The flake apps

From the mod repo root (e.g. `MTDediMod/`):

| App | Does |
|-----|------|
| `.#configure` | Downloads MSVC SDK via `xwin` into `.xwin-cache/`, writes `toolchain.cmake` + wrapper `CMakeLists.txt`, runs `cmake -B build-cross`. **Only needed once** (or when the UE4SS source override changes) |
| `.#build` | `cmake --build build-cross` (ninja). Parallelism: `-j${NIX_BUILD_CORES:-nproc}` |
| `.#package` | Assembles `MotorTownMods-package.zip` (proxy dll, UE4SS.dll, mod dll as `dlls/main.dll`, Lua scripts, production-patched UE4SS-settings.ini, shared Lua + prebuilt Lua binary deps) and collects PDBs into `symbols/` |
| `.#configure-client` / `.#build-client` / `.#package-client` | Same for the client mod (`dwmapi.dll` proxy, `build-cross-client/`) |
| `.#archive-symbols` / `.#analyze-crash` | PDB archiving per tag / minidump analysis |

Always pass `--no-update-lock-file` (prevents flake.lock refresh hitting the GitHub API).

Outputs:
- `build-cross/Game__Shipping__Win64/bin/` → `UE4SS.dll`, `version.dll` (proxy), PDBs
- `build-cross/MotorTownMods/MotorTownMods.dll` → the mod itself

## 2. The UEPseudo gate (the one hard blocker)

UE4SS builds against `deps/first/Unreal` = **UEPseudo, a private submodule** of the
`Re-UE4SS` org. Credentials that do NOT work: the amc-coding-agent GitHub App token,
and the nix `access-tokens` PAT on amc-peripheral (both 404). The only working secret is
the repo-level Actions secret `UEPSEUDO_PAT` used by CI.

### Bootstrap UE4SS source via CI (once per flake.lock ue4ss rev)

Reference implementation: branch `ci/ue4ss-src-artifact` in MTDediMod
(`.github/workflows/ue4ss-src-artifact.yml`, triggers on `workflow_dispatch` and pushes to
`ci/**`): checks out `UE4SS-RE/RE-UE4SS` at the `flake.lock`-pinned rev with
`submodules: recursive` + `UEPSEUDO_PAT`, strips all `.git` metadata, uploads artifact `ue4ss-src`.

```bash
git commit -q --allow-empty && git push          # on ci/ue4ss-src-artifact → re-dump
# download the artifact via API; it 302s to a signed Azure blob URL —
# you MUST drop the Authorization header on the redirect or Azure returns 401
```

Extract the tarball to a **plain directory** (e.g. `/opt/data/workspace/ue4ss-art/ue4ss-src`).
Stripping `.git` matters: nix copies path inputs of git repos via git file lists, which can
drop submodule working-tree content. Keep the dir until the flake.lock `ue4ss` rev changes
(tarball name = locked rev). Re-dumping is cheap (~2 min CI).

### Alternative used by CI itself / UE4SSCPPTemplate

CI (`nix-release.yml`) checks out UE4SS with `actions/checkout submodules: recursive` and
overrides the input with `path:$PWD/.ue4ss-src`. `ASEAN-Motor-Club/UE4SSCPPTemplate` instead
declares the flake input with `submodules = true` and configures
`url."https://x-access-token:$PAT@github.com/".insteadOf "https://github.com/"` — requires a
PAT in the environment, which AMC build hosts don't have.

## 3. Environment: build on the HOST, not the agent container

- **The agent container is cgroup-capped at 4GiB** (`memory.max`). `free -h` inside the
  container shows the HOST's RAM (15GiB) — misleading. A full UE4SS build needs ~6GiB peak.
- Build over SSH on the host: `ssh root@host.docker.internal` (= amc-peripheral).
- Container and host **share the same `/nix/store`** (bind mount) — toolchain store paths
  from either side are valid on both; nothing re-downloads.
- `/opt/data` is a **symlink** to `/var/lib/hermes-agent` on the host. Nix `path:` inputs
  refuse symlinks → `cd` and all `path:` overrides must use the real
  `/var/lib/hermes-agent/workspace/...` paths.
- No host compiler on NixOS-minimal: cargo *host* build scripts (num-traits,
  windows_x86_64_msvc, crossbeam-utils, …) need `cc`. Prepend a gcc wrapper from the store:
  ```bash
  export PATH=$(echo /nix/store/*-gcc-wrapper-*/bin | cut -d' ' -f1):/run/current-system/sw/bin:$PATH
  ```
- Size `-j` to RAM: `NIX_BUILD_CORES=4` peaks ~5-6GiB (4 × clang-cl on the big UE4SS TUs);
  run under `nice -n 15` to stay polite to the game/production services on the same box.

## 4. Procedure (proven commands)

```bash
ssh root@host.docker.internal 'export PATH=<gcc-wrapper>:/run/current-system/sw/bin:$PATH; \
  cd /var/lib/hermes-agent/workspace/MTDediMod-wt-XXX && \
  NIX_BUILD_CORES=4 nice -n 15 nix run --no-update-lock-file \
    --override-input ue4ss "path:/var/lib/hermes-agent/workspace/ue4ss-art/ue4ss-src" \
    .#configure > /var/lib/hermes-agent/workspace/mt-build.log 2>&1; echo EXIT:$?'
```

- Same command with `.#build` (then `.#package`). Use the **same** `--override-input` for
  all three.
- Log redirects must be INSIDE the ssh quotes (host-side file) — a container-side `tee`
  pipe dies silently and SIGPIPEs the build.
- Cold full build: ~70 min at `-j4`. Incremental after touching only `src/`: minutes.
- `rm -rf build-cross` when the ue4ss override path changes — the CMake **cache pins the old
  `UE4SS_SOURCE_DIR`** and silently keeps building against it.
- Build runs as root on the host → `build-cross/` ends up root-owned (still world-readable;
  packaging only needs read). `chown -R 10000:10000` if container tools must write into it.
- Tree must be **clean** for packaging (zip must match the tag). `.gitignore` already covers
  `build-cross/`, `.xwin-cache/`, `/CMakeLists.txt`, `cargo/`.

## 5. What the toolchain actually does (when debugging it)

- `setup_cross_compile.sh` → `xwin --accept-license splat --output .xwin-cache` (MSVC CRT +
  Windows SDK, ~2GB, cached), then generates `toolchain.cmake`:
  `clang-cl --target=x86_64-pc-windows-msvc`, `/imsvc` include paths into the xwin cache,
  `/libpath:` lib paths, `lld-link`, `/MD` runtime, `/Zi` + `/DEBUG:FULL` for PDBs,
  `-fuse-ld=lld`, `UE_BUILD_SHIPPING` defines.
- A wrapper `CMakeLists.txt` is **generated at repo root** by configure:
  `add_subdirectory(${UE4SS_SOURCE_DIR} RE-UE4SS)` + `add_subdirectory(src <ModName>)`.
  Env var `UE4SS_SOURCE_DIR` (set by the flake) is baked in at configure time.
- UE4SS pulls Rust components (patternsleuth) via **Corrosion**; the fenix toolchain in the
  flake provides `rustc/cargo` with the `x86_64-pc-windows-msvc` std. Corrosion sets
  `CC_x86_64_pc_windows_msvc=clang-cl` for target crates — but host build scripts still link
  with `cc` (hence §3).
- After linking, `tools/patch-pe-debug-dir.py` fixes the `IMAGE_DEBUG_DIRECTORY` that
  lld-link writes incorrectly (minidumps need it to match PDBs).

## 6. Symbols / crash dumps

- PDBs land in `build-cross/**.pdb` and are copied to `symbols/` by `.#package`.
- **A PDB only matches the exact build that produced it** (GUID+age baked at link time).
  Archive per release: `nix run .#archive-symbols` → `symbols-archive/<tag>/`.
- Analyze: `nix run .#analyze-crash -- /path/to/UEMinidump.dmp` (LLDB, loads the local
  DLL+PDB), or `dump_syms` + `minidump-stackwalk` for breakpad-style traces.
- Crashes live on the servers under
  `/var/lib/motortown-server/MotorTown/Saved/Crashes/*/UEMinidump.dmp`.

## 7. Pitfalls checklist

- **UEPseudo missing** → configure passes but build dies immediately on missing
  `Unreal/*.hpp` includes. Bootstrap §2 first.
- `warning: Git tree is dirty` during package → stop; the zip must match the tag.
- Wrapper `CMakeLists.txt` must be created in the **mod repo root**, not the monorepo root.
- UE4SS log levels are `Verbose | Normal | Warning | Error` — there is **no `Info`**
  (C++ compile error if you use it).
- Never use `LoopAsync` in mod code (background thread; see MTDediMod AGENTS.md).
- Tag-push of `server/v*`/`client/v*` **auto-creates a GitHub release** (softprops) — for
  staging-only tests, tag locally and push only after validation.
- CI (`nix-release.yml`) rebuilds everything on cold runners (~50 min); the local host path
  (§4) is faster for iteration and doesn't burn CI minutes.
- Versioning: new C++ hook = **minor** bump (see `mtdedimod-deploy`); experimental builds use
  `server/v<base>-exp.<topic>.<N>` tags on `exp/*` branches, never promoted.
