#!/usr/bin/env python3
"""Writes paste-ready files for the CX Agent Studio console from a built package, for adding to an existing agent without importing a zip.

  export_console_files.py SPEC_JSON PACKAGE_DIR OUT_DIR

OUT_DIR gets:
  tools/<name>.py                      one file per Python tool (paste into a Python tool of the same name)
  callbacks/<type>_<n>_<template>.py   one file per callback, in the order the console runs them
  root_instruction.txt (and global_instruction.txt if there is one)
  salesforce_schema.json               the whole connector schema, in the form the Salesforce tool dialog takes
Nothing here contains a secret. The connector's login settings are not part of the schema.
"""
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from ces_lib import openapi_sf          # noqa: E402
from selftest_callbacks import identify  # noqa: E402


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    spec_path, package, out = sys.argv[1:]
    spec = json.load(open(spec_path))
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(os.path.join(out, "tools"))
    os.makedirs(os.path.join(out, "callbacks"))
    for name in sorted(os.listdir(os.path.join(package, "tools"))):
        src = os.path.join(package, "tools", name, "python_function", "python_code.py")
        if os.path.isfile(src):
            shutil.copy(src, os.path.join(out, "tools", name + ".py"))
    agents_dir = os.path.join(package, "agents")
    for agent in sorted(os.listdir(agents_dir)):
        jf = os.path.join(agents_dir, agent, agent + ".json")
        if not os.path.isfile(jf):
            continue
        data = json.load(open(jf))
        prefix = "" if len(os.listdir(agents_dir)) == 1 else agent + "_"
        for key, label in (("beforeAgentCallbacks", "before_agent"), ("afterAgentCallbacks", "after_agent"), ("beforeModelCallbacks", "before_model"),
                           ("afterModelCallbacks", "after_model"), ("beforeToolCallbacks", "before_tool"), ("afterToolCallbacks", "after_tool")):
            for i, cb in enumerate(data.get(key, []), 1):
                path = os.path.join(package, cb["pythonCode"])
                what = identify(open(path).read()) or "callback"
                shutil.copy(path, os.path.join(out, "callbacks", "%s%s_%d_%s.py" % (prefix, label, i, what)))
    for rel, name in (("instruction.txt", "root_instruction.txt"), ("global_instruction.txt", "global_instruction.txt")):
        for base in (package, os.path.join(package, "agents", "Root_agent")):
            if os.path.isfile(os.path.join(base, rel)):
                shutil.copy(os.path.join(base, rel), os.path.join(out, name))
                break
    sf = spec["salesforce"]
    for ts in spec.get("toolsets", []):
        schema = openapi_sf.build_schema(sf["instanceUrl"], sf.get("apiVersion", "v60.0"), ts.get("title", ts["name"]), ts["operations"],
                                         relative=bool(ts.get("server_includes_version", False)))
        fname = "salesforce_schema.json" if len(spec["toolsets"]) == 1 else "%s_schema.json" % ts["name"]
        with open(os.path.join(out, fname), "w") as fh:
            json.dump(schema, fh, indent=2)
    print("wrote %s: %d tool file(s), %d callback file(s)" % (out, len(os.listdir(os.path.join(out, "tools"))), len(os.listdir(os.path.join(out, "callbacks")))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
