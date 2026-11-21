#!/usr/bin/env python3
"""Build an importable Google CX Agent Studio (CES) agent package from a spec.json.

  build_agent.py SPEC.json [--out DIR] [--no-zip] [--force] [--selftest]

Writes  <out>/<AppFolder>/...           the package (same layout as a console export, JSON files)
        <out>/<AppFolder>.zip            the file to import (made only when validation has no errors)
        <out>/_selftest/scenarios.json   offline test scenarios for the generated Python tools (not in the zip)

See references/spec-reference.md for the spec format and references/export-format.md for the package layout.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from ces_lib import callbacks as cb_lib  # noqa: E402
from ces_lib import guardrails as gr_lib  # noqa: E402
from ces_lib import openapi_sf  # noqa: E402
from ces_lib import tools as tool_lib  # noqa: E402
from ces_lib.common import SpecError, folder_name, need, stable_uuid, to_yaml, write_json, write_text  # noqa: E402

SYSTEM_TOOLS = {"end_session", "transfer_to_agent", "customize_response"}
CALLBACK_KEYS = {"beforeAgent": "beforeAgentCallbacks", "afterAgent": "afterAgentCallbacks", "beforeModel": "beforeModelCallbacks",
                 "afterModel": "afterModelCallbacks", "beforeTool": "beforeToolCallbacks", "afterTool": "afterToolCallbacks"}
CALLBACK_FUNC = {"beforeAgentCallbacks": "before_agent_callback", "afterAgentCallbacks": "after_agent_callback",
                 "beforeModelCallbacks": "before_model_callback", "afterModelCallbacks": "after_model_callback",
                 "beforeToolCallbacks": "before_tool_callback", "afterToolCallbacks": "after_tool_callback"}
CALLBACK_DIRS = {"beforeAgentCallbacks": "before_agent_callbacks", "afterAgentCallbacks": "after_agent_callbacks",
                 "beforeModelCallbacks": "before_model_callbacks", "afterModelCallbacks": "after_model_callbacks",
                 "beforeToolCallbacks": "before_tool_callbacks", "afterToolCallbacks": "after_tool_callbacks"}
VAR_TYPES = {"STRING", "NUMBER", "INTEGER", "BOOLEAN", "OBJECT", "ARRAY"}


def read_file(base, rel, where):
    path = rel if os.path.isabs(rel) else os.path.join(base, rel)
    if not os.path.isfile(path):
        raise SpecError("%s: file not found: %s" % (where, path))
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def build_variables(spec_vars, extra):
    """Merge user variables with variables the templates need. Returns the declaration list."""
    merged, order = {}, []
    for v in list(spec_vars) + list(extra):
        name = need(v, "name", "variable")
        if name in merged:
            if v.get("_auto"):
                continue
            raise SpecError("variable '%s' is declared twice" % name)
        merged[name] = v
        order.append(name)
    out = []
    for name in order:
        v = merged[name]
        t = v.get("type", "STRING").upper()
        if t not in VAR_TYPES:
            raise SpecError("variable %s: type must be one of %s" % (name, sorted(VAR_TYPES)))
        schema = dict(v["schema"]) if v.get("schema") else {"type": t}
        if "default" in v and "default" not in schema:
            schema["default"] = v["default"]
        out.append({"name": name, "description": v.get("description", ""), "schema": schema})
    return out


def build_app_json(app, sf, variables, guardrail_names, root_name, global_file, uid):
    channel = app.get("channel", "voice")
    j = {"name": uid("app"), "displayName": app["displayName"]}
    if app.get("description"):
        j["description"] = app["description"]
    j["rootAgent"] = root_name
    lang = app.get("defaultLanguage", "en-US")
    if channel in ("voice", "both"):
        voice = app.get("voice", {})
        apc = {"synthesizeSpeechConfigs": {lang: {"voice": voice.get("name", "en-US-Chirp3-HD-Aoede"), "speakingRate": voice.get("speakingRate", 1.0)}},
               "bargeInConfig": {"bargeInAwareness": bool(app.get("bargeInAwareness", True))},
               "inactivityTimeout": app.get("inactivityTimeout", "10s")}
        if voice.get("ambientSound"):
            amb = {"prebuiltAmbientSound": voice["ambientSound"]}
            if voice.get("ambientVolumeDb") is not None:
                amb["volumeGainDb"] = voice["ambientVolumeDb"]
            apc["ambientSoundConfig"] = amb
        j["audioProcessingConfig"] = apc
    lg = app.get("logging", {})
    # the console writes every sub-setting, the unused ones as empty objects (verified against a real export)
    ls = {}
    if lg.get("redaction"):
        ls["redactionConfig"] = {"enableRedaction": True}
    ls["audioRecordingConfig"] = {}
    ls["bigqueryExportSettings"] = {}
    ls["cloudLoggingSettings"] = {"enableCloudLogging": True} if lg.get("cloudLogging") else {}
    ls["conversationLoggingSettings"] = {"retentionWindow": "%ds" % (int(lg.get("retentionDays", 365)) * 86400)}
    ls["metricAnalysisSettings"] = {}
    ls["unredactedBigqueryExportSettings"] = {}
    j["loggingSettings"] = ls
    j["guardrails"] = guardrail_names
    model = app.get("model", "gemini-composite-v2" if channel in ("voice", "both") else "gemini-3.5-flash")
    ms = {"model": model}
    if not model.startswith("gemini-composite"):          # the console writes no thinkingLevel for the voice composite models
        ms["thinkingLevel"] = app.get("thinkingLevel", "MEDIUM")
    if app.get("temperature") is not None:
        ms["temperature"] = app["temperature"]
    j["modelSettings"] = ms
    j["variableDeclarations"] = variables
    if app.get("multilingual") or app.get("supportedLanguages"):
        j["languageSettings"] = {"defaultLanguageCode": lang, "supportedLanguageCodes": app.get("supportedLanguages", []),
                                 "enableMultilingualSupport": bool(app.get("multilingual", True))}
    j["defaultChannelProfile"] = {"personaProperty": {"persona": app.get("persona", "CONCISE")},
                                  "disableDtmf": bool(app.get("disableDtmf", channel == "chat")),
                                  "disableBargeInControl": bool(app.get("disableBargeIn", False))}
    j["timeZoneSettings"] = {"timeZone": app.get("timeZone", "America/Los_Angeles")}
    eh = app.get("errorHandling", {})
    fr = {"maxFallbackAttempts": int(eh.get("maxFallbackAttempts", 1))}
    if eh.get("customFallbackMessage"):
        fr["customFallbackMessages"] = {lang: eh["customFallbackMessage"]}
    j["errorHandlingSettings"] = {"errorHandlingStrategy": eh.get("strategy", "FALLBACK_RESPONSE"), "fallbackResponseConfig": fr,
                                  "endSessionConfig": {"escalateSession": bool(eh.get("escalateOnEnd", True))}}
    if app.get("toolExecutionMode"):
        j["toolExecutionMode"] = app["toolExecutionMode"]
    if global_file:
        j["globalInstruction"] = global_file
    return j


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("spec")
    ap.add_argument("--out", default=None, help="output directory (default: <spec dir>/out)")
    ap.add_argument("--no-zip", action="store_true")
    ap.add_argument("--force", action="store_true", help="zip even when validation reports errors")
    ap.add_argument("--selftest", action="store_true", help="run selftest_tools.py after building")
    a = ap.parse_args()

    spec_path = os.path.abspath(a.spec)
    base = os.path.dirname(spec_path)
    with open(spec_path, encoding="utf-8") as fh:
        spec = json.load(fh)
    out_dir = os.path.abspath(a.out or os.path.join(base, "out"))
    try:
        build(spec, base, out_dir, a)
    except SpecError as e:
        print("SPEC ERROR: %s" % e, file=sys.stderr)
        return 2
    return 0


def build(spec, base, out_dir, a):
    app = need(spec, "app", "spec")
    sf = need(spec, "salesforce", "spec")
    need(app, "displayName", "app")
    need(sf, "instanceUrl", "salesforce")
    auth = sf.setdefault("auth", {"mode": "bearer_variable"})
    mode = auth.get("mode", "bearer_variable")
    token_var = auth.get("tokenVariable", "salesforce_access_token")
    auth["tokenVariable"] = token_var
    if mode not in ("bearer_variable", "oauth_client_credentials"):
        raise SpecError("salesforce.auth.mode must be bearer_variable or oauth_client_credentials")
    transport = sf.get("transport", "rest")
    if transport not in ("rest", "connector"):
        raise SpecError("salesforce.transport must be 'rest' (Python calls Salesforce itself) or 'connector' (Python calls the Salesforce connector tool)")

    app_folder = folder_name(app["displayName"])
    root = os.path.join(out_dir, app_folder)
    if os.path.isdir(root):
        if not os.path.isfile(os.path.join(root, "app.json")):
            raise SpecError("%s exists and is not a previous build; choose another --out" % root)
        shutil.rmtree(root)
    os.makedirs(root)

    def uid(*parts):
        return stable_uuid(app["displayName"], *parts)

    extra_vars = []
    scenarios = []
    tool_names, tool_meta = set(), {}

    # ---------------- tools ----------------
    python_templates_used = False
    for t in spec.get("tools", []):
        name = need(t, "name", "tool")
        where = "tool '%s'" % name
        if name in tool_names:
            raise SpecError("%s: duplicate tool name" % where)
        if name in SYSTEM_TOOLS:
            raise SpecError("%s: reserved system tool name" % where)
        tool_names.add(name)
        if t.get("template"):
            python_templates_used = True
            r = tool_lib.render_tool(name, t["template"], t.get("params", {}), sf, where)
            if t.get("description"):
                r["description"] = t["description"]
            src, desc = r["source"], r["description"]
            for v in r["variables"]:
                v["_auto"] = True
                extra_vars.append(v)
            scenarios.extend(r["scenarios"])
            tool_meta[name] = r
            if t.get("params", {}).get("scope_field"):
                tool_meta[name]["scope"] = True
        elif t.get("file"):
            src = read_file(base, t["file"], where)
            import ast
            try:
                tree = ast.parse(src)
            except SyntaxError as e:
                raise SpecError("%s: python syntax error line %s: %s" % (where, e.lineno, e.msg))
            fns = {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}
            if name not in fns:
                raise SpecError("%s: the file must define a function named '%s'" % (where, name))
            desc = t.get("description") or ast.get_docstring(fns[name]) or ""
            tool_meta[name] = {"needs_verify": False, "writes_gate": False}
        else:
            raise SpecError("%s: needs 'template' (with params) or 'file'" % where)
        d = "tools/%s" % name
        write_text(os.path.join(root, d, "python_function", "python_code.py"), src)
        write_json(os.path.join(root, d, name + ".json"), {
            "name": uid("tool", name),
            "pythonFunction": {"name": name, "pythonCode": d + "/python_function/python_code.py", "description": desc},
            "executionType": t.get("executionType", "SYNCHRONOUS"), "displayName": name})

    if python_templates_used and mode != "bearer_variable" and transport != "connector":
        raise SpecError("Python template tools call Salesforce with the access token variable, so auth.mode must be bearer_variable. "
                        "For OAuth, expose operations through a salesforce_openapi toolset instead (see references/tools-guide.md).")
    if any(m.get("needs_verify") for m in tool_meta.values()) and not any(m.get("writes_gate") for m in tool_meta.values()):
        raise SpecError("a tool requires a verified caller but no verify_caller tool exists. Add one, or set require_verified: false on those tools")
    if any(m.get("scope") for m in tool_meta.values()):
        verify_has_scope = any(m.get("writes_gate") and "verified_scope_id" in [v["name"] for v in m["variables"]] for m in tool_meta.values())
        if not verify_has_scope:
            raise SpecError("a tool uses scope_field but verify_caller has no scope_field, so verified_scope_id would never be set")
    if transport == "connector" and spec.get("toolsets"):
        expected = {"%s_%s" % (ts["name"], op["operationId"]) for ts in spec["toolsets"] for op in ts.get("operations", [])}
        if sf.get("connectorTool") not in expected:
            raise SpecError("salesforce.connectorTool '%s' is not <toolset name>_<operationId> of any toolset operation (expected one of: %s)" % (sf.get("connectorTool"), ", ".join(sorted(expected))))
    if spec.get("toolsets"):
        expected_ops = {"%s_%s" % (ts["name"], op["operationId"]) for ts in spec["toolsets"] for op in ts.get("operations", [])}
        for t in spec.get("tools", []):
            for key in ("connector_tool", "write_connector_tool"):
                ct = (t.get("params") or {}).get(key)
                if t.get("template") and ct and ct not in expected_ops:
                    raise SpecError("tool '%s': params.%s '%s' is not <toolset name>_<operationId> of any toolset operation (expected one of: %s)" % (t["name"], key, ct, ", ".join(sorted(expected_ops))))
    if any(t.get("template") for t in spec.get("tools", [])) and transport != "connector":
        extra_vars.append({"name": token_var, "type": "STRING", "default": "",
                           "description": "Salesforce access token. Set this after import (never stored in the package).", "_auto": True})

    # ---------------- toolsets ----------------
    # Mirrors a real console export: the schema is YAML with servers[0].url = $env_var, the secret version and token endpoint are
    # $env_var, and environment.json holds the real values. (Salesforce rejects a scope in the client credentials request, so none is sent.)
    toolset_ops = {}
    environment = {}
    for ts in spec.get("toolsets", []):
        name = need(ts, "name", "toolset")
        where = "toolset '%s'" % name
        if ts.get("type", "salesforce_openapi") != "salesforce_openapi":
            raise SpecError("%s: only type salesforce_openapi is generated" % where)
        schema = openapi_sf.build_schema(sf["instanceUrl"], sf.get("apiVersion", "v60.0"), ts.get("title", name), need(ts, "operations", where),
                                         relative=bool(ts.get("server_includes_version", False)))
        server_url = schema["servers"][0]["url"]
        schema["servers"][0]["url"] = "$env_var"
        toolset_ops[name] = [op["operationId"] for op in ts["operations"]]
        d = "toolsets/%s" % name
        write_text(os.path.join(root, d, "open_api_toolset", "open_api_schema.yaml"), to_yaml(schema))
        env_entry = {"openApiToolset": {"url": server_url}}
        if mode == "bearer_variable":
            api_auth = {"bearerTokenConfig": {"token": "$context.variables.%s" % token_var}}
            if not any(v["name"] == token_var for v in extra_vars):
                extra_vars.append({"name": token_var, "type": "STRING", "default": "",
                                   "description": "Salesforce access token. Set this after import (never stored in the package).", "_auto": True})
        else:
            need(auth, "clientId", "salesforce.auth")
            need(auth, "clientSecretVersion", "salesforce.auth")
            oauth = {"oauthGrantType": "CLIENT_CREDENTIAL", "clientId": auth["clientId"],
                     "clientSecretVersion": "$env_var", "tokenEndpoint": "$env_var"}
            if auth.get("scopes"):
                oauth["scopes"] = auth["scopes"]      # Salesforce answers 'scope parameter not supported'; leave empty for Salesforce
            api_auth = {"oauthConfig": oauth}
            env_entry["openApiToolset"]["apiAuthentication"] = {"oauthConfig": {
                "clientSecretVersion": auth["clientSecretVersion"], "tokenEndpoint": sf["instanceUrl"].rstrip("/") + "/services/oauth2/token"}}
        environment.setdefault("toolsets", {})[name] = env_entry
        tj = {"name": uid("toolset", name), "displayName": name,
              "openApiToolset": {"openApiSchema": d + "/open_api_toolset/open_api_schema.yaml", "apiAuthentication": api_auth}}
        if ts.get("description"):
            tj["description"] = ts["description"]
        if ts.get("executionType", "SYNCHRONOUS") != "SYNCHRONOUS":
            tj["executionType"] = ts["executionType"]
        write_json(os.path.join(root, d, name + ".json"), tj)
    if environment:
        write_json(os.path.join(root, "environment.json"), environment)

    # ---------------- guardrails ----------------
    gspecs = spec.get("guardrails") or [{"type": "default_safety"}, {"type": "default_prompt_security"}]
    app_guardrails, agent_guardrails = [], {}
    seen_g = set()
    for g in gspecs:
        gname, gj, extra = gr_lib.build_guardrail(g)
        if gname in seen_g:
            raise SpecError("duplicate guardrail '%s'" % gname)
        seen_g.add(gname)
        gf = folder_name(gname)
        if "codeCallback" in gj:
            for ph in gj["codeCallback"].values():
                ph["pythonCode"] = ph["pythonCode"].replace("__DIR__", gf)
        out = {"name": uid("guardrail", gname)}
        out.update(gj)
        write_json(os.path.join(root, "guardrails", gf, gf + ".json"), out)
        for rel, text in extra.items():
            write_text(os.path.join(root, "guardrails", gf, rel), text)
        if g.get("scope", "app") not in ("app", "agent"):
            raise SpecError("guardrail '%s': scope must be 'app' or 'agent' (for llm_policy use policy_scope)" % gname)
        if g.get("scope", "app") == "app":
            app_guardrails.append(gname)
        else:
            for ag in g.get("agents", []):
                agent_guardrails.setdefault(ag, []).append(gname)

    # ---------------- agents ----------------
    agents = need(spec, "agents", "spec")
    root_name = app.get("rootAgent") or agents[0]["displayName"]
    known_agents = {x["displayName"] for x in agents}
    if root_name not in known_agents:
        raise SpecError("rootAgent '%s' is not among the agents" % root_name)
    for ag in agents:
        name = need(ag, "displayName", "agent")
        where = "agent '%s'" % name
        af = folder_name(name)
        ad = "agents/%s" % af
        j = {"name": uid("agent", name), "displayName": name}
        if ag.get("description"):
            j["description"] = ag["description"]
        if ag.get("instructionFile"):
            text = read_file(base, ag["instructionFile"], where)
        elif ag.get("instruction"):
            text = ag["instruction"]
        else:
            raise SpecError("%s: needs instructionFile or instruction" % where)
        write_text(os.path.join(root, ad, "instruction.txt"), text)
        j["instruction"] = ad + "/instruction.txt"
        tools = list(ag.get("tools", []))
        for t in tools:
            if t not in tool_names and t not in SYSTEM_TOOLS:
                raise SpecError("%s: tool '%s' is not defined (system tools: %s)" % (where, t, ", ".join(sorted(SYSTEM_TOOLS))))
        j["tools"] = tools
        if ag.get("toolsets"):
            for ref in ag["toolsets"]:
                if ref["toolset"] not in toolset_ops:
                    raise SpecError("%s: toolset '%s' is not defined" % (where, ref["toolset"]))
                for tid in ref.get("toolIds", []):
                    if tid not in toolset_ops[ref["toolset"]]:
                        raise SpecError("%s: toolId '%s' is not an operation of toolset '%s'" % (where, tid, ref["toolset"]))
            j["toolsets"] = ag["toolsets"]
        if ag.get("childAgents"):
            j["childAgents"] = ag["childAgents"]
        for short, key in CALLBACK_KEYS.items():
            entries = (ag.get("callbacks") or {}).get(short, [])
            if not entries:
                continue
            lst = []
            for i, c in enumerate(entries, 1):
                label = c.get("template") or os.path.splitext(os.path.basename(c.get("file", "callback")))[0]
                if c.get("template"):
                    fn, src, cvars = cb_lib.render_callback(c, where + " callback " + label)
                    if fn != CALLBACK_FUNC[key]:
                        raise SpecError("%s: callback template %s is a %s, not a %s" % (where, label, fn, CALLBACK_FUNC[key]))
                    for v in cvars:
                        v["_auto"] = True
                        extra_vars.append(v)
                else:
                    src = read_file(base, c["file"], where)
                folder = CALLBACK_DIRS[key]
                # real export layout: agents/<A>/after_model_callbacks/after_model_callbacks_01/python_code.py, entry {"pythonCode": ...} only
                rel = "%s/%s/%s_%02d/python_code.py" % (ad, folder, folder, i)
                write_text(os.path.join(root, rel), src)
                entry = {"pythonCode": rel}
                if c.get("disabled"):
                    entry["disabled"] = True
                if c.get("description"):
                    entry["description"] = c["description"]
                lst.append(entry)
            j[key] = lst
        gl = list(ag.get("guardrails", [])) + agent_guardrails.get(name, [])
        if gl:
            j["guardrails"] = gl
        if ag.get("modelSettings"):
            j["modelSettings"] = ag["modelSettings"]
        write_json(os.path.join(root, ad, af + ".json"), j)

    # the end-of-call transcript hook puts save_transcript in front of end_session in one model response: run them in order
    hook_agents = [ag["displayName"] for ag in agents for lst in (ag.get("callbacks") or {}).values() for c in lst if c.get("template") == "save_transcript_on_end"]
    if hook_agents:
        if app.get("toolExecutionMode") not in (None, "SEQUENTIAL"):
            raise SpecError("callback save_transcript_on_end needs app.toolExecutionMode SEQUENTIAL (tools run in parallel by default, so end_session could end the call before the transcript is saved)")
        app["toolExecutionMode"] = "SEQUENTIAL"
        for ag in agents:
            if ag["displayName"] in hook_agents:
                for c in [c for lst in (ag.get("callbacks") or {}).values() for c in lst if c.get("template") == "save_transcript_on_end"]:
                    tool = (c.get("params") or {}).get("tool", "save_transcript")
                    if tool not in ag.get("tools", []):
                        raise SpecError("agent '%s': save_transcript_on_end calls '%s' but the agent's tools list does not include it" % (ag["displayName"], tool))

    # the start-of-call greeting calls the caller lookup tool: it must exist and sit on that agent
    for ag in agents:
        for c in [c for lst in (ag.get("callbacks") or {}).values() for c in lst if c.get("template") == "greet_known_caller"]:
            tool = (c.get("params") or {}).get("tool", "identify_caller")
            if tool not in tool_names:
                raise SpecError("agent '%s': greet_known_caller calls tool '%s', which is not defined in tools" % (ag["displayName"], tool))
            if tool not in ag.get("tools", []):
                raise SpecError("agent '%s': greet_known_caller calls '%s' but the agent's tools list does not include it" % (ag["displayName"], tool))

    # the console always writes this (empty) file; mirror it
    write_text(os.path.join(root, "pythonEnvFiles", "pythonEnvFiles.json"), "{\n}")

    # ---------------- app.json ----------------
    global_file = None
    if app.get("globalInstructionFile"):
        write_text(os.path.join(root, "global_instruction.txt"), read_file(base, app["globalInstructionFile"], "app.globalInstructionFile"))
        global_file = "global_instruction.txt"
    variables = build_variables(spec.get("variables", []), extra_vars)
    write_json(os.path.join(root, "app.json"), build_app_json(app, sf, variables, app_guardrails, root_name, global_file, uid))

    sd = os.path.join(out_dir, "_selftest")
    os.makedirs(sd, exist_ok=True)
    query_patterns = {}
    for ts in spec.get("toolsets", []):
        for op in ts.get("operations", []):
            if op.get("kind") == "soql_query" and op.get("q_pattern"):
                query_patterns["%s_%s" % (ts["name"], op["operationId"])] = op["q_pattern"]
    with open(os.path.join(sd, "scenarios.json"), "w") as fh:
        json.dump({"package": root, "scenarios": scenarios, "query_patterns": query_patterns}, fh, indent=1)

    # ---------------- validate, zip ----------------
    vp = os.path.join(HERE, "validate_package.py")
    r = subprocess.run([sys.executable, vp, root, "--quiet"], capture_output=True, text=True)
    print(r.stdout.rstrip())
    ok = r.returncode == 0
    print("Package folder: %s" % root)
    if a.selftest:
        st = subprocess.run([sys.executable, os.path.join(HERE, "selftest_tools.py"), os.path.join(sd, "scenarios.json")], capture_output=True, text=True)
        print(st.stdout.rstrip())
        if st.returncode != 0:
            ok = False
    if not ok and not a.force:
        print("NOT zipped: fix the errors above (or use --force).")
        sys.exit(1)
    if not a.no_zip:
        zp = os.path.join(out_dir, app_folder + ".zip")
        if os.path.exists(zp):
            os.remove(zp)
        with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED) as z:
            for b, _d, files in os.walk(root):
                for f in sorted(files):
                    if f == ".DS_Store":
                        continue
                    full = os.path.join(b, f)
                    z.write(full, os.path.join(app_folder, os.path.relpath(full, root)))
        print("Import this file: %s" % zp)
    if any(v["name"] == token_var for v in variables):
        print("After import: set variable '%s' (the package ships it empty)." % token_var)


if __name__ == "__main__":
    sys.exit(main())
