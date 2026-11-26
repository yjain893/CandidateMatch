"""Applies the console settings the user switched on, so the package matches a console export:
Cloud Logging ON and the Preview default of telephony-caller-id (a fictional test number),
and sorts variables and tools the way the console exports them.
Usage: python3 finalize_package.py <package folder>"""
import json, os, sys
PKG = sys.argv[1]
TEST_NUMBER = "+15155550101"

p = os.path.join(PKG, "app.json")
a = json.load(open(p))
a.setdefault("loggingSettings", {}).setdefault("cloudLoggingSettings", {})["enableCloudLogging"] = True
for v in a.get("variableDeclarations", []):
    if v["name"] == "telephony-caller-id":
        v["schema"]["default"] = TEST_NUMBER
a["variableDeclarations"] = sorted(a.get("variableDeclarations", []), key=lambda v: v["name"])
json.dump(a, open(p, "w"), indent=2)

for f in [os.path.join(PKG, "agents", d, d + ".json") for d in os.listdir(os.path.join(PKG, "agents"))]:
    r = json.load(open(f))
    r["tools"] = sorted(r.get("tools", []))
    json.dump(r, open(f, "w"), indent=2)
print("console settings applied to", PKG)
