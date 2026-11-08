#!/usr/bin/env python3
"""glTF (Sketchfab export: Y-up, metres) -> game-ready GLB (UE space: Z-up, centimetres, +X forward).

Usage:  gltf_to_ue.py <dir containing scene.gltf + scene.bin> [OutName.glb]

Mapping (glTF Y-up right-handed -> UE Z-up left-handed), a pure rotation, no mirroring:
    UE = 100 * ( gz, gx, gy )
so glTF +Z (model front) -> UE +X (forward) and glTF +Y (up) -> UE +Z.

Wheels keep LOCAL vertex coordinates, so the pivot stays at the hub centre; the hub offsets are
printed in the report AND kept as node translations in the GLB so a viewer places them correctly.
Sketchfab's two opposite 90-degree X wrapper matrices cancel; the parent chain is accumulated so a
mesh node's translation is read from its parent (reading the leaf gives zeros).

Requires numpy:  uv venv .venv && uv pip install --python .venv/bin/python numpy
"""
import json
import struct
import sys
import os

import numpy as np

SRC = sys.argv[1] if len(sys.argv) > 1 else "."
OUT = sys.argv[2] if len(sys.argv) > 2 else None
SCALE = 100.0

CT = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}

g = json.load(open(os.path.join(SRC, "scene.gltf")))
blob = open(os.path.join(SRC, "scene.bin"), "rb").read()


def read_accessor(i):
    a = g["accessors"][i]
    bv = g["bufferViews"][a["bufferView"]]
    fmt, size = CT[a["componentType"]]
    n = NC[a["type"]]
    off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = bv.get("byteStride") or size * n
    out = np.zeros((a["count"], n), dtype=np.float64 if fmt == "f" else np.int64)
    for k in range(a["count"]):
        out[k] = struct.unpack_from("<" + fmt * n, blob, off + k * stride)
    return out


def ue(p):
    """glTF coords -> UE coords (cm)."""
    return np.stack([p[:, 2], p[:, 0], p[:, 1]], axis=1) * SCALE


# --- node hierarchy: a mesh node's transform lives on its PARENT -----------
parent = {c: i for i, n in enumerate(g["nodes"]) for c in n.get("children", [])}


def local_mat(node):
    if "matrix" in node:
        return np.array(node["matrix"], dtype=np.float64).reshape(4, 4).T
    M = np.eye(4)
    t = node.get("translation", [0, 0, 0])
    s = node.get("scale", [1, 1, 1])
    x, y, z, w = node.get("rotation", [0, 0, 0, 1])
    R = np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])
    M[:3, :3] = R @ np.diag(s)
    M[:3, 3] = t
    return M


def world_mat(i):
    M = np.eye(4)
    while i is not None:
        M = local_mat(g["nodes"][i]) @ M
        i = parent.get(i)
    return M


parts = []
for i, node in enumerate(g["nodes"]):
    if "mesh" not in node:
        continue
    name = node.get("name", "mesh")
    if name.startswith("Object_") and i in parent:  # use the semantic parent name
        name = g["nodes"][parent[i]].get("name", name)
    t = world_mat(i)[:3, 3]
    prim = g["meshes"][node["mesh"]]["primitives"][0]
    pos = ue(read_accessor(prim["attributes"]["POSITION"]))
    nrm = ue(read_accessor(prim["attributes"]["NORMAL"]))
    nrm /= np.linalg.norm(nrm, axis=1, keepdims=True)
    uv = read_accessor(prim["attributes"]["TEXCOORD_0"]) if "TEXCOORD_0" in prim["attributes"] \
        else np.zeros((len(pos), 2))
    idx = read_accessor(prim["indices"]).reshape(-1).astype(np.uint32)
    parts.append(dict(name=name, pos=pos, nrm=nrm, uv=uv, idx=idx,
                      hub=ue(t.reshape(1, 3))[0], bbox=(pos.min(0), pos.max(0))))

# --- report ---------------------------------------------------------------
body = max(parts, key=lambda p: len(p["idx"]))
print("=== parts (UE space, cm) ===")
for p in parts:
    lo, hi = p["bbox"]
    print(f"{p['name']:<14} tris={len(p['idx'])//3:<6} hub=({p['hub'][0]:8.1f},{p['hub'][1]:7.1f},"
          f"{p['hub'][2]:6.1f})  size=({hi[0]-lo[0]:6.1f} x {hi[1]-lo[1]:6.1f} x {hi[2]-lo[2]:6.1f})")

lo, hi = body["bbox"]
wheels = [p for p in parts if p is not body]
print("\n=== derived ===")
print(f"body  length {hi[0]-lo[0]:.1f} | width {hi[1]-lo[1]:.1f} | height {hi[2]-lo[2]:.1f} cm")
print(f"body  sill Z {lo[2]:.1f} (origin sits on the ground if this is ~0-ish above it), roof Z {hi[2]:.1f}")
if wheels:
    front = [p["hub"][0] for p in wheels if p["hub"][0] > 0]
    rear = [p["hub"][0] for p in wheels if p["hub"][0] < 0]
    wb = abs(np.mean(front) - np.mean(rear)) if front and rear else 0.0
    track = 2 * float(np.mean([abs(p["hub"][1]) for p in wheels]))
    rad = float(np.mean([(p["bbox"][1][2] - p["bbox"][0][2]) / 2 for p in wheels]))
    print(f"wheelbase {wb:.1f} | track {track:.1f} | wheel radius {rad:.1f} (dia {2*rad:.1f}) cm")
    print("compare against the donor blueprint's Wheel0..3 RelativeLocation before building")

# --- write GLB ------------------------------------------------------------
buf = bytearray()
accessors, bufferViews = [], []


def push(arr, comp, typ, target=None):
    global buf
    while len(buf) % 4:
        buf += b"\x00"
    off = len(buf)
    data = arr.tobytes()
    buf += data
    bv = {"buffer": 0, "byteOffset": off, "byteLength": len(data)}
    if target:
        bv["target"] = target
    bufferViews.append(bv)
    acc = {"bufferView": len(bufferViews) - 1, "componentType": comp,
           "count": arr.shape[0] if arr.ndim > 1 else len(arr), "type": typ}
    if typ == "VEC3":
        acc["min"] = arr.min(0).tolist()
        acc["max"] = arr.max(0).tolist()
    accessors.append(acc)
    return len(accessors) - 1


meshes, nodes = [], []
for p in parts:
    a_pos = push(p["pos"].astype(np.float32), 5126, "VEC3", 34962)
    a_nrm = push(p["nrm"].astype(np.float32), 5126, "VEC3", 34962)
    a_uv = push(p["uv"].astype(np.float32), 5126, "VEC2", 34962)
    a_idx = push(p["idx"], 5125, "SCALAR", 34963)
    meshes.append({"name": p["name"], "primitives": [{
        "attributes": {"POSITION": a_pos, "NORMAL": a_nrm, "TEXCOORD_0": a_uv},
        "indices": a_idx, "material": 0, "mode": 4}]})
    nodes.append({"name": p["name"], "mesh": len(meshes) - 1,
                  "translation": (p["hub"].tolist() if p is not body else [0.0, 0.0, 0.0])})

gltf = {
    "asset": {"version": "2.0", "generator": "AMC mt-vehicle-import"},
    "scene": 0,
    "scenes": [{"nodes": list(range(len(nodes)))}],
    "nodes": nodes,
    "meshes": meshes,
    "materials": [{"name": "M_Vehicle_Paint", "pbrMetallicRoughness": {
        "baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0.6, "roughnessFactor": 0.35}}],
    "accessors": accessors,
    "bufferViews": bufferViews,
    "buffers": [{"byteLength": len(buf)}],
}
js = json.dumps(gltf, separators=(",", ":")).encode()
while len(js) % 4:
    js += b" "
while len(buf) % 4:
    buf += b"\x00"
bin_chunk = bytes(buf)
out = b"glTF" + struct.pack("<II", 2, 12 + 8 + len(js) + 8 + len(bin_chunk))
out += struct.pack("<I", len(js)) + b"JSON" + js
out += struct.pack("<I", len(bin_chunk)) + b"BIN\x00" + bin_chunk
name = OUT or (parts[0]["name"].split("_")[0] + "_MT_UE.glb")
open(name, "wb").write(out)
print(f"\nwrote {name}  {len(out)/1024:.0f} KB")
