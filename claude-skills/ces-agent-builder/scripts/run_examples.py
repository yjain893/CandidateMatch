#!/usr/bin/env python3
"""Regression check for the skill itself: builds every example spec with validation and self-tests, in a temp folder.

  python3 run_examples.py            exit code 0 only if every example builds clean

Run it after changing any script, template or example.
"""
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)


CALLBACK_PATH = re.compile(r"^agents/[^/]+/((?:before|after)_(?:agent|model|tool)_callbacks)/\1_(\d\d)/python_code\.py$")


def callback_layout_problems(pkg):
    """Callback files must sit where the console exports them (verified against a real export): <type>_callbacks/<type>_callbacks_01/."""
    problems = []
    for jf in glob.glob(os.path.join(pkg, "agents", "*", "*.json")):
        agent = json.load(open(jf))
        seen = {}
        for key, entries in agent.items():
            if not key.endswith("Callbacks"):
                continue
            for i, entry in enumerate(entries, 1):
                m = CALLBACK_PATH.match(entry.get("pythonCode", ""))
                if not m or int(m.group(2)) != i:
                    problems.append("%s: callback path '%s' is not the console layout" % (key, entry.get("pythonCode")))
                if not os.path.isfile(os.path.join(pkg, entry.get("pythonCode", ""))):
                    problems.append("%s: file missing" % entry.get("pythonCode"))
    return problems


def guard_problems():
    """Checks that the generator refuses mistakes it once let through."""
    sys.path.insert(0, HERE)
    from ces_lib import openapi_sf
    from ces_lib.common import SpecError
    problems = []
    two_queries = [{"kind": "soql_query", "operationId": "a", "allow_free_soql": True}, {"kind": "soql_query", "operationId": "b", "allow_free_soql": True}]
    try:
        openapi_sf.build_schema("https://x.my.salesforce.com", "v60.0", "t", two_queries)
        problems.append("two soql_query operations (both GET /query) were accepted; one silently replaces the other")
    except SpecError:
        pass
    return problems


def main():
    specs = sorted(glob.glob(os.path.join(SKILL, "assets", "example-*", "spec.json")))
    bad = 0
    for spec in specs:
        out = tempfile.mkdtemp(prefix="ces_example_")
        r = subprocess.run([sys.executable, os.path.join(HERE, "build_agent.py"), spec, "--out", out, "--selftest"], capture_output=True, text=True)
        lines = [l for l in r.stdout.splitlines() if "error(s)" in l or "SELFTEST" in l or "Import this file" in l]
        status = "OK  " if r.returncode == 0 else "FAIL"
        bad += r.returncode != 0
        cb_note = ""
        if r.returncode == 0:
            pkgs = [d for d in glob.glob(os.path.join(out, "*")) if os.path.isfile(os.path.join(d, "app.json"))]
            for pkg in pkgs:
                layout = callback_layout_problems(pkg)
                if layout:
                    status, bad = "FAIL", bad + 1
                    print("\n".join(layout))
                c = subprocess.run([sys.executable, os.path.join(HERE, "selftest_callbacks.py"), pkg], capture_output=True, text=True)
                cb_note = " | " + c.stdout.strip().splitlines()[-1]
                if c.returncode != 0:
                    status, bad = "FAIL", bad + 1
                    print(c.stdout[-1500:])
        print("%s %-28s %s%s" % (status, os.path.basename(os.path.dirname(spec)), " | ".join(l.strip() for l in lines), cb_note))
        if r.returncode != 0:
            print(r.stdout[-1500:], r.stderr[-800:])
    for problem in guard_problems():
        bad += 1
        print("FAIL guard: " + problem)
    print("\n%d example(s), %d failing" % (len(specs), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
