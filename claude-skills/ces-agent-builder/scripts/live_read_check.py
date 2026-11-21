#!/usr/bin/env python3
"""Run ONE generated Python tool against a real Salesforce org, read-only, without handling any access token.

  live_read_check.py PACKAGE_DIR --tool verify_order_caller --org demoOrg \
      --args '{"order_number": "101", "phone_number": "4165550142"}' [--vars '{"caller_verified": true}']

The tool's GET requests are sent through the `sf` CLI (which signs in by itself). POST and PATCH are refused, so
this can never change data. The Authorization header the tool builds is ignored here; header handling is covered by
selftest_tools.py. Use this to prove query text, field names and result mapping against real records.
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.parse


class Resp:
    def __init__(self, status, body):
        self.status_code, self._body, self.text = status, body, json.dumps(body)
        self.reason, self.ok = "", status < 400

    def json(self):
        return self._body

    def raise_for_status(self):
        if not self.ok:
            raise RuntimeError("status %s" % self.status_code)


class CliGet:
    def __init__(self, org, instance):
        self.org, self.instance, self.writes_blocked = org, instance.rstrip("/"), 0

    def get(self, url, params=None, **kw):
        path = url.replace(self.instance, "") + ("?" + urllib.parse.urlencode(params) if params else "")
        p = subprocess.run(["sf", "api", "request", "rest", path, "-o", self.org], capture_output=True, text=True)
        try:
            data = json.loads(p.stdout)
        except ValueError:
            data = {}
        return Resp(200 if p.returncode == 0 else 400, data)

    def _blocked(self, *a, **k):
        self.writes_blocked += 1
        print("BLOCKED: live_read_check never sends POST/PATCH", file=sys.stderr)
        return Resp(403, {"error": "writes are blocked in live_read_check"})

    post = patch = put = delete = _blocked


class CliTools:
    """Stands in for the CES `tools` global: tools.<connector>({"q": soql}) becomes a GET /query through the sf CLI."""
    def __init__(self, cli):
        self.cli = cli

    def __getattr__(self, name):
        return lambda args: self.cli.get(self.cli.instance + "/services/data/%s/query" % self.cli.api, params=args)


class Ctx:
    def __init__(self, variables):
        self.variables = variables
        self.state = variables


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("package")
    ap.add_argument("--tool", required=True)
    ap.add_argument("--org", required=True)
    ap.add_argument("--args", default="{}")
    ap.add_argument("--vars", default="{}")
    ap.add_argument("--connector", action="store_true", help="the tool calls Salesforce through the connector tool (tools.<name>) instead of ces_requests")
    a = ap.parse_args()
    src_path = os.path.join(a.package, "tools", a.tool, "python_function", "python_code.py")
    with open(src_path, encoding="utf-8") as fh:
        src = fh.read()
    info = json.loads(subprocess.run(["sf", "org", "display", "-o", a.org, "--json"], capture_output=True, text=True).stdout)["result"]
    variables = json.loads(a.vars)
    import re
    m = re.search(r"TOKEN_VARIABLE = '([^']+)'", src)
    variables[m.group(1) if m else "salesforce_access_token"] = "placeholder-not-a-real-token"
    ctx = Ctx(variables)
    fake = CliGet(a.org, info["instanceUrl"])
    ns = {"context": ctx, "ces_requests": fake}
    if a.connector:
        fake.api = "v" + str(info.get("apiVersion", "60.0")).lstrip("v")
        ns["tools"] = CliTools(fake)
    exec(compile(src, a.tool, "exec"), ns)
    result = ns[a.tool](**json.loads(a.args))
    print(json.dumps(result, indent=2, default=str))
    shown = {k: v for k, v in ctx.variables.items() if k not in ("salesforce_access_token",)}
    print("variables after the call:", json.dumps(shown, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
