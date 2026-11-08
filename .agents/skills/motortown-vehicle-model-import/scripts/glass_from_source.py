"""Pick a third-party car's glazing triangles out of its ORIGINAL model.

Why this exists: low-poly car sources paint their windows one flat colour in a tiny palette atlas
(often 64x64, a handful of colours) instead of shipping a glass material. That colour is the
artist's own window selection, so it beats any geometric heuristic: it catches side glass that
angle/normal rules miss, and it never glass-overs a painted panel.

The source index table is normally identical to the one our exporter emits (same vertex count and
order), so the selected triangle indices transfer directly onto our body primitive.

Usage: python3 glass_from_source.py <dir with scene.gltf/scene.bin/textures> [out.npy]
Prints the count and the band extents, and warns about partially-matching triangles.
Edit GLASS_RGB to the colour you actually find (list the atlas's top colours first).
"""
import json
import sys

import numpy as np
from PIL import Image

GLASS_RGB = np.array([16, 22, 28])
OUT_DEFAULT = "glass_tris.npy"


def read_accessor(g, buf, index):
    a = g["accessors"][index]
    bv = g["bufferViews"][a["bufferView"]]
    off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    comps = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[a["type"]]
    dtype = {5126: "<f4", 5125: "<u4", 5123: "<u2", 5121: "<u1"}[a["componentType"]]
    return np.frombuffer(buf, dtype=dtype, count=a["count"] * comps, offset=off).reshape(a["count"], comps)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "."
    out = sys.argv[2] if len(sys.argv) > 2 else OUT_DEFAULT

    g = json.load(open(f"{src}/scene.gltf"))
    buf = open(f"{src}/scene.bin", "rb").read()
    mat = g["materials"][0]
    tex_name = mat["pbrMetallicRoughness"]["baseColorTexture"]["index"]
    uri = g["textures"][tex_name]["source"]
    img = g["images"][uri]["uri"]
    tex = np.asarray(Image.open(f"{src}/{img}").convert("RGB"))
    h, w, _ = tex.shape

    prim = g["meshes"][0]["primitives"][0]
    pos = read_accessor(g, buf, prim["attributes"]["POSITION"])
    uv = read_accessor(g, buf, prim["attributes"]["TEXCOORD_0"])
    idx = read_accessor(g, buf, prim["indices"]).reshape(-1, 3)

    tri_uv = uv[idx]
    u = np.clip((tri_uv[:, :, 0] * w).astype(int), 0, w - 1)
    v = np.clip((tri_uv[:, :, 1] * h).astype(int), 0, h - 1)
    cols = tex[v, u].astype(int)
    on_colour = np.abs(cols - GLASS_RGB).sum(2) == 0
    sel = on_colour.all(1)          # all three corners on the colour, so no texture edge bleed

    centres = pos[idx].mean(1)[sel]
    print(f"glass tris: {int(sel.sum())} of {len(idx)}")
    if sel.sum():
        for axis, label in enumerate(("lat", "up", "fwd")):
            print("  %-4s %.2f..%.2f m" % (label, centres[:, axis].min(), centres[:, axis].max()))
    unsure = (on_colour.any(1) & ~sel).sum()
    if unsure:
        print(f"  WARNING: {unsure} triangles only partially on the glass colour")
    np.save(out, np.where(sel)[0])
    print("wrote", out)

    # atlas sanity: a low-poly source is usually a handful of flat colours
    uniq, counts = np.unique(tex.reshape(-1, 3), axis=0, return_counts=True)
    top = uniq[np.argsort(-counts)][:8]
    print("atlas top colours:", [tuple(int(c) for c in row) for row in top])


if __name__ == "__main__":
    main()
