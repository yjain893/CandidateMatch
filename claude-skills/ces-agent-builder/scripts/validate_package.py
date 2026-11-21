#!/usr/bin/env python3
"""Validate (or inspect) a Google CX Agent Studio / CES agent export package.

Works on a folder or a .zip, for packages built by build_agent.py and for exports downloaded from the console.

  validate_package.py PATH            validate; exit code 1 when there are errors
  validate_package.py PATH --inspect  also print a summary of agents, tools, guardrails, variables
  validate_package.py PATH --json     machine readable result

Rules come from the official export format page, the REST reference and the instruction/tool/callback docs
(see references/export-format.md). Secrets found anywhere in the package are ERRORS: a package must never
contain access tokens, client secrets, API keys or private keys.
"""
import argparse
import ast
import difflib
import json
import os
import re
import sys
import tempfile
import zipfile

SYSTEM_TOOLS = {"end_session", "transfer_to_agent", "customize_response"}
RESERVED = set(SYSTEM_TOOLS)
KNOWN_MODELS = {"gemini-composite-v2", "gemini-composite-v1", "gemini-3.7-flash", "gemini-3.5-flash",
                "gemini-3-flash", "gemini-2.5-flash", "gemini-3.1-flash-live"}
GUARDRAIL_TYPES = ["contentFilter", "llmPromptSecurity", "llmPolicy", "modelSafety", "codeCallback", "supervisor"]
ACTION_TYPES = ["respondImmediately", "transferAgent", "generativeAnswer"]
MATCH_TYPES = {"SIMPLE_STRING_MATCH", "WORD_BOUNDARY_STRING_MATCH", "REGEXP_MATCH", "SENSITIVE_WORDS"}
POLICY_SCOPES = {"USER_QUERY", "AGENT_RESPONSE", "USER_QUERY_AND_AGENT_RESPONSE", "POLICY_SCOPE_UNSPECIFIED"}
HARM_CATEGORIES = {"HARM_CATEGORY_HATE_SPEECH", "HARM_CATEGORY_DANGEROUS_CONTENT", "HARM_CATEGORY_HARASSMENT",
                   "HARM_CATEGORY_SEXUALLY_EXPLICIT", "HARM_CATEGORY_PROFANITY", "HARM_CATEGORY_TOXIC"}
HARM_THRESHOLDS = {"BLOCK_LOW_AND_ABOVE", "BLOCK_MEDIUM_AND_ABOVE", "BLOCK_ONLY_HIGH", "BLOCK_NONE", "OFF"}
SUPERVISOR_TYPES = {"INVALID_TEXT", "LANGUAGE_SHIFT", "SPEAKER_SHIFT", "AUDIO_MISMATCH", "MISSING_TOOL_CALL", "CUSTOM",
                    "CHOPPY_AUDIO", "PROFANITY"}
DETECTION_MODES = {"NON_BLOCKING", "BLOCKING", "DETECTION_MODE_UNSPECIFIED"}
VAR_TYPES = {"STRING", "NUMBER", "INTEGER", "BOOLEAN", "OBJECT", "ARRAY"}
CALLBACK_FUNCS = {
    "beforeAgentCallbacks": "before_agent_callback", "afterAgentCallbacks": "after_agent_callback",
    "beforeModelCallbacks": "before_model_callback", "afterModelCallbacks": "after_model_callback",
    "beforeToolCallbacks": "before_tool_callback", "afterToolCallbacks": "after_tool_callback",
}
# variables the phone platform fills in; Google's documentation gives them names with hyphens
PLATFORM_VARIABLES = {"telephony-caller-id", "uui-headers", "x-headers"}
STRUCT_TAGS = ["role", "persona", "primary_goal", "constraints", "taskflow", "subtask", "step", "trigger", "action", "examples"]
SENSITIVE_NAME = re.compile(r"(token|secret|password|passwd|api[_-]?key|private[_-]?key|credential)", re.I)
SECRET_PATTERNS = [
    ("Salesforce session/access token", re.compile(r"\b00D[A-Za-z0-9]{12,15}![A-Za-z0-9_.\-]{20,}")),
    ("Bearer token", re.compile(r"[Bb]earer\s+[A-Za-z0-9._\-]{30,}")),
    ("Private key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}\b")),
    ("AWS access key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("Assigned secret value", re.compile(r"""(?i)\b(client_secret|secret|password|api[_-]?key|access_token)\b["']?\s*[:=]\s*["']([A-Za-z0-9._\-!/+=]{20,})["']""")),
]
PLACEHOLDER = re.compile(r"(<[^>]+>|REPLACE|YOUR_|\$context|\$env|projects/|example|changeme|xxxx)", re.I)
STDLIB_FALLBACK = set("""abc argparse array ast asyncio base64 binascii bisect calendar collections colorsys copy csv dataclasses datetime decimal
difflib enum fractions functools hashlib heapq hmac html itertools json math numbers operator pprint random re statistics string
struct textwrap time typing unicodedata urllib uuid warnings zoneinfo contextlib secrets string""".split())
ALLOWED_THIRD_PARTY = {"pydantic", "numpy", "google"}


class Report:
    def __init__(self):
        self.items = []

    def add(self, level, where, msg):
        self.items.append({"level": level, "where": where, "msg": msg})

    def error(self, where, msg):
        self.add("ERROR", where, msg)

    def warn(self, where, msg):
        self.add("WARN", where, msg)

    def info(self, where, msg):
        self.add("INFO", where, msg)

    def count(self, level):
        return sum(1 for i in self.items if i["level"] == level)


def load_json(path, rep, where):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        rep.error(where, "file not found: %s" % path)
    except ValueError as e:
        rep.error(where, "invalid JSON: %s" % e)
    return None


def find_root(path):
    if path.lower().endswith(".zip"):
        tmp = tempfile.mkdtemp(prefix="ces_pkg_")
        with zipfile.ZipFile(path) as z:
            z.extractall(tmp)
        path = tmp
    if os.path.isfile(os.path.join(path, "app.json")) or os.path.isfile(os.path.join(path, "app.yaml")):
        return path
    for d in sorted(os.listdir(path)):
        sub = os.path.join(path, d)
        if os.path.isdir(sub) and (os.path.isfile(os.path.join(sub, "app.json")) or os.path.isfile(os.path.join(sub, "app.yaml"))):
            return sub
    return path


def read_text(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8") as fh:
        return fh.read()


def check_python(root, rel, where, rep, expect_func, is_tool):
    full = os.path.join(root, rel)
    if not os.path.isfile(full):
        rep.error(where, "python file missing: %s" % rel)
        return None
    src = read_text(root, rel)
    try:
        tree = ast.parse(src)
    except SyntaxError as e:
        rep.error(where, "python syntax error line %s: %s" % (e.lineno, e.msg))
        return None
    funcs = {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}
    if expect_func not in funcs:
        rep.error(where, "no top-level function named '%s' (found: %s)" % (expect_func, ", ".join(funcs) or "none"))
        return None
    fn = funcs[expect_func]
    if is_tool:
        args = [a for a in fn.args.args]
        for a in args:
            if a.annotation is None:
                rep.warn(where, "parameter '%s' has no type hint; the model sees no type" % a.arg)
            if len(a.arg) < 3 and a.arg not in ("id",):
                rep.warn(where, "parameter '%s' is too short; use descriptive snake_case names" % a.arg)
        doc = ast.get_docstring(fn) or ""
        if not doc:
            rep.error(where, "tool function has no docstring; the docstring is the tool description sent to the model")
        else:
            missing = [a.arg for a in args if not re.search(r"\b%s\b\s*(\([^)]*\))?\s*:" % re.escape(a.arg), doc)]
            if missing:
                rep.warn(where, "docstring Args section does not describe: %s" % ", ".join(missing))
            if len(doc) > 3500:
                rep.warn(where, "docstring is %d chars; long tool descriptions add tokens to every model call" % len(doc))
        if fn.returns is None:
            rep.info(where, "no return type hint (-> dict is recommended)")
    for node in ast.walk(tree):
        mods = []
        if isinstance(node, ast.Import):
            mods = [a.name.split(".")[0] for a in node.names]
        elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
            mods = [node.module.split(".")[0]]
        for m in mods:
            if m == "requests":
                rep.warn(where, "imports 'requests'; the documented HTTP client is the global ces_requests")
                continue
            std = getattr(sys, "stdlib_module_names", None) or STDLIB_FALLBACK
            if m not in std and m not in ALLOWED_THIRD_PARTY:
                rep.warn(where, "import '%s' is outside the documented sandbox (stdlib, pydantic, numpy, protobuf)" % m)
    return src


def scan_secrets(root, rep):
    for base, _dirs, files in os.walk(root):
        for f in files:
            if f.endswith((".zip", ".png", ".jpg", ".DS_Store")) or f == ".DS_Store":
                continue
            full = os.path.join(base, f)
            rel = os.path.relpath(full, root)
            try:
                with open(full, encoding="utf-8") as fh:
                    lines = fh.read().splitlines()
            except (UnicodeDecodeError, OSError):
                continue
            for i, line in enumerate(lines, 1):
                for label, pat in SECRET_PATTERNS:
                    m = pat.search(line)
                    if not m:
                        continue
                    value = m.group(2) if m.lastindex and m.lastindex >= 2 else m.group(0)
                    if PLACEHOLDER.search(value) or PLACEHOLDER.search(line) and label == "Assigned secret value":
                        continue
                    rep.error("%s:%d" % (rel, i), "%s found (%s...). Remove it; set secrets after import or use Secret Manager." % (label, value[:6]))


def check_instruction(text, where, agent_name, agent, ctx, rep, is_global=False):
    tools_ok = set(agent.get("tools", [])) | ctx["toolset_ops_for_agent"].get(agent_name, set())
    children = set(agent.get("childAgents", []))
    for m in re.finditer(r"\{@TOOL:\s*([^}]+?)\s*\}", text):
        t = m.group(1)
        if t not in tools_ok:
            rep.error(where, "{@TOOL: %s} is not a tool of agent '%s' (this is what draws the red underline)" % (t, agent_name))
    for m in re.finditer(r"\{@AGENT:\s*([^}]+?)\s*\}", text):
        a = m.group(1)
        if a not in ctx["agents"]:
            rep.error(where, "{@AGENT: %s} does not exist" % a)
        elif a not in children and a != agent_name:
            rep.warn(where, "{@AGENT: %s} is not a child agent of '%s'" % (a, agent_name))
    for call, tool in (("end_session(", "end_session"), ("customize_response(", "customize_response")):
        if call in text and tool not in agent.get("tools", []):
            rep.error(where, "instructions call %s but the agent has no '%s' tool in its tools list" % (tool, tool))
    declared = ctx["variables"]
    stripped = re.sub(r"\{%.*?%\}", "", text, flags=re.S)
    for m in re.finditer(r"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)[^}]*\}\}", stripped):
        v = m.group(1)
        if v not in declared and v != "_session":
            rep.warn(where, "static variable {{%s}} is not declared in app variableDeclarations" % v)
        if v in ctx["written_vars"]:
            rep.warn(where, "{{%s}} is a static reference but a tool writes it at runtime; use {%s} (dynamic)" % (v, v))
    no_static = re.sub(r"\{\{[^}]*\}\}", "", stripped)
    for m in re.finditer(r"(?<![\{@])\{([A-Za-z_][A-Za-z0-9_.]*)\}", no_static):
        v = m.group(1).split(".")[0]
        if v not in declared and v != "_session":
            rep.warn(where, "variable {%s} is not declared in app variableDeclarations" % v)
    opens = len(re.findall(r"\{%\s*(if|for|macro)\b", text))
    closes = len(re.findall(r"\{%\s*end(if|for|macro)\b", text))
    if opens != closes:
        rep.error(where, "unbalanced {%% %%} blocks: %d opened, %d closed" % (opens, closes))
    stack = []
    for m in re.finditer(r"<(/?)(%s)\b([^>]*)>" % "|".join(STRUCT_TAGS), text):
        closing, tag = m.group(1) == "/", m.group(2)
        line = text[: m.start()].count("\n") + 1
        if not closing:
            stack.append((tag, line))
            if tag in ("subtask", "step") and "name=" not in m.group(3):
                rep.warn("%s:%d" % (where, line), "<%s> has no name attribute" % tag)
        else:
            if not stack or stack[-1][0] != tag:
                rep.error("%s:%d" % (where, line), "closing </%s> does not match the open tag %s" % (tag, stack[-1][0] if stack else "none"))
                if stack and any(s[0] == tag for s in stack):
                    while stack and stack[-1][0] != tag:
                        stack.pop()
                    stack.pop()
            else:
                stack.pop()
    for tag, line in stack:
        rep.error("%s:%d" % (where, line), "<%s> is never closed" % tag)
    for sm in re.finditer(r"<step\b[^>]*>(.*?)</step>", text, flags=re.S):
        body = sm.group(1)
        if "<trigger>" not in body or "<action>" not in body:
            line = text[: sm.start()].count("\n") + 1
            rep.error("%s:%d" % (where, line), "a <step> needs both <trigger> and <action>")
    if re.search(r"&(?!amp;|lt;|gt;|quot;|#)", re.sub(r"\{%.*?%\}", "", text, flags=re.S)):
        rep.warn(where, "contains a bare '&'; write 'and' (Google's docs do not say how to escape it and the editor may flag it)")
    if len(text) > 12000:
        rep.warn(where, "instruction is %d chars; shorter, specific instructions follow better" % len(text))
    if "<role>" not in text and not is_global:
        rep.info(where, "no <role> block; Google recommends the role/persona/constraints/taskflow structure")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path")
    ap.add_argument("--inspect", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--quiet", action="store_true", help="only print errors and warnings")
    a = ap.parse_args()

    rep = Report()
    root = find_root(a.path)
    app = load_json(os.path.join(root, "app.json"), rep, "app.json")
    if app is None:
        return finish(rep, a, None)

    # ---------- load every resource ----------
    agents, tools, toolsets, guardrails = {}, {}, {}, {}
    for kind, store in (("agents", agents), ("tools", tools), ("toolsets", toolsets), ("guardrails", guardrails)):
        base = os.path.join(root, kind)
        if not os.path.isdir(base):
            continue
        for d in sorted(os.listdir(base)):
            if d.startswith(".") or not os.path.isdir(os.path.join(base, d)):
                continue
            jf = os.path.join(base, d, d + ".json")
            if not os.path.isfile(jf):
                if os.path.isfile(os.path.join(base, d, d + ".yaml")):
                    rep.warn("%s/%s" % (kind, d), "YAML resource files are not validated by this script")
                else:
                    rep.error("%s/%s" % (kind, d), "missing %s.json" % d)
                continue
            data = load_json(jf, rep, "%s/%s/%s.json" % (kind, d, d))
            if data is None:
                continue
            name = data.get("displayName") or (data.get("pythonFunction") or {}).get("name") or d
            if name in store:
                rep.error("%s/%s" % (kind, d), "duplicate displayName '%s'" % name)
            data["_dir"] = d
            store[name] = data

    # ---------- app ----------
    if not app.get("displayName"):
        rep.error("app.json", "displayName is required")
    root_agent = app.get("rootAgent")
    if root_agent not in agents:
        rep.error("app.json", "rootAgent '%s' is not an agent displayName (agents: %s)" % (root_agent, ", ".join(agents) or "none"))
    model = (app.get("modelSettings") or {}).get("model")
    if model and model not in KNOWN_MODELS:
        rep.warn("app.json", "model '%s' is not in the documented list: %s" % (model, ", ".join(sorted(KNOWN_MODELS))))
    for g in app.get("guardrails", []):
        if g not in guardrails:
            rep.error("app.json", "guardrail '%s' has no folder under guardrails/" % g)
    variables, written = {}, set()
    for v in app.get("variableDeclarations", []):
        n = v.get("name", "")
        if n not in PLATFORM_VARIABLES and not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", n):
            rep.error("app.json", "variable name '%s' must start with a letter/underscore and contain only letters, numbers, underscores" % n)
        if n in variables:
            rep.error("app.json", "variable '%s' declared twice" % n)
        variables[n] = v
        sch = v.get("schema") or {}
        if sch.get("type") not in VAR_TYPES:
            rep.error("app.json", "variable '%s' has type '%s'; use one of %s" % (n, sch.get("type"), ", ".join(sorted(VAR_TYPES))))
        if not v.get("description"):
            rep.info("app.json", "variable '%s' has no description (the console writes variables without one; a description helps readers)" % n)
        default = sch.get("default")
        if SENSITIVE_NAME.search(n) and isinstance(default, str) and default.strip():
            rep.error("app.json", "variable '%s' looks like a secret but has a default value stored in the package" % n)
    ap_cfg = app.get("audioProcessingConfig") or {}
    for loc, cfg in (ap_cfg.get("synthesizeSpeechConfigs") or {}).items():
        rate = cfg.get("speakingRate")
        if rate is not None and not (0.25 <= rate <= 2.0):
            rep.error("app.json", "speakingRate %s for %s must be between 0.25 and 2.0" % (rate, loc))
    if ap_cfg.get("inactivityTimeout") and not re.match(r"^\d+(\.\d+)?s$", ap_cfg["inactivityTimeout"]):
        rep.error("app.json", "inactivityTimeout must look like '10s'")
    gi = app.get("globalInstruction")
    if gi and not os.path.isfile(os.path.join(root, gi)):
        rep.error("app.json", "globalInstruction file missing: %s" % gi)

    # ---------- tools ----------
    for name, t in tools.items():
        where = "tools/%s" % t["_dir"]
        kinds = [k for k in ("pythonFunction", "dataStoreTool", "openApiTool", "googleSearchTool", "connectorTool", "fileSearchTool", "mcpTool", "widgetTool", "clientFunction", "agentTool", "systemTool") if k in t]
        if len(kinds) != 1:
            rep.error(where, "needs exactly one tool type key, found: %s" % (kinds or "none"))
        if name in RESERVED:
            rep.error(where, "'%s' is a reserved system tool name" % name)
        if not re.match(r"^[a-z][a-z0-9_]*$", name):
            rep.warn(where, "tool name '%s' should be lower snake_case" % name)
        if t.get("executionType") not in (None, "SYNCHRONOUS", "ASYNCHRONOUS"):
            rep.error(where, "executionType must be SYNCHRONOUS or ASYNCHRONOUS")
        if "pythonFunction" in t:
            pf = t["pythonFunction"]
            if pf.get("name") != name:
                rep.error(where, "pythonFunction.name '%s' must equal the tool name '%s'" % (pf.get("name"), name))
            src = check_python(root, pf.get("pythonCode", ""), where, rep, pf.get("name", name), True)
            if src:
                for m in re.finditer(r"context\.variables\[\s*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]\s*\]\s*=", src):
                    written.add(m.group(1))
                for m in re.finditer(r"set_variable\(\s*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]", src):
                    written.add(m.group(1))
    names = list(tools)
    for i, n1 in enumerate(names):
        for n2 in names[i + 1:]:
            if difflib.SequenceMatcher(None, n1, n2).ratio() > 0.85:
                rep.warn("tools", "tool names '%s' and '%s' are very similar; make them distinct" % (n1, n2))

    # ---------- toolsets ----------
    env = {}
    env_path = os.path.join(root, "environment.json")
    if os.path.isfile(env_path):
        env = load_json(env_path, rep, "environment.json") or {}
    toolset_ops = {}
    for name, ts in toolsets.items():
        where = "toolsets/%s" % ts["_dir"]
        o = ts.get("openApiToolset")
        if not o:
            rep.warn(where, "only openApiToolset is validated")
            continue
        sp = o.get("openApiSchema", "")
        schema_path = os.path.join(root, sp)
        if not os.path.isfile(schema_path):
            rep.error(where, "openApiSchema file missing: %s" % sp)
            continue
        sch = load_json(schema_path, rep, sp) if sp.endswith(".json") else None
        ops = set()
        if sp.endswith((".yaml", ".yml")):
            ytext = read_text(root, sp)
            for oid in re.findall(r"^\s*operationId:\s*(\S+)", ytext, flags=re.M):
                if oid in ops:
                    rep.error(where, "duplicate operationId %s" % oid)
                ops.add(oid)
            if "servers:" not in ytext:
                rep.warn(where, "schema has no servers[].url (the server comes from the schema)")
            if "$env_var" in ytext and not ((env.get("toolsets") or {}).get(name) or {}).get("openApiToolset", {}).get("url"):
                rep.error(where, "schema uses $env_var for the server URL but environment.json has no toolsets.%s.openApiToolset.url" % name)
        if sch:
            if not sch.get("servers"):
                rep.warn(where, "schema has no servers[].url (the server comes from the schema)")
            for p, methods in (sch.get("paths") or {}).items():
                for meth, op in methods.items():
                    if isinstance(op, dict) and op.get("operationId"):
                        if op["operationId"] in ops:
                            rep.error(where, "duplicate operationId %s" % op["operationId"])
                        ops.add(op["operationId"])
                    elif isinstance(op, dict):
                        rep.warn(where, "%s %s has no operationId" % (meth.upper(), p))
        toolset_ops[name] = ops
        auth = o.get("apiAuthentication") or {}
        if len([k for k in auth if k]) > 1:
            rep.error(where, "apiAuthentication must have at most one auth config")
        bt = (auth.get("bearerTokenConfig") or {}).get("token")
        if bt:
            m = re.match(r"^\$context\.variables\.([A-Za-z_][A-Za-z0-9_]*)$", bt)
            if not m:
                rep.error(where, "bearerTokenConfig.token must be $context.variables.<name>, got '%s'" % bt)
            elif m.group(1) not in variables:
                rep.error(where, "bearer token variable '%s' is not declared" % m.group(1))
        oc = auth.get("oauthConfig")
        if oc:
            env_oc = ((((env.get("toolsets") or {}).get(name) or {}).get("openApiToolset") or {}).get("apiAuthentication") or {}).get("oauthConfig") or {}
            resolved = {}
            for k in ("clientId", "clientSecretVersion", "tokenEndpoint"):
                val = oc.get(k)
                if val == "$env_var":
                    val = env_oc.get(k)
                    if not val:
                        rep.error(where, "oauthConfig.%s is $env_var but environment.json has no value for it" % k)
                if not oc.get(k):
                    rep.error(where, "oauthConfig.%s is required" % k)
                resolved[k] = val
            if oc.get("oauthGrantType") not in (None, "CLIENT_CREDENTIAL", "OAUTH_GRANT_TYPE_UNSPECIFIED"):
                rep.error(where, "only the CLIENT_CREDENTIAL grant type is supported")
            sv = resolved.get("clientSecretVersion")
            if sv and not re.match(r"^projects/[^/]+/secrets/[^/]+/versions/[^/]+$", sv):
                rep.error(where, "clientSecretVersion must look like projects/{project}/secrets/{secret}/versions/{version}")
            if oc.get("scopes") and "salesforce" in str(resolved.get("tokenEndpoint") or "").lower():
                rep.error(where, "oauthConfig.scopes is set but Salesforce answers 'scope parameter not supported' to a client credentials request; leave scopes empty (the scope is chosen in the Salesforce app)")

    # ---------- guardrails ----------
    for name, g in guardrails.items():
        where = "guardrails/%s" % g["_dir"]
        ts_ = [k for k in GUARDRAIL_TYPES if k in g]
        if len(ts_) != 1:
            rep.error(where, "needs exactly one guardrail type among %s, found %s" % (GUARDRAIL_TYPES, ts_ or "none"))
        act = g.get("action")
        if act is not None:
            ak = [k for k in ACTION_TYPES if k in act]
            if len(ak) != 1:
                rep.error(where, "action needs exactly one of %s" % ACTION_TYPES)
            elif ak[0] == "respondImmediately":
                rs = act["respondImmediately"].get("responses") or []
                if not rs or not all(r.get("text") for r in rs):
                    rep.error(where, "respondImmediately.responses needs at least one {text}")
            elif ak[0] == "transferAgent":
                if act["transferAgent"].get("agent") not in agents:
                    rep.error(where, "transferAgent.agent '%s' is not an agent displayName" % act["transferAgent"].get("agent"))
        cf = g.get("contentFilter")
        if cf:
            if cf.get("matchType") not in MATCH_TYPES:
                rep.error(where, "contentFilter.matchType must be one of %s" % sorted(MATCH_TYPES))
            if cf.get("matchType") != "SENSITIVE_WORDS" and not (cf.get("bannedContents") or cf.get("bannedContentsInUserInput") or cf.get("bannedContentsInAgentResponse")):
                rep.error(where, "contentFilter has no banned phrases")
        lp = g.get("llmPolicy")
        if lp:
            if not lp.get("prompt"):
                rep.error(where, "llmPolicy.prompt is required")
            if lp.get("policyScope") not in POLICY_SCOPES:
                rep.error(where, "llmPolicy.policyScope must be one of %s" % sorted(POLICY_SCOPES))
            if lp.get("policyScope") in ("AGENT_RESPONSE", "USER_QUERY_AND_AGENT_RESPONSE"):
                rep.info(where, "scope includes AGENT_RESPONSE: adds latency before every reply")
        ms = g.get("modelSafety")
        if ms:
            for s in ms.get("safetySettings", []):
                if s.get("category") not in HARM_CATEGORIES:
                    rep.error(where, "unknown harm category %s" % s.get("category"))
                if s.get("threshold") not in HARM_THRESHOLDS:
                    rep.error(where, "unknown threshold %s" % s.get("threshold"))
        sv = g.get("supervisor")
        if sv:
            if sv.get("type") not in SUPERVISOR_TYPES:
                rep.error(where, "supervisor.type must be one of %s" % sorted(SUPERVISOR_TYPES))
            if sv.get("detectionMode") not in DETECTION_MODES | {None}:
                rep.error(where, "supervisor.detectionMode must be one of %s" % sorted(DETECTION_MODES))
        cc = g.get("codeCallback")
        if cc:
            for k, v in cc.items():
                fname = CALLBACK_FUNCS.get(k + "s")
                if v.get("pythonCode"):
                    check_python(root, v["pythonCode"], where, rep, fname or "callback", False)
    # ---------- agents ----------
    parent_of = {}
    toolset_ops_for_agent = {}
    ctx = {"agents": agents, "variables": variables, "written_vars": written, "toolset_ops_for_agent": toolset_ops_for_agent}
    for name, ag in agents.items():
        ops = set()
        for ref in ag.get("toolsets", []):
            ts_name = ref.get("toolset")
            if ts_name not in toolsets:
                rep.error("agents/%s" % ag["_dir"], "toolset '%s' not found under toolsets/" % ts_name)
                continue
            for tid in ref.get("toolIds", []) or []:
                if tid not in toolset_ops.get(ts_name, set()):
                    rep.error("agents/%s" % ag["_dir"], "toolId '%s' is not an operationId of toolset '%s'" % (tid, ts_name))
            ops |= set(ref.get("toolIds") or toolset_ops.get(ts_name, set()))
        toolset_ops_for_agent[name] = ops
    for name, ag in agents.items():
        where = "agents/%s" % ag["_dir"]
        for t in ag.get("tools", []):
            if t not in tools and t not in SYSTEM_TOOLS:
                rep.error(where, "tool '%s' not found under tools/ (system tools: %s)" % (t, ", ".join(sorted(SYSTEM_TOOLS))))
        for g in ag.get("guardrails", []):
            if g not in guardrails:
                rep.error(where, "guardrail '%s' not found" % g)
        for c in ag.get("childAgents", []):
            if c not in agents:
                rep.error(where, "child agent '%s' not found" % c)
            elif c in parent_of and parent_of[c] != name:
                rep.warn(where, "agent '%s' has more than one parent (%s, %s)" % (c, parent_of[c], name))
            parent_of[c] = name
            if c == root_agent:
                rep.error(where, "the root agent cannot be a child agent")
        if len(ag.get("tools", [])) + len(toolset_ops_for_agent[name]) > 10:
            rep.warn(where, "more than 10 tools on one agent; fewer, distinct tools improve tool selection")
        ins = ag.get("instruction")
        if ins:
            if not os.path.isfile(os.path.join(root, ins)):
                rep.error(where, "instruction file missing: %s" % ins)
            else:
                check_instruction(read_text(root, ins), ins, name, ag, ctx, rep)
        else:
            rep.warn(where, "agent has no instruction")
        for key, fname in CALLBACK_FUNCS.items():
            for cb in ag.get(key, []) or []:
                if not cb.get("pythonCode"):
                    rep.error(where, "%s entry has no pythonCode" % key)
                else:
                    check_python(root, cb["pythonCode"], where + "/" + key, rep, fname, False)
                    check_callback_tools(read_text(root, cb["pythonCode"]), where + "/" + key, ag, tools, toolset_ops_for_agent.get(name, set()), app, rep, set().union(*toolset_ops.values()) if toolset_ops else set())
    # cycles
    for start in agents:
        seen, cur = set(), start
        while cur in parent_of:
            if cur in seen:
                rep.error("agents", "agent tree has a cycle through '%s'" % cur)
                break
            seen.add(cur)
            cur = parent_of[cur]
    if gi and os.path.isfile(os.path.join(root, gi)):
        txt = read_text(root, gi)
        check_instruction(txt, gi, root_agent or "", agents.get(root_agent, {}), ctx, rep, is_global=True)

    # ---------- usage warnings ----------
    applied_g = set(app.get("guardrails", []))
    for ag in agents.values():
        applied_g |= set(ag.get("guardrails", []))
    for gname, g in guardrails.items():
        if gname not in applied_g:
            rep.warn("guardrails/%s" % g["_dir"], "guardrail '%s' is not listed in app.json guardrails or on any agent, so it is not applied" % gname)
    used_tools = set()
    for ag in agents.values():
        used_tools |= set(ag.get("tools", []))
    for t in tools:
        if t not in used_tools:
            rep.warn("tools/%s" % tools[t]["_dir"], "tool is not attached to any agent")
    all_instr = ""
    for ag in agents.values():
        if ag.get("instruction") and os.path.isfile(os.path.join(root, ag["instruction"])):
            all_instr += read_text(root, ag["instruction"])
    if gi and os.path.isfile(os.path.join(root, gi)):
        all_instr += read_text(root, gi)
    tool_vars = set()
    for ts in toolsets.values():
        bt = (((ts.get("openApiToolset") or {}).get("apiAuthentication") or {}).get("bearerTokenConfig") or {}).get("token", "")
        if bt.startswith("$context.variables."):
            tool_vars.add(bt.split(".")[-1])
    for v in variables:
        if v not in all_instr and v not in written and v not in tool_vars and not any(v in read_py(root, t) for t in tools.values()):
            rep.info("app.json", "variable '%s' is not used by any instruction or tool" % v)

    # a Python tool that calls a connector operation by name (<toolset>_<operationId>) needs that operation in the schema file
    for t_name, t in tools.items():
        code = read_py(root, t)
        for ts_name, ops_in_schema in toolset_ops.items():
            for ref in sorted(set(re.findall(r"['\"](%s_[A-Za-z0-9_]+)['\"]" % re.escape(ts_name), code))):
                if ref[len(ts_name) + 1:] not in ops_in_schema:
                    rep.error("tools/%s" % t["_dir"], "the tool calls connector operation '%s', but toolset '%s' has no operation '%s' (it has: %s)"
                              % (ref, ts_name, ref[len(ts_name) + 1:], ", ".join(sorted(ops_in_schema)) or "none"))

    scan_secrets(root, rep)
    return finish(rep, a, dict(app=app, agents=agents, tools=tools, toolsets=toolsets, guardrails=guardrails, variables=variables, root=root))


def check_callback_tools(src, where, agent, tools, ops, app, rep, every_op=frozenset()):
    """A callback that injects a tool call must name a tool the agent has; one that hides tools must name real tools."""
    inserted = re.findall(r"from_function_call\(\s*name\s*=\s*([A-Za-z_][A-Za-z0-9_]*|'[^']*'|\"[^\"]*\")", src)
    consts = dict(re.findall(r"^\s*([A-Z_]+)\s*=\s*['\"]([^'\"]+)['\"]", src, re.M))
    available = set(agent.get("tools", [])) | set(ops) | SYSTEM_TOOLS
    for ref in inserted:
        name = consts.get(ref) if re.match(r"^[A-Za-z_]", ref) else ref.strip("'\"")
        if name and name not in available:
            rep.error(where, "the callback calls tool '%s', which is not on this agent (add it to the agent's tools)" % name)
        if name and name not in SYSTEM_TOOLS and app.get("toolExecutionMode") != "SEQUENTIAL":
            rep.warn(where, "the callback runs tool '%s' next to other calls; with toolExecutionMode PARALLEL end_session can finish the call first. Set the app to SEQUENTIAL" % name)
    direct = re.findall(r"getattr\(\s*tools\s*,\s*([A-Za-z_][A-Za-z0-9_]*|'[^']*'|\"[^\"]*\")\s*\)", src) + re.findall(r"\btools\.([A-Za-z_][A-Za-z0-9_]*)\(", src)
    for ref in direct:
        name = consts.get(ref) if re.match(r"^[A-Z_]+$", ref) else ref.strip("'\"")
        if name and name not in tools and not any(name.endswith("_" + op) for op in every_op):
            rep.error(where, "the callback calls tool '%s', which does not exist in this package" % name)
    m = re.search(r"for\s+tool_name\s+in\s+(\[[^\]]*\])\s*:", src)
    if m and "hide_tool" in src:
        try:
            hidden = ast.literal_eval(m.group(1))
        except (ValueError, SyntaxError):
            hidden = []
        for name in hidden:
            if name not in tools and name not in ops and name not in every_op:
                rep.error(where, "hide_tools names '%s', which is not a tool or toolset operation in this package" % name)


def read_py(root, t):
    pf = t.get("pythonFunction")
    if not pf:
        return ""
    try:
        return read_text(root, pf.get("pythonCode", ""))
    except OSError:
        return ""


def finish(rep, a, data):
    if a.json:
        print(json.dumps({"errors": rep.count("ERROR"), "warnings": rep.count("WARN"), "items": rep.items}, indent=2))
        return 1 if rep.count("ERROR") else 0
    if a.inspect and data:
        app = data["app"]
        print("App: %s | root agent: %s | model: %s | variables: %d" % (app.get("displayName"), app.get("rootAgent"), (app.get("modelSettings") or {}).get("model"), len(data["variables"])))
        for n, ag in data["agents"].items():
            print("  agent %-24s tools=%s children=%s" % (n, ag.get("tools", []), ag.get("childAgents", [])))
        for n, t in data["tools"].items():
            kind = [k for k in t if k.endswith(("Function", "Tool"))]
            print("  tool  %-24s %s" % (n, kind))
        for n, t in data["toolsets"].items():
            print("  toolset %-22s %s" % (n, list(t.keys())))
        for n, g in data["guardrails"].items():
            print("  guardrail %-20s %s" % (n, [k for k in GUARDRAIL_TYPES if k in g]))
        print()
    order = {"ERROR": 0, "WARN": 1, "INFO": 2}
    for it in sorted(rep.items, key=lambda i: order[i["level"]]):
        if a.quiet and it["level"] == "INFO":
            continue
        print("%-5s %-40s %s" % (it["level"], it["where"], it["msg"]))
    print("\n%d error(s), %d warning(s)" % (rep.count("ERROR"), rep.count("WARN")))
    return 1 if rep.count("ERROR") else 0


if __name__ == "__main__":
    sys.exit(main())
