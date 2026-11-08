#!/usr/bin/env python3
"""Mark a source model's own cabin-interior faces so they can take interior materials.

Why: on a shell that models its own cabin tub, the surfaces the driver sees from the cabin are
BODY triangles wearing body paint, sitting in front of any authored interior primitive. Recolouring
the interior material then changes nothing on screen (measured once at 98.7% body / 1.3% interior in
the driver's view). Faces that are visible from inside but NOT from outside can be moved to an
interior slot without the car's exterior changing at all.

Usage: cabin_split.py <scene.gltf> <out.npy>

Writes a uint8 array, one entry per source triangle (source order, so it indexes the same tri table
split_glb_interior.py uses):
  0 = shell, keep body paint
  1 = cabin surface, horizontal  (floor, ceiling, dash top)
  2 = cabin surface, vertical    (door cards, kick panels, dash face)

In the generator, build the body primitive from class 0 and append classes 1 and 2 as their own
primitives with the interior materials. Flipping: these triangles come from the same source as the
body, so reverse them with it -- flip by the primitives they now live in, and re-check after any
change to how many primitives the GLB emits.

Axes: source glTF is (x lateral, y up, z length) -> UE (X length, Y lateral, Z up). The bbox print is
the sanity check; a 4.6 m car should read about X +-230, Y +-93, Z 25..135 cm. Get the axes wrong and
the eye point lands outside the car, reporting nonsense percentages.
"""
import json
import sys

import numpy as np

SRC = sys.argv[1] if len(sys.argv) > 1 else "scene.gltf"
OUT = sys.argv[2] if len(sys.argv) > 2 else "cabin_tris.npy"
BIN = SRC.replace("scene.gltf", "scene.bin")

# Cabin eye points: driver, passenger, and three looks around the cabin. Adjust to the actual
# cockpit camera once it exists -- they only need to be inside the cabin looking along real sightlines.
EYES = [
    ((-70.0, -33.0, 110.0), (60.0, -33.0, 55.0)),
    ((-70.0, 5.0, 108.0), (60.0, 25.0, 55.0)),
    ((-70.0, -33.0, 110.0), (-60.0, -33.0, 60.0)),
    ((-70.0, -33.0, 110.0), (-60.0, 60.0, 90.0)),
    ((-70.0, -33.0, 110.0), (-60.0, -60.0, 90.0)),
]

MESH = 0          # mesh index of the part to analyse
PRIM = 0          # primitive index holding the body
VERTICAL_DOT = 0.6


def read_accessor(g, buf, i):
    a = g["accessors"][i]
    bv = g["bufferViews"][a["bufferView"]]
    off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    comps = {"SCALAR": 1, "VEC2": 2, "VEC3": 3}[a["type"]]
    dt = {5126: "<f4", 5125: "<u4", 5123: "<u2", 5121: "<u1"}[a["componentType"]]
    return np.frombuffer(buf, dtype=np.dtype(dt), count=a["count"] * comps,
                         offset=off).reshape(a["count"], comps)


g = json.load(open(SRC))
buf = open(BIN, "rb").read()
prim = g["meshes"][MESH]["primitives"][PRIM]
pos = read_accessor(g, buf, prim["attributes"]["POSITION"]).astype(float)
idx = read_accessor(g, buf, prim["indices"]).reshape(-1, 3)

# glTF (x, y, z) -> UE (X length, Y lateral, Z up) in cm
T = np.stack([pos[idx][:, :, 2], pos[idx][:, :, 0], pos[idx][:, :, 1]], 2) * 100.0
N = np.cross(T[:, 1] - T[:, 0], T[:, 2] - T[:, 0])
N /= (np.linalg.norm(N, axis=1, keepdims=True) + 1e-9)
cent = T.mean(1)
print(f"tris {len(T)}  X {cent[:,0].min():.0f}..{cent[:,0].max():.0f} "
      f"Y {cent[:,1].min():.0f}..{cent[:,1].max():.0f} "
      f"Z {cent[:,2].min():.0f}..{cent[:,2].max():.0f}")
print("  (expect X length, Y lateral, Z up -- if not, the axis mapping is wrong)")

E1 = T[:, 1] - T[:, 0]
E2 = T[:, 2] - T[:, 0]


def cast(eye, dirs):
    """Nearest hit per ray -> (hit_mask, front_face_mask) per triangle."""
    hit = np.zeros(len(T), bool)
    front = np.zeros(len(T), bool)
    for d in dirs:
        h = np.cross(d, E2)
        a = (E1 * h).sum(1)
        ok = np.abs(a) > 1e-9
        f = np.where(ok, 1 / np.where(ok, a, 1), 0)
        s = eye - T[:, 0]
        uu = f * (s * h).sum(1)
        q = np.cross(s, E1)
        vv = f * (d * q).sum(1)
        tt = f * (E2 * q).sum(1)
        m = ok & (uu >= 0) & (uu <= 1) & (vv >= 0) & (vv <= 1) & (uu + vv <= 1) & (tt > 1)
        if not m.any():
            continue
        j = int(np.argmin(np.where(m, tt, np.inf)))
        hit[j] = True
        if (N[j] * d).sum() < 0:
            front[j] = True
    return hit, front


def fan(eye, target, fov, w, h):
    fwd = target - eye
    fwd /= np.linalg.norm(fwd)
    right = np.cross(fwd, [0, 0, 1.0])
    right /= np.linalg.norm(right) + 1e-9
    up = np.cross(right, fwd)
    t = np.tan(np.radians(fov / 2))
    return [((fwd + right * ((ix + 0.5) / w * 2 - 1) * t
              + up * ((iy + 0.5) / h * 2 - 1) * t * h / w)
             / np.linalg.norm(fwd + right * ((ix + 0.5) / w * 2 - 1) * t
                              + up * ((iy + 0.5) / h * 2 - 1) * t * h / w))
            for iy in range(h) for ix in range(w)]


inside = np.zeros(len(T), bool)
for eye, tgt in EYES:
    h, _ = cast(np.array(eye), fan(np.array(eye), np.array(tgt), 70, 40, 22))
    inside |= h
print(f"visible from the cabin: {int(inside.sum())}")

centre = np.array([0.0, 0.0, 70.0])
outside = np.zeros(len(T), bool)
for az in range(0, 360, 30):
    for el in (-10, 10, 35, 60):
        a, e = np.radians(az), np.radians(el)
        eye = centre + np.array([np.cos(a) * np.cos(e), np.sin(a) * np.cos(e), np.sin(e)]) * 900.0
        _, f = cast(eye, fan(eye, centre, 45, 16, 10))
        outside |= f          # front faces only: that is what the exterior can actually see
print(f"visible from outside: {int(outside.sum())}")

cabin = inside & ~outside
print(f"cabin-only: {int(cabin.sum())}  ({int((inside & outside).sum())} shared with the exterior)")

slot = np.zeros(len(T), np.uint8)
slot[cabin & (np.abs(N[:, 2]) >= VERTICAL_DOT)] = 1
slot[cabin & (np.abs(N[:, 2]) < VERTICAL_DOT)] = 2
np.save(OUT, slot)
print(f"horizontal {int((slot == 1).sum())}  vertical {int((slot == 2).sum())}  -> {OUT}")
