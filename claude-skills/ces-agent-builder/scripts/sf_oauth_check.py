#!/usr/bin/env python3
"""Test a Salesforce External Client App's OAuth client credentials login (the login the Google CX Salesforce connector uses).

  sf_oauth_check.py --org demoOrg                          # instance URL from the sf CLI, key and secret from env or a hidden prompt
  sf_oauth_check.py --instance https://x.my.salesforce.com --soql "SELECT Id FROM Order LIMIT 1"

Key and secret come from the environment (SF_KEY, SF_SECRET) or a hidden prompt. They are never accepted as command line
arguments (they would land in shell history) and the access token is never printed. Run it yourself in a terminal; do not paste
the key or secret into a chat.

On failure it explains the usual cause and fix, from the errors seen in practice.
"""
import argparse
import getpass
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

HINTS = [
    ("invalid_client_id", "The consumer key is wrong or empty. Copy it again from the app's Settings tab (OAuth Settings -> Consumer Key and Secret). A new app can take a few minutes to become active."),
    ("invalid_client", "The consumer secret does not match the key. Copy both again; check for a trailing space or newline."),
    ("no valid scopes defined", "The app has no OAuth scope that works for this flow. In the app's Settings tab -> OAuth Settings select 'Manage user data via APIs (api)' (not 'Full access'), save, wait a minute."),
    ("no client credentials user enabled", "No Run As user. App -> Policies tab -> Edit -> tick 'Enable Client Credentials Flow' -> choose the Run As user -> Save."),
    ("unsupported_grant_type", "The client credentials flow is not enabled. Tick 'Enable Client Credentials Flow' on both the Settings tab (flow enablement) and the Policies tab."),
    ("scope parameter not supported", "A scope was sent in the request. Salesforce does not accept one for client credentials. In Google's Salesforce tool dialog leave 'OAuth scopes' empty."),
    ("request not supported on this domain", "Use your My Domain URL (https://<domain>.my.salesforce.com) for the token endpoint, not login.salesforce.com or a setup/lightning URL."),
    ("ip restricted", "Set IP Relaxation on the app's Policies tab to 'Relax IP restrictions' (Google's servers have no fixed addresses), or allow the Run As user's login IP ranges."),
    ("inactive user", "The Run As user is inactive or locked. Pick an active user."),
    ("user is not admin approved", "Set Permitted Users on the Policies tab to a setting that allows the Run As user, or pre-authorize the user."),
]
QUERY_HINTS = {
    401: "The token was refused. Re-run the token request; check the Run As user is active.",
    403: "Salesforce refused the call. Give the Run As user 'API Enabled' and read access to the objects and fields the query uses.",
    400: "Salesforce rejected the query. Check object and field names and that the Run As user can see those fields (field-level security).",
}


def call(req):
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except urllib.error.URLError as e:
        return 0, str(e.reason)


def instance_from_cli(org):
    p = subprocess.run(["sf", "org", "display", "-o", org, "--json"], capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit("Could not read org '%s' with the sf CLI: %s" % (org, (p.stdout or p.stderr).strip()[:200]))
    return json.loads(p.stdout)["result"]["instanceUrl"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--org", help="sf CLI org alias (used only to find the instance URL)")
    ap.add_argument("--instance", help="https://<my-domain>.my.salesforce.com")
    ap.add_argument("--soql", default="", help="optional read-only query to run with the token (for example a lookup the agent makes)")
    ap.add_argument("--api", default="v68.0")
    a = ap.parse_args()
    instance = (a.instance or (instance_from_cli(a.org) if a.org else "")).rstrip("/")
    if not instance:
        ap.error("give --instance or --org")
    def ask(name, label):
        value = os.environ.get(name)
        if value:
            return value
        try:
            return getpass.getpass(label)
        except (EOFError, KeyboardInterrupt):
            return ""

    key = ask("SF_KEY", "Consumer key (hidden): ")
    secret = ask("SF_SECRET", "Consumer secret (hidden): ")
    print("endpoint: %s/services/oauth2/token" % instance)
    print("key length %d, secret length %d" % (len(key), len(secret)))
    if not key or not secret:
        print("RESULT: key or secret is empty, so Salesforce cannot authenticate. Set SF_KEY and SF_SECRET in this terminal (use `read -rs`).")
        return 1
    data = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": key, "client_secret": secret}).encode()
    status, body = call(urllib.request.Request(instance + "/services/oauth2/token", data=data))
    try:
        resp = json.loads(body)
    except ValueError:
        resp = {"raw": body[:200]}
    token = resp.pop("access_token", None)
    resp.pop("id", None)
    resp.pop("signature", None)
    print("TOKEN REQUEST: HTTP %s, token issued: %s" % (status, bool(token)))
    print("response without the token:", json.dumps(resp))
    if not token:
        text = (str(resp.get("error", "")) + " " + str(resp.get("error_description", ""))).lower()
        for needle, hint in HINTS:
            if needle in text:
                print("LIKELY CAUSE AND FIX: " + hint)
                break
        else:
            print("No known hint for this error. Check the app's Settings and Policies tabs and the Run As user.")
        return 1
    print("RESULT: OAuth works (scope: %s)." % resp.get("scope"))
    if a.soql:
        q = urllib.parse.urlencode({"q": a.soql})
        status, body = call(urllib.request.Request("%s/services/data/%s/query?%s" % (instance, a.api, q), headers={"Authorization": "Bearer " + token}))
        print("QUERY: HTTP %s" % status)
        print(body[:500])
        if status != 200:
            print("LIKELY CAUSE AND FIX: " + QUERY_HINTS.get(status, "See the response above."))
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
