#!/usr/bin/env python3
"""Read-only Salesforce org discovery for the ces-agent-builder skill.

Uses the `sf` CLI (already signed in) so this script never sees or stores an access token.
Only GET requests are made: org info, global describe, object describe, COUNT() queries.

Examples
  sf_discover.py --check
  sf_discover.py --org demoOrg --keywords order,delivery,phone --out ./project/discovery
  sf_discover.py --org demoOrg --objects Order,Account,Case --out ./project/discovery
  sf_discover.py --org demoOrg --all-custom --no-counts

Outputs (in --out)
  org-profile.json   full machine-readable profile (objects, fields, picklists, relationships)
  org-summary.md     compact summary that is meant to be read by the model / the user
"""
import argparse
import concurrent.futures as cf
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse

STANDARD_DEFAULTS = [
    "Account", "Contact", "Lead", "Opportunity", "Case", "Order", "OrderItem", "Product2",
    "Asset", "Contract", "Task", "Event", "Quote", "WorkOrder", "ServiceAppointment",
]
SENSITIVE_HINTS = re.compile(r"(ssn|social.?security|password|secret|token|credit.?card|card.?number|cvv|iban|bank.?account|passport|license.?number|date.?of.?birth|birth.?date|dob|health|diagnos|medical)", re.I)


def run_sf(args, timeout=120):
    """Run an sf command and return (returncode, stdout, stderr)."""
    if shutil.which("sf") is None:
        raise SystemExit("The `sf` CLI is not installed or not on PATH. Install it from https://developer.salesforce.com/tools/salesforcecli")
    p = subprocess.run(["sf"] + args, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr


def rest_get(alias, path):
    code, out, err = run_sf(["api", "request", "rest", path, "-o", alias])
    if code != 0:
        raise RuntimeError("GET %s failed: %s" % (path, (out or err).strip()[:300]))
    try:
        return json.loads(out)
    except ValueError:
        raise RuntimeError("GET %s returned non-JSON output" % path)


def check_orgs():
    code, out, err = run_sf(["org", "list", "--json"])
    if code != 0:
        print("Could not list orgs: %s" % (err or out).strip()[:300])
        return 1
    result = json.loads(out).get("result", {})
    seen, rows = set(), []
    for group, items in result.items():
        if not isinstance(items, list):
            continue
        for o in items:
            key = o.get("username")
            if key in seen:
                continue
            seen.add(key)
            rows.append({
                "alias": o.get("alias"), "username": o.get("username"),
                "instanceUrl": o.get("instanceUrl"), "type": group,
                "default": bool(o.get("isDefaultUsername")), "status": o.get("connectedStatus"),
            })
    print(json.dumps(rows, indent=2))
    if not rows:
        print("No authenticated orgs. Run: sf org login web --alias <name>")
    return 0


def org_info(alias):
    code, out, err = run_sf(["org", "display", "-o", alias, "--json"])
    if code != 0:
        raise SystemExit("Could not read org '%s': %s" % (alias, (out or err).strip()[:300]))
    r = json.loads(out)["result"]
    r.pop("accessToken", None)          # never keep a token, even a redacted placeholder
    r.pop("sfdxAuthUrl", None)
    return r


def field_summary(f):
    d = {
        "name": f["name"], "label": f.get("label"), "type": f.get("type"),
        "length": f.get("length"), "nillable": f.get("nillable"),
        "createable": f.get("createable"), "updateable": f.get("updateable"),
        "filterable": f.get("filterable"),
    }
    for flag in ("unique", "autoNumber", "externalId", "calculated", "custom", "idLookup"):
        if f.get(flag):
            d[flag] = True
    if f.get("referenceTo"):
        d["referenceTo"] = f["referenceTo"]
        d["relationshipName"] = f.get("relationshipName")
    if f.get("picklistValues"):
        d["picklist"] = [p["value"] for p in f["picklistValues"] if p.get("active")]
    if SENSITIVE_HINTS.search(f["name"] + " " + (f.get("label") or "")):
        d["sensitive_hint"] = True
    return d


def describe_object(alias, api, name):
    d = rest_get(alias, "/services/data/%s/sobjects/%s/describe" % (api, name))
    return {
        "name": d["name"], "label": d.get("label"), "custom": d.get("custom"), "keyPrefix": d.get("keyPrefix"),
        "queryable": d.get("queryable"), "createable": d.get("createable"),
        "updateable": d.get("updateable"), "deletable": d.get("deletable"),
        "recordTypes": [r["name"] for r in d.get("recordTypeInfos", []) if r.get("active") and not r.get("master")],
        "fields": [field_summary(f) for f in d.get("fields", [])],
        "childRelationships": [
            {"child": c["childSObject"], "field": c["field"]}
            for c in d.get("childRelationships", []) if c.get("childSObject") and not c.get("deprecatedAndHidden")
        ][:40],
    }


def count_rows(alias, api, name):
    try:
        q = urllib.parse.quote("SELECT COUNT() FROM %s" % name)
        return rest_get(alias, "/services/data/%s/query?q=%s" % (api, q)).get("totalSize")
    except Exception:
        return None


def build_summary(info, profile, keywords):
    L = []
    L.append("# Salesforce org discovery: %s\n" % (info.get("alias") or info.get("username")))
    L.append("- Instance URL: `%s`" % info.get("instanceUrl"))
    L.append("- API version: `v%s`" % str(info.get("apiVersion")).lstrip("v"))
    L.append("- Org type: %s%s" % (profile["org"].get("orgType", "unknown"), " (sandbox)" if profile["org"].get("isSandbox") else ""))
    L.append("- Objects described: %d  (read-only discovery, no record data read)\n" % len(profile["objects"]))
    L.append("## Objects\n")
    L.append("| Object | Label | Custom | Rows | Create | Update | Fields |")
    L.append("|---|---|---|---|---|---|---|")
    for o in profile["objects"]:
        L.append("| %s | %s | %s | %s | %s | %s | %d |" % (
            o["name"], o["label"], "yes" if o["custom"] else "", "?" if o.get("rows") is None else o["rows"],
            "yes" if o["createable"] else "no", "yes" if o["updateable"] else "no", len(o["fields"])))
    empty = [o["name"] for o in profile["objects"] if o.get("rows") == 0]
    if empty:
        L.append("\n> No rows in: %s. A live test needs test data first (ask the user before creating any)." % ", ".join(empty))
    if keywords:
        L.append("\n## Keyword matches (%s)\n" % ", ".join(keywords))
        if not profile["keyword_hits"]:
            L.append("No object or field names/labels matched.")
        for obj, hits in profile["keyword_hits"].items():
            L.append("- **%s**: %s" % (obj, ", ".join("%s (%s)" % (h["name"], h["type"]) for h in hits[:25])))
    extras = [o["name"] for o in profile["objects"] if not o.get("focus")]
    if extras:
        L.append("\nObjects pulled in only by keyword (listed above, no field detail; ask for one by name with --objects): " + ", ".join(extras))
    L.append("\n## Key fields per object\n")
    for o in profile["objects"]:
        if not o.get("focus"):
            continue
        L.append("### %s" % o["name"])
        ident = [f for f in o["fields"] if f.get("autoNumber") or f.get("unique") or f.get("externalId")]
        names = [f for f in o["fields"] if f["name"] in ("Name", "Subject", "CaseNumber", "OrderNumber")]
        phones = [f for f in o["fields"] if f["type"] in ("phone", "email")]
        status = [f for f in o["fields"] if "picklist" in f and re.search(r"status|stage|priority|type|origin|reason", f["name"], re.I)]
        lookups = [f for f in o["fields"] if f.get("referenceTo")]
        sens = [f for f in o["fields"] if f.get("sensitive_hint")]
        if ident:
            L.append("- Identifier-like: " + ", ".join("%s%s" % (f["name"], " (autonumber)" if f.get("autoNumber") else "") for f in ident))
        if names:
            L.append("- Name-like: " + ", ".join(f["name"] for f in names))
        if phones:
            L.append("- Phone/email: " + ", ".join(f["name"] for f in phones))
        for f in status[:6]:
            L.append("- Picklist `%s`: %s" % (f["name"], ", ".join(f["picklist"][:12]) + (" ..." if len(f["picklist"]) > 12 else "")))
        if lookups:
            L.append("- Lookups: " + ", ".join("%s->%s" % (f["name"], "/".join(f["referenceTo"][:2])) for f in lookups[:12]))
        custom = [f["name"] for f in o["fields"] if f["name"].endswith("__c")]
        if custom:
            L.append("- Custom fields (%d): %s" % (len(custom), ", ".join(custom[:25]) + (" ..." if len(custom) > 25 else "")))
        if sens:
            L.append("- Possibly sensitive (do not read aloud, do not return from tools unless required): " + ", ".join(f["name"] for f in sens[:10]))
        if o["recordTypes"]:
            L.append("- Record types: " + ", ".join(o["recordTypes"]))
        L.append("")
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="list authenticated orgs and exit")
    ap.add_argument("--org", help="sf org alias or username")
    ap.add_argument("--keywords", default="", help="comma separated words to look for in object and field names/labels")
    ap.add_argument("--objects", default="", help="comma separated objects to describe in addition to the defaults")
    ap.add_argument("--all-custom", action="store_true", help="describe every custom object (can be slow in big orgs)")
    ap.add_argument("--no-standard", action="store_true", help="skip the default standard object list")
    ap.add_argument("--no-counts", action="store_true", help="skip COUNT() queries")
    ap.add_argument("--max-objects", type=int, default=40)
    ap.add_argument("--out", default="./discovery")
    a = ap.parse_args()

    if a.check:
        return check_orgs()
    if not a.org:
        ap.error("--org is required (or use --check)")

    info = org_info(a.org)
    info["alias"] = a.org
    api = "v" + str(info.get("apiVersion", "60.0")).lstrip("v")
    keywords = [k.strip().lower() for k in a.keywords.split(",") if k.strip()]

    glob = rest_get(a.org, "/services/data/%s/sobjects" % api)["sobjects"]
    by_name = {s["name"]: s for s in glob}
    chosen = []
    focus_names = set()

    def add(n, focus=True):
        if n in by_name and by_name[n].get("queryable") and n not in chosen:
            chosen.append(n)
            if focus:
                focus_names.add(n)

    for n in [x.strip() for x in a.objects.split(",") if x.strip()]:
        add(n)
    custom = [s["name"] for s in glob if s.get("custom") and s.get("queryable") and not s["name"].endswith(("__Share", "__History", "__Feed", "__ChangeEvent", "__e"))]
    if a.all_custom or len(custom) <= 12:
        for n in custom:
            add(n)
    if not a.no_standard:
        for n in STANDARD_DEFAULTS:
            add(n)
    for kw in keywords:
        for s in glob:
            if s.get("queryable") and (kw in s["name"].lower() or kw in (s.get("label") or "").lower()):
                if not s["name"].endswith(("Share", "History", "Feed", "ChangeEvent", "Event")):
                    add(s["name"], focus=False)
    chosen = chosen[: a.max_objects]

    objects = []
    with cf.ThreadPoolExecutor(4) as ex:
        futs = {n: ex.submit(describe_object, a.org, api, n) for n in chosen}
        for n in chosen:
            try:
                obj = futs[n].result()
                obj["focus"] = n in focus_names
                objects.append(obj)
            except Exception as e:
                print("skip %s: %s" % (n, e), file=sys.stderr)
    if not a.no_counts:
        with cf.ThreadPoolExecutor(4) as ex:
            counts = list(ex.map(lambda o: count_rows(a.org, api, o["name"]), objects))
        for o, c in zip(objects, counts):
            o["rows"] = c

    hits = {}
    for o in objects:
        for f in o["fields"]:
            text = (f["name"] + " " + (f.get("label") or "")).lower()
            if any(k in text for k in keywords):
                hits.setdefault(o["name"], []).append(f)

    org_row = {}
    try:
        q = urllib.parse.quote("SELECT OrganizationType, IsSandbox FROM Organization")
        rec = rest_get(a.org, "/services/data/%s/query?q=%s" % (api, q))["records"][0]
        org_row = {"orgType": rec.get("OrganizationType"), "isSandbox": rec.get("IsSandbox")}
    except Exception:
        pass

    profile = {
        "org": dict(org_row, alias=a.org, instanceUrl=info.get("instanceUrl"), apiVersion=api, username=info.get("username")),
        "keywords": keywords, "objects": objects, "keyword_hits": {k: [{"name": f["name"], "type": f["type"]} for f in v] for k, v in hits.items()},
    }
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "org-profile.json"), "w") as fh:
        json.dump(profile, fh, indent=1)
    summary = build_summary(info, profile, keywords)
    with open(os.path.join(a.out, "org-summary.md"), "w") as fh:
        fh.write(summary)
    print("Wrote %s and %s" % (os.path.join(a.out, "org-profile.json"), os.path.join(a.out, "org-summary.md")))
    print("Described %d objects. Read org-summary.md next." % len(objects))
    return 0


if __name__ == "__main__":
    sys.exit(main())
