#!/usr/bin/env python3
"""Rewrite FVector RelativeLocations inside a cooked Motor Town blueprint .uexp.

The UAssetAPI writer refuses cooked blueprints (missing BP-class schemas in
Mappings.usmap), but the *bytes* need no schema: UE5 large-world coordinates
store FVector as three contiguous float64s, so a position can be overwritten in
place with the header untouched.

Config JSON:
  {
    "uasset_in":  ".../<V>.uasset",     # copied through untouched
    "uexp_in":    ".../<V>.uexp",
    "uasset_out": ".../out/<V>.uasset",
    "uexp_out":   ".../out/<V>.uexp",
    "patches": [{"name": "Wheel0", "old": [143, 98, 35], "new": [145.8, 80.7, 37.5]}]
  }

Usage: python3 patch_bp_vectors.py cfg.json [report.json]

Guarantees: exactly one byte-pattern hit per patch (0 or >1 is refused, a
multi-hit vector would silently move the wrong component), file length
unchanged, and every new triple read back out of the written file.
"""
import json
import os
import struct
import sys


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    cfg = json.load(open(sys.argv[1]))
    uexp = bytearray(open(cfg["uexp_in"], "rb").read())
    original = bytes(uexp)
    lines, failed = [], 0

    for p in cfg["patches"]:
        name, old, new = p["name"], list(map(float, p["old"])), list(map(float, p["new"]))
        pat_old, pat_new = struct.pack("<3d", *old), struct.pack("<3d", *new)
        hits, i = [], uexp.find(pat_old)
        while i >= 0:
            hits.append(i)
            i = uexp.find(pat_old, i + 1)
        if len(hits) != 1:
            lines.append(f"SKIP {name}: {len(hits)} hits (need exactly 1) old={old}")
            failed += 1
            continue
        off = hits[0]
        uexp[off:off + 24] = pat_new
        lines.append(f"OK   {name}: @0x{off:X} {old} -> {new}")

    if failed:
        print("\n".join(lines))
        raise SystemExit(f"{failed} patch(es) refused — nothing written")
    if len(uexp) != len(original):
        raise SystemExit("internal error: length changed")
    if bytes(uexp) == original:
        raise SystemExit("internal error: no bytes changed")

    os.makedirs(os.path.dirname(os.path.abspath(cfg["uexp_out"])), exist_ok=True)
    open(cfg["uexp_out"], "wb").write(uexp)
    open(cfg["uasset_out"], "wb").write(open(cfg["uasset_in"], "rb").read())

    # prove it: read the values back out of the file we just wrote
    back = open(cfg["uexp_out"], "rb").read()
    for p in cfg["patches"]:
        pat_new = struct.pack("<3d", *list(map(float, p["new"])))
        assert pat_new in back, f"{p['name']}: new triple not present after write"
        assert len(back) == len(original), "size drifted"
    assert open(cfg["uasset_out"], "rb").read() == open(cfg["uasset_in"], "rb").read()

    print("\n".join(lines))
    print(f"wrote {cfg['uexp_out']} ({len(uexp)} bytes, {sum(1 for a,b in zip(original, uexp) if a != b)} changed)")
    if len(sys.argv) > 2:
        json.dump({"patched": lines}, open(sys.argv[2], "w"), indent=1)


if __name__ == "__main__":
    main()
