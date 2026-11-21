#!/usr/bin/env python3
"""Compare a built package with a real console export, to find places where the generator drifts from what the console writes.

  compare_to_export.py BUILT_PACKAGE REAL_EXPORT

Reports files and JSON keys that only one side has, and (when PyYAML is installed) whether the Salesforce toolset schemas match.
Differences that come from the spec itself (descriptions, a global instruction, extra callbacks) are expected: read the list, do not
aim for zero. Anything else is a generator bug or a console feature the generator does not know yet. Names inside the console's
generated ids ("name": uuid) are ignored.
"""
import json
import os
import re
import sys


def files(root):
    out = []
    for r, _, fs in os.walk(root):
        for f in fs:
            if f not in (".DS_Store",) and not f.endswith((".zip", ".pyc")):
                out.append(os.path.relpath(os.path.join(r, f), root))
    return sorted(out)


def shape(path):
    """Collapse numbered callback folders so layouts can be compared."""
    return re.sub(r"_callbacks_\d+", "_callbacks_NN", path)


def keys(node, prefix=""):
    found = set()
    if isinstance(node, dict):
        for k, v in node.items():
            found.add(prefix + "/" + k)
            found |= keys(v, prefix + "/" + k)
    elif isinstance(node, list):
        for v in node:
            found |= keys(v, prefix + "[]")
    return found


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    mine, real = sys.argv[1], sys.argv[2]
    fm, fr = {shape(f) for f in files(mine)}, {shape(f) for f in files(real)}
    print("Files only in the built package:")
    for f in sorted(fm - fr):
        print("   " + f)
    print("Files only in the real export:")
    for f in sorted(fr - fm):
        print("   " + f)
    json_files = sorted(f for f in files(real) if f.endswith(".json"))
    for rel in json_files:
        other = os.path.join(mine, rel)
        if not os.path.isfile(other):
            continue
        try:
            a, b = json.load(open(other)), json.load(open(os.path.join(real, rel)))
        except ValueError:
            continue
        ka, kb = keys(a), keys(b)
        ka.discard("/name"), kb.discard("/name")
        if ka != kb:
            print("\n%s" % rel)
            if ka - kb:
                print("   keys only in the built package: %s" % sorted(ka - kb))
            if kb - ka:
                print("   keys only in the real export:   %s" % sorted(kb - ka))
    try:
        import yaml
    except ImportError:
        print("\n(PyYAML not installed: toolset schemas not compared)")
        return 0
    for rel in files(real):
        if rel.endswith("open_api_schema.yaml") and os.path.isfile(os.path.join(mine, rel)):
            ym, yr = yaml.safe_load(open(os.path.join(mine, rel))), yaml.safe_load(open(os.path.join(real, rel)))
            same = [p for p in yr.get("paths", {}) if ym.get("paths", {}).get(p) == yr["paths"][p]]
            diff = [p for p in yr.get("paths", {}) if p not in same]
            print("\n%s: %d operation path(s) identical" % (rel, len(same)) + ("; different or missing: %s" % diff if diff else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
