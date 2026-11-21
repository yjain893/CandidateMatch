#!/usr/bin/env python3
"""Run the generated Python tools against offline scenarios (no network, no Salesforce, no Google).

  selftest_tools.py OUT/_selftest/scenarios.json

The CES sandbox globals (context, ces_requests) are replaced with fakes. Each scenario sets session variables, scripts the
Salesforce replies, calls the tool, and checks the result, the variables the tool wrote, and the requests it made.
"""
import json
import os
import re
import sys
import urllib.parse


class Resp:
    def __init__(self, status, body):
        self.status_code = status
        self._body = body
        self.text = json.dumps(body)
        self.reason = ""
        self.ok = status < 400

    def json(self):
        return self._body

    def raise_for_status(self):
        if not self.ok:
            raise RuntimeError("status %s" % self.status_code)


class FakeRequests:
    def __init__(self, responses):
        self.responses = responses
        self.calls = []

    def _do(self, method, url, params=None, json_body=None, headers=None):
        query = ("?" + urllib.parse.unquote_plus(urllib.parse.urlencode(params))) if params else ""
        text = "%s %s%s" % (method, url, query)
        if json_body is not None:
            text += " BODY " + json.dumps(json_body)
        self.calls.append({"text": text, "headers": headers or {}})
        for r in self.responses:
            if r["when"] in text:
                return Resp(r.get("status", 200), r.get("json", {}))
        return Resp(404, {"errorCode": "NOT_FOUND"})

    def get(self, url, params=None, **kw):
        return self._do("GET", url, params=params, headers=kw.get("headers"))

    def post(self, url, data=None, json=None, **kw):
        return self._do("POST", url, json_body=json if json is not None else data, headers=kw.get("headers"))

    def patch(self, url, data=None, json=None, **kw):
        return self._do("PATCH", url, json_body=json if json is not None else data, headers=kw.get("headers"))


class ConnectorError(Exception):
    """A connector call that raises instead of returning, with the status the platform would attach."""
    def __init__(self, status):
        super().__init__("status %s" % status)
        self.status_code = status


class FakeTools:
    """Stands in for the CES `tools` global: tools.<connector_name>({"q": soql}) behaves like GET <instance>/query?q=..."""
    def __init__(self, responses, calls):
        self.responses, self.calls = responses, calls

    def __getattr__(self, name):
        def call(args):
            if set(args) == {"q"}:
                text = "GET connector://%s/query?q=%s" % (name, urllib.parse.unquote_plus(urllib.parse.urlencode(args)).replace("q=", "", 1))
            else:
                text = "CALL connector://%s/args %s" % (name, json.dumps(args))
            self.calls.append({"text": text, "headers": {}})
            for r in self.responses:
                if r["when"] in text:
                    if r.get("raise"):
                        raise ConnectorError(r.get("status", 500))
                    return Resp(r.get("status", 200), r.get("json", {}))
            return Resp(404, {"errorCode": "NOT_FOUND"})
        return call


class FakePart:
    def __init__(self, text):
        self.text = text

    def text_or_transcript(self):
        return self.text


class FakeContent:
    def __init__(self, text):
        self.parts = [FakePart(text)]


class FakeEvent:
    """A session event as the CES Python runtime describes it: author, timestamp, content.parts, is_user()."""
    def __init__(self, d):
        self.author = d["author"]
        self.timestamp = d.get("timestamp")
        self.content = FakeContent(d["text"])

    def is_user(self):
        return self.author == "user"


class Ctx:
    def __init__(self, variables, events=None, session_id="sess-test", agent_name=""):
        self.variables = variables
        self.state = variables
        self.events = events or []
        self.session_id = session_id
        self.agent_name = agent_name


def load_tool(package, name):
    path = os.path.join(package, "tools", name, "python_function", "python_code.py")
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def run_scenario(package, sc, query_patterns=None):
    src = load_tool(package, sc["tool"])
    variables = dict(sc.get("variables", {}))
    no_token = variables.pop("__no_token__", False)
    m = re.search(r"TOKEN_VARIABLE = '([^']+)'", src) or re.search(r'TOKEN_VARIABLE = "([^"]+)"', src)
    token_var = m.group(1) if m else "salesforce_access_token"
    secret = "tok-test-SECRET-123"
    if not no_token:
        variables[token_var] = secret
    ctx = Ctx(variables, [FakeEvent(e) for e in sc.get("events", [])], sc.get("session_id", "sess-test"), sc.get("agent_name", ""))
    fake = FakeRequests(sc.get("responses", []))
    ns = {"context": ctx, "ces_requests": fake}
    connector = sc.get("transport") == "connector"
    if connector:
        ns["tools"] = FakeTools(sc.get("responses", []), fake.calls)
    ns["get_variable"] = lambda k, d=None: ctx.variables.get(k, d)
    ns["set_variable"] = lambda k, v: ctx.variables.__setitem__(k, v)
    exec(compile(src, sc["tool"], "exec"), ns)
    problems = []
    try:
        result = ns[sc["tool"]](**sc.get("args", {}))
    except Exception as e:
        return ["raised %s: %s" % (type(e).__name__, e)]
    if not isinstance(result, dict):
        return ["result is %s, expected dict" % type(result).__name__]
    try:
        dumped = json.dumps(result)
    except TypeError as e:
        return ["result is not JSON serializable: %s" % e]
    if secret in dumped:
        problems.append("the access token leaked into the tool result")
    for k, v in (sc.get("expect") or {}).items():
        if k not in result:
            problems.append("result has no '%s' (got keys %s)" % (k, sorted(result)))
        elif result[k] != v:
            problems.append("result['%s'] = %r, expected %r" % (k, result[k], v))
    for k in sc.get("expect_absent") or []:
        if k in result:
            problems.append("result must not contain '%s' (information leak)" % k)
    for s in sc.get("result_must_not_contain") or []:
        if s and s in dumped:
            problems.append("the result must not contain %r (information leak)" % s)
    for k, v in (sc.get("expect_variables") or {}).items():
        if ctx.variables.get(k) != v:
            problems.append("variable %s = %r, expected %r" % (k, ctx.variables.get(k), v))
    joined = "\n".join(c["text"] for c in fake.calls)
    if sc.get("expect_no_calls") and fake.calls:
        problems.append("made %d request(s) but should have made none" % len(fake.calls))
    if "expect_call_count" in sc and len(fake.calls) != sc["expect_call_count"]:
        problems.append("made %d request(s), expected %d" % (len(fake.calls), sc["expect_call_count"]))
    for s in sc.get("calls_must_contain") or []:
        if s not in joined:
            problems.append("requests do not contain %r" % s)
    for s in sc.get("calls_must_not_contain") or []:
        if s and s in joined:
            problems.append("requests must not contain %r" % s)
    for c in fake.calls:
        if connector:
            break
        if "Bearer " + secret not in str(c["headers"].get("Authorization", "")) and not no_token:
            problems.append("a request had no bearer token header")
            break
    # the query must satisfy the pattern that locks the connector operation it is sent to
    for c in fake.calls:
        mc = re.match(r"GET connector://([^/]+)/query\?q=(.*)$", c["text"], flags=re.S)
        if mc and (query_patterns or {}).get(mc.group(1)) and not re.search(query_patterns[mc.group(1)], mc.group(2)):
            problems.append("the query does not match the q_pattern of connector operation %s: %s" % (mc.group(1), mc.group(2)[:140]))
    # injection guard: after removing escaped quotes and string literals, no user payload may remain in the SOQL
    for c in fake.calls:
        mq = re.search(r"[?&]?q=(SELECT .*)$", c["text"].split(" BODY ")[0], flags=re.S)
        if mq:
            soql = mq.group(1)
            stripped = re.sub(r"'((?:\\.|[^'\\])*)'", "''", soql)
            if "OR Id" in stripped:
                problems.append("SOQL injection: user text escaped out of its string literal")
    return problems


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
    package = data["package"]
    scenarios = data["scenarios"]
    failed = 0
    by_tool = {}
    for sc in scenarios:
        probs = run_scenario(package, sc, data.get("query_patterns"))
        by_tool.setdefault(sc["tool"], []).append((sc["name"], probs))
        failed += 1 if probs else 0
    for tool, rows in by_tool.items():
        ok = sum(1 for _n, p in rows if not p)
        print("tool %s: %d/%d scenarios passed" % (tool, ok, len(rows)))
        for n, p in rows:
            if p:
                print("   FAIL %s" % n)
                for line in p:
                    print("        - %s" % line)
    print("SELFTEST: %d scenario(s), %d failed" % (len(scenarios), failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
