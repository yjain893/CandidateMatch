"""Render Python tool source from the templates in assets/tool-templates, plus self-test scenarios.

Every generated tool is a single self-contained function (helpers are nested inside it), because the CES
sandbox calls the function whose name equals the tool name. See references/tools-guide.md.
"""
import ast
import os
import re
from json import dumps as json_dumps

from .common import SpecError, need, py_literal

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "assets", "tool-templates"))
PY_TYPES = {"string": "str", "text": "str", "phone": "str", "email": "str", "date": "str", "picklist": "str",
            "number": "float", "boolean": "bool"}
STATE_VARS = {
    "caller_verified": ("BOOLEAN", False, "True after verify_caller succeeded. Tools that need a verified caller check it."),
    "verified_record_id": ("STRING", "", "Salesforce Id of the record the caller was verified against."),
    "verified_scope_id": ("STRING", "", "Salesforce Id that scopes what the verified caller may see (for example the Account Id)."),
    "verification_attempts": ("NUMBER", 0, "Failed verification attempts so far in this session."),
    "telephony-caller-id": ("STRING", "", "The caller's phone number. The phone platform fills it on a real phone call; in Preview set a test number as its default and clear it before go-live."),
    "caller_status": ("STRING", "", "Set at the start of the call: known when the caller's number matched exactly one Salesforce Contact, otherwise unknown."),
    "caller_name": ("STRING", "", "First name of the Contact that matched the caller's number."),
    "caller_email": ("STRING", "", "Email address of that Contact, compared with what the caller says."),
    "caller_contact_id": ("STRING", "", "Salesforce Id of the matched Contact."),
    "caller_account_id": ("STRING", "", "Salesforce Id of the matched Contact's Account."),
    "last_order_id": ("STRING", "", "Salesforce Id of the order last looked up or changed (linked on the call transcript)."),
}
NO_GATE = ("verify_caller", "verify_contact_email", "identify_caller", "save_transcript")


def _read(name):
    with open(os.path.join(TEMPLATE_DIR, name), encoding="utf-8") as fh:
        return fh.read()


def _docstring(description, args, returns):
    first = description.strip().replace('"""', "'''").replace("\n", "\n  ")
    lines = ['  """' + first]
    if args:
        lines += ["", "  Args:"]
        for a in args:
            lines.append("    %s: %s" % (a["name"], a["doc"].replace("\n", " ")))
    if returns:
        lines += ["", "  Returns:", "    " + returns.replace("\n", "\n    ")]
    lines.append('  """')
    return "\n".join(lines)


def _signature(args):
    ordered = [a for a in args if a["required"]] + [a for a in args if not a["required"]]
    parts, uses_optional = [], False
    for a in ordered:
        if a["required"]:
            parts.append("%s: %s" % (a["name"], a["type"]))
        elif a["type"] == "str":
            parts.append('%s: str = ""' % a["name"])
        elif a["type"] == "bool":
            parts.append("%s: bool = False" % a["name"])
        else:
            parts.append("%s: Optional[%s] = None" % (a["name"], a["type"]))
            uses_optional = True
    return ", ".join(parts), uses_optional


def _label(param):
    return param.replace("_", " ")


def _field_args(fields):
    out = []
    for f in fields:
        t = PY_TYPES.get(f.get("type", "string"), "str")
        doc = f.get("doc") or _label(f["param"]).capitalize()
        if f.get("allowed"):
            doc += " One of: " + ", ".join(str(x) for x in f["allowed"]) + "."
        out.append({"name": f["param"], "type": t, "required": bool(f.get("required")), "doc": doc})
    return out


def _nested(path, value):
    parts = path.split(".")
    d = value
    for p in reversed(parts):
        d = {p: d}
    return d


def _merge(a, b):
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(a.get(k), dict):
            _merge(a[k], v)
        else:
            a[k] = v
    return a


def _sample_value(key):
    k = key.lower()
    if "date" in k:
        return "2026-11-28"
    if any(w in k for w in ("amount", "total", "count", "price", "years")):
        return 99.5
    return "Sample " + key


def _record(paths_values):
    rec = {}
    for path, value in paths_values.items():
        _merge(rec, _nested(path, value))
    return rec


def _ok(resp_json, status=200, when="/query"):
    return {"when": when, "status": status, "json": resp_json}


def _auth_scenarios(tool, args, variables):
    return [
        {"name": "token variable empty -> system error", "tool": tool, "args": args, "variables": dict(variables, __no_token__=True),
         "responses": [], "expect": {"system_error": True}, "expect_no_calls": True},
        {"name": "Salesforce 401 -> system error, no crash", "tool": tool, "args": args, "variables": dict(variables),
         "responses": [{"when": "/", "status": 401, "json": [{"errorCode": "INVALID_SESSION_ID"}]}], "expect": {"system_error": True, "error": "salesforce_auth_failed"}},
        {"name": "Salesforce 500 -> system error, no crash", "tool": tool, "args": args, "variables": dict(variables),
         "responses": [{"when": "/", "status": 500, "json": {}}], "expect": {"system_error": True, "error": "salesforce_error"}},
    ]


# --------------------------------------------------------------------------------------------------------------
def build_verify(name, p, where):
    ident = need(p, "identifier", where)
    factor = need(p, "factor", where)
    need(ident, "param", where + ".identifier")
    need(ident, "field", where + ".identifier")
    need(factor, "param", where + ".factor")
    need(factor, "field", where + ".factor")
    ret = need(p, "return_fields", where)
    cfg = {
        "sobject": need(p, "sobject", where),
        "identifier": {"field": ident["field"], "normalize": ident.get("normalize", "digits"), "pad": ident.get("pad", 0)},
        "factor": {"field": factor["field"], "kind": factor.get("kind", "phone")},
        "return_fields": ret,
        "scope_field": p.get("scope_field", ""),
        "max_attempts": int(p.get("max_attempts", 3)),
        "attempts_variable": "verification_attempts",
    }
    if cfg["factor"]["kind"] == "digits_last_n":
        cfg["factor"]["last_n"] = int(factor.get("last_n", 4))
    args = [
        {"name": ident["param"], "type": "str", "required": True, "doc": ident.get("doc") or "The %s the caller gave." % _label(ident["param"])},
        {"name": factor["param"], "type": "str", "required": True, "doc": factor.get("doc") or "The %s registered for the record, in any format." % _label(factor["param"])},
    ]
    args_dict = '{"identifier": %s, "factor": %s}' % (ident["param"], factor["param"])
    keys = ", ".join(ret.keys())
    description = p.get("description") or (
        "Verifies a caller by checking the %s and the %s registered in Salesforce. Call this once the caller has given both. "
        "If verified is true, the details in the result can be shared with the caller. If verified is false, do not share anything." %
        (_label(ident["param"]), _label(factor["param"])))
    returns = ("dict: verified (true or false) and a message. When verified is true it also has %s. "
               "If error is not_verified the caller may retry (see attempts_remaining). "
               "If system_error is true or error is locked_out, stop and escalate." % keys)
    written = ["caller_verified", "verified_record_id", "verification_attempts"] + (["verified_scope_id"] if cfg["scope_field"] else [])
    return dict(cfg=cfg, args=args, args_dict=args_dict, description=description, returns=returns, written=written,
                scenarios=lambda: _verify_scenarios(name, cfg, ident, factor, ret))


def _verify_scenarios(tool, cfg, ident, factor, ret):
    kind = cfg["factor"]["kind"]
    stored, spoken, wrong = {
        "phone": ("(416) 555-0142", "+1 416-555-0142", "4165559999"),
        "digits_last_n": ("123-45-6789", "6789", "1111"),
        "email": ("Jane.Doe@Example.com", "jane.doe@example.com", "other@example.com"),
        "text": ("Smith", " smith ", "Jones"),
    }.get(kind, ("Smith", " smith ", "Jones"))
    norm = cfg["identifier"]["normalize"]
    pad = int(cfg["identifier"].get("pad") or 0)
    if norm == "digits":
        stored_id, spoken_id, bad_id = ("0" * max(pad - 4, 0) + "1234"), "1234", "7777"
    elif norm == "alnum_upper":
        stored_id, spoken_id, bad_id = "AB-123", "ab-123", "ZZ-999"
    else:
        stored_id, spoken_id, bad_id = "A1B2", "A1B2", "Z9Z9"
    values = {"Id": "801000000000001AAA", cfg["identifier"]["field"]: stored_id, cfg["factor"]["field"]: stored}
    if cfg["scope_field"]:
        values[cfg["scope_field"]] = "001000000000001AAA"
    sample_ret = {}
    for key, path in ret.items():
        sample_ret[key] = _sample_value(key)
        values[path] = sample_ret[key]
    good = _record(values)
    args = {ident["param"]: spoken_id, factor["param"]: spoken}
    base_vars = {"caller_verified": False, "verification_attempts": 0}
    expect_ok = dict({"verified": True, "ok": True}, **sample_ret)
    exp_vars = {"caller_verified": True, "verified_record_id": "801000000000001AAA", "verification_attempts": 0}
    if cfg["scope_field"]:
        exp_vars["verified_scope_id"] = "001000000000001AAA"
    blank = _record(dict(values, **{cfg["factor"]["field"]: ""}))
    sc = [
        {"name": "correct details -> verified, variables set, details returned", "tool": tool, "args": args, "variables": dict(base_vars),
         "responses": [_ok({"records": [good]})], "expect": expect_ok, "expect_variables": exp_vars,
         "calls_must_not_contain": [spoken.strip()] if kind in ("phone", "email") else []},
        {"name": "wrong detail -> not verified, attempt counted, nothing leaked", "tool": tool, "args": dict(args, **{factor["param"]: wrong}),
         "variables": dict(base_vars), "responses": [_ok({"records": [good]})],
         "expect": {"verified": False, "error": "not_verified", "attempts_remaining": cfg["max_attempts"] - 1},
         "expect_absent": list(sample_ret.keys()), "expect_variables": {"caller_verified": False, "verification_attempts": 1}},
        {"name": "blank value on the record never matches", "tool": tool, "args": args, "variables": dict(base_vars),
         "responses": [_ok({"records": [blank]})], "expect": {"verified": False, "error": "not_verified"}},
        {"name": "unknown record -> same message as a wrong detail", "tool": tool, "args": dict(args, **{ident["param"]: bad_id}),
         "variables": dict(base_vars), "responses": [_ok({"records": []})],
         "expect": {"verified": False, "error": "not_verified", "message": "The details do not match our records."}},
        {"name": "locked out after max attempts -> no call", "tool": tool, "args": args,
         "variables": {"caller_verified": False, "verification_attempts": cfg["max_attempts"]}, "responses": [],
         "expect": {"verified": False, "error": "locked_out"}, "expect_no_calls": True},
        {"name": "empty input -> invalid_input, no call", "tool": tool, "args": {ident["param"]: "", factor["param"]: ""},
         "variables": dict(base_vars), "responses": [], "expect": {"verified": False, "error": "invalid_input"}, "expect_no_calls": True},
    ]
    if norm == "digits" and pad:
        sc.append({"name": "identifier padded in the query", "tool": tool, "args": args, "variables": dict(base_vars),
                   "responses": [_ok({"records": [good]})], "calls_must_contain": ["'" + stored_id + "'"]})
    if norm == "none":
        sc.append({"name": "quote in the identifier is escaped", "tool": tool, "args": dict(args, **{ident["param"]: "x' OR Id != '"}),
                   "variables": dict(base_vars), "responses": [_ok({"records": []})], "calls_must_contain": ["x\\' OR Id != \\'"]})
    sc += _auth_scenarios(tool, args, base_vars)
    return sc


# --------------------------------------------------------------------------------------------------------------
def _gating_vars(cfg, verified=True):
    v = {"caller_verified": verified}
    if cfg.get("scope_field"):
        v["verified_scope_id"] = "001000000000001AAA"
    return v


def build_lookup(name, p, where):
    lk = need(p, "lookup", where)
    need(lk, "param", where + ".lookup")
    need(lk, "field", where + ".lookup")
    ret = need(p, "return_fields", where)
    cfg = {"sobject": need(p, "sobject", where),
           "lookup": {"field": lk["field"], "normalize": lk.get("normalize", "none"), "pad": lk.get("pad", 0)},
           "return_fields": ret, "scope_field": p.get("scope_field", ""), "require_verified": bool(p.get("require_verified", True)),
           "remember_id_as": p.get("remember_id_as", "")}
    args = [{"name": lk["param"], "type": "str", "required": True, "doc": lk.get("doc") or "The %s to look up." % _label(lk["param"])}]
    description = p.get("description") or "Looks up one %s record and returns only the details the agent needs." % cfg["sobject"]
    returns = "dict: ok and %s. If error is not_found nothing matched; if system_error is true, apologize and escalate." % ", ".join(ret.keys())
    return dict(cfg=cfg, args=args, args_dict='{"lookup": %s}' % lk["param"], description=description, returns=returns,
                written=[cfg["remember_id_as"]] if cfg["remember_id_as"] else [],
                scenarios=lambda: _lookup_scenarios(name, cfg, lk, ret))


def _lookup_scenarios(tool, cfg, lk, ret):
    pad = int(cfg["lookup"].get("pad") or 0)
    norm = cfg["lookup"]["normalize"]
    spoken = "1234" if norm == "digits" else "ABC-1"
    values, sample = {"Id": "801000000000009AAA"}, {}
    for key, path in ret.items():
        sample[key] = _sample_value(key)
        values[path] = sample[key]
    rec = _record(values)
    args = {lk["param"]: spoken}
    gv = _gating_vars(cfg)
    sc = [{"name": "found -> ok with the mapped details", "tool": tool, "args": args, "variables": dict(gv),
           "responses": [_ok({"records": [rec]})], "expect": dict({"ok": True}, **sample),
           "calls_must_contain": ([cfg["scope_field"] + " = '001000000000001AAA'"] if cfg["scope_field"] else []),
           "expect_variables": ({cfg["remember_id_as"]: "801000000000009AAA"} if cfg["remember_id_as"] else {})},
          {"name": "no match -> not_found", "tool": tool, "args": args, "variables": dict(gv),
           "responses": [_ok({"records": []})], "expect": {"ok": False, "error": "not_found"}}]
    if cfg["require_verified"]:
        sc.append({"name": "caller not verified -> blocked, no call", "tool": tool, "args": args, "variables": _gating_vars(cfg, False),
                   "responses": [], "expect": {"ok": False, "error": "not_verified"}, "expect_no_calls": True})
    if cfg["scope_field"]:
        sc.append({"name": "verified but no scope id -> blocked, no call", "tool": tool, "args": args, "variables": {"caller_verified": True},
                   "responses": [], "expect": {"ok": False, "error": "not_verified"}, "expect_no_calls": True})
    if norm == "none":
        sc.append({"name": "quote in the lookup value is escaped", "tool": tool, "args": {lk["param"]: "x' OR Id != '"}, "variables": dict(gv),
                   "responses": [_ok({"records": []})], "calls_must_contain": ["x\\' OR Id != \\'"]})
    sc += _auth_scenarios(tool, args, gv)
    return sc


# --------------------------------------------------------------------------------------------------------------
def build_search(name, p, where):
    filters = need(p, "filters", where)
    ret = need(p, "return_fields", where)
    cfg = {"sobject": need(p, "sobject", where), "filters": filters, "return_fields": ret, "scope_field": p.get("scope_field", ""),
           "require_verified": bool(p.get("require_verified", True)), "require_filter": bool(p.get("require_filter", True)),
           "order_by": p.get("order_by", ""), "max_rows": int(p.get("max_rows", 5))}
    for f in filters:
        need(f, "param", where + ".filters")
        need(f, "field", where + ".filters")
        if f.get("op", "=") not in ("=", "!=", "<", ">", "<=", ">=", "LIKE"):
            raise SpecError("%s: unsupported operator %s" % (where, f.get("op")))
    fa = _field_args([dict(f, required=False) for f in filters])
    description = p.get("description") or "Searches %s records and returns at most %d, with only the details the agent needs." % (cfg["sobject"], cfg["max_rows"])
    returns = "dict: ok, count and records (each with %s). If system_error is true, apologize and escalate." % ", ".join(ret.keys())
    args_dict = "{" + ", ".join('"%s": %s' % (f["param"], f["param"]) for f in filters) + "}"
    return dict(cfg=cfg, args=fa, args_dict=args_dict, description=description, returns=returns, written=[],
                scenarios=lambda: _search_scenarios(name, cfg, filters, ret))


def _search_scenarios(tool, cfg, filters, ret):
    first = filters[0]
    kind = first.get("type", "string")
    val = {"number": 5, "date": "2026-11-28", "boolean": True}.get(kind, (first.get("allowed") or ["Open"])[0] if kind == "picklist" else "Acme")
    values, sample = {"Id": "500000000000001AAA"}, {}
    for key, path in ret.items():
        sample[key] = _sample_value(key)
        values[path] = sample[key]
    rec = _record(values)
    gv = _gating_vars(cfg)
    args = {first["param"]: val}
    sc = [{"name": "match -> ok with count and records", "tool": tool, "args": args, "variables": dict(gv),
           "responses": [_ok({"records": [rec]})], "expect": {"ok": True, "count": 1}, "calls_must_contain": ["LIMIT %d" % cfg["max_rows"]]},
          {"name": "no match -> ok with count 0", "tool": tool, "args": args, "variables": dict(gv),
           "responses": [_ok({"records": []})], "expect": {"ok": True, "count": 0}}]
    if cfg["require_filter"]:
        sc.append({"name": "no filter given -> invalid_input, no call", "tool": tool, "args": {}, "variables": dict(gv), "responses": [],
                   "expect": {"ok": False, "error": "invalid_input"}, "expect_no_calls": True})
    if cfg["require_verified"]:
        sc.append({"name": "caller not verified -> blocked, no call", "tool": tool, "args": args, "variables": _gating_vars(cfg, False),
                   "responses": [], "expect": {"ok": False, "error": "not_verified"}, "expect_no_calls": True})
    text_filters = [f for f in filters if f.get("type", "string") in ("string", "text", "email", "phone")]
    if text_filters:
        tf = text_filters[0]
        sc.append({"name": "quote in a text search value is escaped", "tool": tool, "args": {tf["param"]: "x' OR Id != '"}, "variables": dict(gv),
                   "responses": [_ok({"records": []})], "calls_must_contain": ["x\\' OR Id != \\'"]})
    picks = [f for f in filters if f.get("type") == "picklist"]
    if picks:
        sc.append({"name": "value outside the allowed list -> invalid_input, no call", "tool": tool, "args": {picks[0]["param"]: "Nope"},
                   "variables": dict(gv), "responses": [], "expect": {"ok": False, "error": "invalid_input"}, "expect_no_calls": True})
    sc += _auth_scenarios(tool, args, gv)
    return sc


# --------------------------------------------------------------------------------------------------------------
def _write_args(p, where, with_lookup=False):
    fields = need(p, "fields", where)
    for f in fields:
        need(f, "param", where + ".fields")
        need(f, "field", where + ".fields")
        if f.get("type") == "picklist" and not f.get("allowed"):
            raise SpecError("%s: field %s is a picklist and needs 'allowed'" % (where, f["param"]))
    return fields


def build_create(name, p, where):
    fields = _write_args(p, where)
    cfg = {"sobject": need(p, "sobject", where), "fields": fields, "fixed_values": p.get("fixed_values", {}),
           "scope_assignments": p.get("scope_assignments", {}), "return_fields": p.get("return_fields", {}),
           "require_verified": bool(p.get("require_verified", True)), "require_confirmation": bool(p.get("require_confirmation", True))}
    args = _field_args(fields)
    if cfg["require_confirmation"]:
        args.append({"name": "caller_confirmed", "type": "bool", "required": False,
                     "doc": "True only after the caller clearly confirmed the details read back to them."})
    description = p.get("description") or "Creates a %s record from details the caller gave. Read the details back and get a clear yes first." % cfg["sobject"]
    returns = "dict: ok, record_id and %s. If error is invalid_input or not_confirmed, fix that and try again; if system_error is true, apologize and escalate." % (", ".join(cfg["return_fields"].keys()) or "a message")
    args_dict = "{" + ", ".join('"%s": %s' % (a["name"], a["name"]) for a in args) + "}"
    return dict(cfg=cfg, args=args, args_dict=args_dict, description=description, returns=returns, written=[],
                scenarios=lambda: _create_scenarios(name, cfg, fields))


def _sample_for(f):
    t = f.get("type", "string")
    if t == "picklist":
        return f["allowed"][0]
    return {"number": 3, "date": "2026-11-28", "boolean": True}.get(t, "Sample text")


def _create_scenarios(tool, cfg, fields):
    good = {f["param"]: _sample_for(f) for f in fields}
    if cfg["require_confirmation"]:
        good["caller_confirmed"] = True
    gv = _gating_vars(cfg)
    for var in cfg["scope_assignments"].values():
        gv[var] = {"verified_scope_id": "001000000000001AAA", "verified_record_id": "801000000000001AAA"}.get(var, "x")
    ret = cfg["return_fields"]
    detail, sample = {}, {}
    for key, path in ret.items():
        sample[key] = _sample_value(key)
        detail[path] = sample[key]
    post = {"when": "POST ", "status": 201, "json": {"id": "500000000000099AAA", "success": True}}
    get = {"when": "GET ", "status": 200, "json": _record(detail) if detail else {}}
    sc = [{"name": "valid details + confirmation -> created", "tool": tool, "args": good, "variables": dict(gv), "responses": [post, get],
           "expect": dict({"ok": True, "record_id": "500000000000099AAA"}, **sample), "calls_must_contain": ["POST "]}]
    if cfg["require_confirmation"]:
        sc.append({"name": "no caller confirmation -> not_confirmed, no call", "tool": tool, "args": dict(good, caller_confirmed=False),
                   "variables": dict(gv), "responses": [], "expect": {"ok": False, "error": "not_confirmed"}, "expect_no_calls": True})
    if cfg["require_verified"]:
        sc.append({"name": "caller not verified -> blocked, no call", "tool": tool, "args": good, "variables": _gating_vars(cfg, False),
                   "responses": [], "expect": {"ok": False, "error": "not_verified"}, "expect_no_calls": True})
    req = [f for f in fields if f.get("required")]
    if req:
        sc.append({"name": "missing required field -> invalid_input, no call", "tool": tool, "args": dict(good, **{req[0]["param"]: ""}),
                   "variables": dict(gv), "responses": [], "expect": {"ok": False, "error": "invalid_input"}, "expect_no_calls": True})
    pick = [f for f in fields if f.get("type") == "picklist"]
    if pick:
        sc.append({"name": "value outside the allowed list -> invalid_input, no call", "tool": tool, "args": dict(good, **{pick[0]["param"]: "Nope"}),
                   "variables": dict(gv), "responses": [], "expect": {"ok": False, "error": "invalid_input"}, "expect_no_calls": True})
    sc += _auth_scenarios(tool, good, gv)
    return sc


def build_update(name, p, where):
    lk = need(p, "lookup", where)
    need(lk, "param", where + ".lookup")
    need(lk, "field", where + ".lookup")
    fields = _write_args(p, where)
    cfg = {"sobject": need(p, "sobject", where), "lookup": {"field": lk["field"], "normalize": lk.get("normalize", "none"), "pad": lk.get("pad", 0)},
           "fields": fields, "scope_field": p.get("scope_field", ""),
           "require_verified": bool(p.get("require_verified", True)), "require_confirmation": bool(p.get("require_confirmation", True)),
           "write_connector_tool": p.get("write_connector_tool", ""), "remember_id_as": p.get("remember_id_as", "")}
    args = [{"name": lk["param"], "type": "str", "required": True, "doc": lk.get("doc") or "The %s of the record to change." % _label(lk["param"])}]
    args += _field_args([dict(f, required=False) for f in fields])
    if cfg["require_confirmation"]:
        args.append({"name": "caller_confirmed", "type": "bool", "required": False,
                     "doc": "True only after the caller clearly confirmed the change read back to them."})
    description = p.get("description") or "Changes details on one %s record that belongs to the verified caller. Read the change back and get a clear yes first." % cfg["sobject"]
    returns = "dict: ok and updated_fields. If error is not_found, not_confirmed or invalid_input fix that; if system_error is true, apologize and escalate."
    args_dict = "{" + ", ".join('"%s": %s' % (("lookup" if a["name"] == lk["param"] else a["name"]), a["name"]) for a in args) + "}"
    return dict(cfg=cfg, args=args, args_dict=args_dict, description=description, returns=returns,
                written=[cfg["remember_id_as"]] if cfg["remember_id_as"] else [],
                scenarios=lambda: _update_scenarios(name, cfg, lk, fields))


def _update_scenarios(tool, cfg, lk, fields):
    wct = cfg.get("write_connector_tool", "")
    good = {lk["param"]: "1234" if cfg["lookup"]["normalize"] == "digits" else "ABC-1"}
    good.update({f["param"]: _sample_for(f) for f in fields[:1]})
    confirm = {"caller_confirmed": True} if cfg["require_confirmation"] else {}
    good.update(confirm)
    gv = _gating_vars(cfg)
    find = {"when": "GET ", "status": 200, "json": {"records": [{"Id": "801000000000009AAA"}]}}
    patch = {"when": ("connector://" + wct) if wct else "PATCH ", "status": 204, "json": {}}
    wrote = ["connector://" + wct, '"id": "801000000000009AAA"'] if wct else ["PATCH ", "/sobjects/%s/801000000000009AAA" % cfg["sobject"]]
    no_write = "connector://" + wct if wct else "PATCH "
    remember = {cfg["remember_id_as"]: "801000000000009AAA"} if cfg["remember_id_as"] else {}
    sc = [{"name": "valid change -> saved", "tool": tool, "args": good, "variables": dict(gv), "responses": [patch, find],
           "expect": {"ok": True}, "calls_must_contain": list(wrote), "expect_variables": remember},
          {"name": "record not found -> not_found, no write", "tool": tool, "args": good, "variables": dict(gv),
           "responses": [{"when": "GET ", "status": 200, "json": {"records": []}}], "expect": {"ok": False, "error": "not_found"},
           "calls_must_not_contain": [no_write]},
          {"name": "nothing to change -> invalid_input, no call", "tool": tool, "args": dict({lk["param"]: good[lk["param"]]}, **confirm),
           "variables": dict(gv), "responses": [], "expect": {"ok": False, "error": "invalid_input"}, "expect_no_calls": True}]
    if cfg["scope_field"]:
        sc[0]["calls_must_contain"].append(cfg["scope_field"] + " = '001000000000001AAA'")
    if len(fields) > 1:
        sc[0]["calls_must_not_contain"] = [fields[1]["field"]]      # only the values the caller gave are sent
    texty = [f for f in fields if f.get("type", "string") in ("string", "text") and f.get("max_length")]
    if texty:
        t = texty[0]
        sc.append({"name": "value longer than its limit -> invalid_input, no call", "tool": tool,
                   "args": dict(good, **{t["param"]: "x" * (int(t["max_length"]) + 1)}), "variables": dict(gv), "responses": [],
                   "expect": {"ok": False, "error": "invalid_input"}, "expect_no_calls": True})
    if cfg["require_confirmation"]:
        sc.append({"name": "no caller confirmation -> not_confirmed, no call", "tool": tool, "args": dict(good, caller_confirmed=False),
                   "variables": dict(gv), "responses": [], "expect": {"ok": False, "error": "not_confirmed"}, "expect_no_calls": True})
    if cfg["require_verified"]:
        sc.append({"name": "caller not verified -> blocked, no call", "tool": tool, "args": good, "variables": _gating_vars(cfg, False),
                   "responses": [], "expect": {"ok": False, "error": "not_verified"}, "expect_no_calls": True})
    if wct:
        sc += [{"name": "connector write: falls back to the body shape when the flat shape is refused", "tool": tool, "args": good, "variables": dict(gv),
                "responses": [{"when": '"body"', "status": 204, "json": {}}, {"when": "connector://" + wct, "status": 400, "json": {}}, find],
                "expect": {"ok": True}, "expect_call_count": 3, "calls_must_contain": ['"body": {']},
               {"name": "connector write: every shape refused -> salesforce_error with the code", "tool": tool, "args": good, "variables": dict(gv),
                "responses": [{"when": "connector://" + wct, "status": 400, "json": {}}, find],
                "expect": {"ok": False, "error": "salesforce_error", "system_error": True, "code": 400}, "expect_call_count": 4},
               {"name": "connector write: an exception on the first shape falls back to the next", "tool": tool, "args": good, "variables": dict(gv),
                "responses": [{"when": '"body"', "status": 204, "json": {}}, {"when": "connector://" + wct, "raise": True, "status": 400}, find],
                "expect": {"ok": True}, "expect_call_count": 3},
               {"name": "connector write: an exception with 401 stops at once", "tool": tool, "args": good, "variables": dict(gv),
                "responses": [{"when": "connector://" + wct, "raise": True, "status": 401}, find],
                "expect": {"ok": False, "error": "salesforce_auth_failed", "system_error": True}, "expect_call_count": 2},
               {"name": "connector write: 401 stops at once -> salesforce_auth_failed", "tool": tool, "args": good, "variables": dict(gv),
                "responses": [{"when": "connector://" + wct, "status": 401, "json": {}}, find],
                "expect": {"ok": False, "error": "salesforce_auth_failed", "system_error": True}, "expect_call_count": 2}]
    sc += _auth_scenarios(tool, good, gv)
    return sc


# --------------------------------------------------------------------------------------------------------------
def build_identify_caller(name, p, where):
    cfg = {"sobject": p.get("sobject", "Contact"), "caller_id_variable": p.get("caller_id_variable", "telephony-caller-id"),
           "phone_fields": list(p.get("phone_fields", ["Phone", "MobilePhone"])), "name_field": p.get("name_field", "FirstName"),
           "email_field": p.get("email_field", "Email"), "account_field": p.get("account_field", "AccountId"),
           "match_digits": int(p.get("match_digits", 10)), "max_candidates": int(p.get("max_candidates", 20))}
    args = [{"name": "include_details", "type": "bool", "required": False,
             "doc": "Internal use by the start-of-call callback: also return the contact's email and ids. Leave empty."}]
    description = p.get("description") or ("Recognises the caller from the phone number they are calling from, by looking for exactly one matching Salesforce contact. "
                                           "It runs automatically at the start of the call. Do not call it yourself.")
    returns = "dict: ok, caller_status (known or unknown) and first_name. If system_error is true the lookup failed and the caller is treated as unknown."
    return dict(cfg=cfg, args=args, args_dict='{"include_details": include_details}', description=description, returns=returns,
                written=["caller_status", "caller_name", "caller_email", "caller_contact_id", "caller_account_id", "telephony-caller-id"],
                scenarios=lambda: _identify_scenarios(name, cfg))


def _identify_scenarios(tool, cfg):
    cid = cfg["caller_id_variable"]
    john = {"Id": "003000000000001AAA", "FirstName": "John", "Email": "john@example.com", "AccountId": "001000000000001AAA",
            "Phone": "(416) 555-0142", "MobilePhone": None}
    base = {cid: "+1 416 555 0142"}
    ids = {"caller_status": "known", "caller_name": "John", "caller_email": "john@example.com",
           "caller_contact_id": "003000000000001AAA", "caller_account_id": "001000000000001AAA"}
    unknown = {"caller_status": "unknown", "caller_name": "", "caller_email": "", "caller_contact_id": "", "caller_account_id": ""}

    def sc(name, **kw):
        d = {"name": name, "tool": tool, "args": {}, "variables": dict(base), "responses": [_ok({"records": [john]})]}
        d.update(kw)
        return d

    out = [sc("number matches one contact -> known, state stored, email not returned", expect={"ok": True, "caller_status": "known", "first_name": "John"},
              expect_absent=["email", "contact_id", "account_id"], expect_variables=ids, result_must_not_contain=["john@example.com"],
              calls_must_contain=["FROM Contact WHERE AccountId != null", "Phone LIKE '%0142'", "MobilePhone LIKE '%0142'", "LIMIT 20"]),
           sc("callback asks for details -> email and ids returned", args={"include_details": True},
              expect={"ok": True, "caller_status": "known", "email": "john@example.com", "contact_id": "003000000000001AAA", "account_id": "001000000000001AAA"}),
           sc("mobile number matches too", responses=[_ok({"records": [dict(john, Phone=None, MobilePhone="416.555.0142")]})],
              expect={"caller_status": "known"}, expect_variables={"caller_status": "known"}),
           sc("same last four digits but another number -> unknown", responses=[_ok({"records": [dict(john, Phone="(212) 555-0142")]})],
              expect={"ok": True, "caller_status": "unknown", "first_name": ""}, expect_variables=unknown),
           sc("two contacts on the same number -> unknown", responses=[_ok({"records": [john, dict(john, Id="003000000000002AAA", FirstName="Jane")]})],
              expect={"caller_status": "unknown"}, expect_variables=unknown),
           sc("no contact found -> unknown", responses=[_ok({"records": []})], expect={"caller_status": "unknown"}, expect_variables=unknown),
           sc("contact without an email is still recognised, email stays empty", responses=[_ok({"records": [dict(john, Email=None)]})],
              expect={"caller_status": "known", "first_name": "John"}, expect_variables=dict(ids, caller_email="")),
           sc("no caller number on this call -> unknown, no lookup", variables={cid: ""}, responses=[], expect={"caller_status": "unknown"},
              expect_variables=unknown, expect_no_calls=True),
           sc("number too short -> unknown, no lookup", variables={cid: "555"}, responses=[], expect={"caller_status": "unknown"}, expect_no_calls=True),
           sc("letters and quotes in the number never reach the query", variables={cid: "+1 416 555 0142'; DROP"},
              expect={"caller_status": "known"}, calls_must_contain=["Phone LIKE '%0142'"], calls_must_not_contain=["DROP", "'; "])]
    for a in _auth_scenarios(tool, {}, base):
        a["expect_variables"] = {"caller_status": "unknown"}
        a["expect"] = dict(a["expect"], caller_status="unknown")
        out.append(a)
    return out


def build_verify_email(name, p, where):
    cfg = {"max_attempts": int(p.get("max_attempts", 3)), "email_variable": p.get("email_variable", "caller_email")}
    args = [{"name": "email", "type": "str", "required": True,
             "doc": p.get("doc") or "The email address exactly as the caller said it, including spoken words such as \"at\" and \"dot\"."}]
    description = p.get("description") or (
        "Verifies the caller by comparing the email address they give with the email on their Salesforce contact. Call it once the caller has said their email address. "
        "If verified is true, the caller may be helped with their orders. If verified is false, do not share anything.")
    returns = ("dict: verified (true or false) and a message. If error is not_verified, tell the caller the email could not be verified and ask for another "
               "(see attempts_remaining). If error is locked_out, stop and end the call politely. If error is invalid_input, ask the caller to say the email again.")
    return dict(cfg=cfg, args=args, args_dict='{"email": email}', description=description, returns=returns,
                written=["caller_verified", "verification_attempts"], scenarios=lambda: _verify_email_scenarios(name, cfg))


def _verify_email_scenarios(tool, cfg):
    stored = "John.Smith@Gmail.com"
    base = {"caller_status": "known", cfg["email_variable"]: stored, "caller_verified": False, "verification_attempts": 0}
    mx = cfg["max_attempts"]

    def sc(name, email, **kw):
        d = {"name": name, "tool": tool, "args": {"email": email}, "variables": dict(base), "responses": []}
        d.update(kw)
        return d

    verified = dict(expect={"verified": True, "ok": True}, expect_variables={"caller_verified": True, "verification_attempts": 0},
                    result_must_not_contain=[stored, stored.lower()])
    return [sc("exact email -> verified", "john.smith@gmail.com", **verified),
            sc("capital letters and spaces around it -> verified", "  John.Smith@GMAIL.com ", **verified),
            sc("spoken: dot, at, dot -> verified", "john dot smith at gmail dot com", **verified),
            sc("spoken with 'at the rate' -> verified", "john dot smith at the rate gmail dot com", **verified),
            sc("spoken with 'at the rate of' -> verified", "john dot smith at the rate of gmail dot com", **verified),
            sc("spelled letters -> verified", "j o h n dot s m i t h at gmail dot com", **verified),
            sc("wrong email -> not verified, counted, nothing leaked", "someone@gmail.com",
               expect={"verified": False, "error": "not_verified", "attempts_remaining": mx - 1},
               expect_variables={"caller_verified": False, "verification_attempts": 1}, result_must_not_contain=[stored, stored.lower(), "john"]),
            sc("third wrong email -> not verified with none left", "other@gmail.com", variables=dict(base, verification_attempts=mx - 1),
               expect={"verified": False, "error": "not_verified", "attempts_remaining": 0}, expect_variables={"verification_attempts": mx}),
            sc("after the last try -> locked out, even with the right email", "john.smith@gmail.com", variables=dict(base, verification_attempts=mx),
               expect={"verified": False, "error": "locked_out"}, expect_variables={"caller_verified": False}),
            sc("not an email -> invalid_input, not counted", "my email is john", expect={"verified": False, "error": "invalid_input"},
               expect_variables={"verification_attempts": 0}),
            sc("empty input -> invalid_input, not counted", "", expect={"verified": False, "error": "invalid_input"},
               expect_variables={"verification_attempts": 0}),
            sc("caller was not recognised -> never verified, counted", "john.smith@gmail.com", variables=dict(base, caller_status="unknown", caller_email=""),
               expect={"verified": False, "error": "not_verified"}, expect_variables={"caller_verified": False, "verification_attempts": 1}),
            sc("unrecognised caller with a stale email in the variable is still never verified", "john.smith@gmail.com", variables=dict(base, caller_status="unknown"),
               expect={"verified": False, "error": "not_verified"}, expect_variables={"caller_verified": False, "verification_attempts": 1}),
            sc("blank email on the contact never matches", "x@gmail.com", variables=dict(base, caller_email=""),
               expect={"verified": False, "error": "not_verified"}, expect_variables={"verification_attempts": 1})]


# --------------------------------------------------------------------------------------------------------------
DEFAULT_TRANSCRIPT_FIELDS = {"transcript": "Transcript__c", "started_at": "Started_At__c", "ended_at": "Ended_At__c",
                             "duration_seconds": "Duration_Seconds__c", "turn_count": "Turn_Count__c", "outcome": "Outcome__c",
                             "caller_verified": "Caller_Verified__c", "agent_name": "Agent_Name__c"}
DEFAULT_REDACT = {"card number": r"\b(?:\d[ -]?){13,16}\b", "social security number": r"\b\d{3}-\d{2}-\d{4}\b"}


def build_save_transcript(name, p, where):
    cfg = {"sobject": p.get("sobject", "Voice_Call_Transcript__c"), "external_id_field": p.get("external_id_field", "Session_Id__c"),
           "fields": p.get("fields", DEFAULT_TRANSCRIPT_FIELDS),
           "links": p.get("links", {"Order__c": "verified_record_id", "Account__c": "verified_scope_id"}),
           "fixed_values": p.get("fixed_values", {}),
           "variable_fields": p.get("variable_fields", {}),
           "redact_patterns": p.get("redact_patterns", DEFAULT_REDACT), "max_chars": int(p.get("max_chars", 120000)),
           "max_attempts": int(p.get("max_attempts", 3)), "path_param": p.get("path_param", "session_id"),
           "connector_tool": p.get("connector_tool", "")}
    args = [{"name": "outcome", "type": "str", "required": False,
             "doc": "How the call ended: completed, escalated or system error. The end-of-call hook fills this in; leave it empty otherwise."}]
    description = p.get("description") or "Saves the transcript of this call to Salesforce. It runs automatically when the call ends. Do not call it yourself."
    returns = "dict: ok and a message. If system_error is true the transcript was not saved."
    return dict(cfg=cfg, args=args, args_dict='{"outcome": outcome}', description=description, returns=returns, written=[],
                scenarios=lambda: _save_scenarios(name, cfg))


def _save_scenarios(tool, cfg):
    ext, obj = cfg["external_id_field"], cfg["sobject"]
    connector = bool(cfg["connector_tool"])
    ev = [{"author": "user", "text": "<event>session start</event>"},
          {"author": "agent", "text": "Hello, thank you for calling.", "timestamp": 1800000000},
          {"author": "user", "text": "<context>agent speaking was interrupted. user only heard 'Hello, thank you' in the last agent response.</context> I want to check my order.", "timestamp": 1800000030},
          {"author": "agent", "text": "Sure. What is the order number?", "timestamp": 1800000040},
          {"author": "user", "text": "It is 102 and my card is 4111 1111 1111 1111.", "timestamp": 1800000100}]
    gv = {"caller_verified": True, "verification_attempts": 0}
    link_ids = {}                      # sample ids for whatever variables the configured links read
    for sf_field, variable in cfg["links"].items():
        low = sf_field.lower()
        link_ids[sf_field] = "801000000000001AAA" if low.startswith("order") else "003000000000001AAA" if low.startswith("contact") else "001000000000001AAA"
        gv[variable] = link_ids[sf_field]
    link_asserts = ['"%s": "%s"' % (f, i) for f, i in link_ids.items()]
    fm = cfg["fields"]

    def has(key, literal):
        return ['"%s": %s' % (fm[key], literal)] if key in fm else []
    base = {"tool": tool, "args": {}, "variables": dict(gv), "events": ev, "session_id": "sess-123", "agent_name": "Root agent"}
    ok_any = {"when": "connector://" if connector else "PATCH ", "status": 204, "json": {}}

    def sc(name, **kw):
        d = dict(base)
        d["name"] = name
        d.update(kw)
        return d

    out = [sc("saved: turns, links, flags and duration in the request", responses=[ok_any], args={"outcome": "completed"}, expect={"ok": True},
              calls_must_contain=["Caller: I want to check my order.", "Agent: Sure. What is the order number?"] + link_asserts + [
                                  ] + has("caller_verified", "true") + has("duration_seconds", "100") + has("turn_count", "2") + has("outcome", '"Completed"') + ["sess-123"],
              calls_must_not_contain=["<event>", "<context>", "interrupted", "4111 1111 1111 1111", "tok-test"]),
           sc("a turn that holds only a platform note is not a caller turn", responses=[ok_any], args={"outcome": "completed"}, expect={"ok": True},
              events=ev + [{"author": "user", "text": "<context>agent speaking was interrupted. user only heard 'Sure' in the last agent response.</context>", "timestamp": 1800000110}],
              calls_must_contain=has("turn_count", "2") + has("duration_seconds", "100"), calls_must_not_contain=["<context>", "interrupted"]),
           sc("escalation hint becomes the Escalated outcome", responses=[ok_any], args={"outcome": "escalated"}, expect={"ok": True},
              calls_must_contain=has("outcome", '"Escalated"') or ["sess-123"]),
           sc("verification-failed hint becomes the Verification failed outcome", responses=[ok_any], args={"outcome": "verification failed"},
              expect={"ok": True}, calls_must_contain=has("outcome", '"Verification failed"') or ["sess-123"], calls_must_not_contain=has("outcome", '"Completed"')),
           sc("never verified and out of attempts -> Verification failed", responses=[ok_any], variables={"caller_verified": False, "verification_attempts": 3},
              expect={"ok": True}, calls_must_contain=has("outcome", '"Verification failed"') + has("caller_verified", "false") or ["sess-123"], calls_must_not_contain=['"%s"' % f for f in link_ids]),
           sc("very long transcript is cut at the limit", responses=[ok_any], events=[{"author": "user", "text": "x" * 200000}],
              expect={"ok": True}, calls_must_contain=["[transcript truncated]"]),
           sc("no session id -> invalid_input, nothing sent", responses=[], session_id="", expect={"ok": False, "error": "invalid_input"}, expect_no_calls=True),
           sc("nothing said -> empty_transcript, nothing sent", responses=[], events=[{"author": "user", "text": "<event>session start</event>"}],
              expect={"ok": False, "error": "empty_transcript"}, expect_no_calls=True)]
    if not connector:
        out += [sc("session id is URL encoded in the key path", responses=[ok_any], session_id="a b/c", expect={"ok": True},
                   calls_must_contain=["/sobjects/%s/%s/a%%20b%%2Fc" % (obj, ext)]),
                sc("Salesforce 400 -> salesforce_error, no crash", responses=[{"when": "PATCH ", "status": 400, "json": [{"errorCode": "FIELD_INTEGRITY_EXCEPTION"}]}],
                   expect={"ok": False, "error": "salesforce_error", "system_error": True})]
        out += [dict(s_, events=ev, session_id="sess-123") for s_ in _auth_scenarios(tool, {}, gv)]
    else:
        flat_ok = {"when": "connector://", "status": 201, "json": {}}
        out += [sc("connector: flat argument shape works first time", responses=[flat_ok], expect={"ok": True}, expect_call_count=1,
                   calls_must_contain=['"%s"' % fm["transcript"], '"session_id": "sess-123"']),
                sc("connector: falls back to the body shape when the flat shape is refused",
                   responses=[{"when": '"body"', "status": 204, "json": {}}, {"when": "connector://", "status": 400, "json": {}}],
                   expect={"ok": True}, expect_call_count=2, calls_must_contain=['"body": {']),
                sc("connector: every shape refused -> salesforce_error with the code", responses=[{"when": "connector://", "status": 400, "json": {}}],
                   expect={"ok": False, "error": "salesforce_error", "system_error": True, "code": 400}, expect_call_count=3),
                sc("connector: 401 stops at once -> salesforce_auth_failed", responses=[{"when": "connector://", "status": 401, "json": {}}],
                   expect={"ok": False, "error": "salesforce_auth_failed", "system_error": True}, expect_call_count=1)]
    for variable, sf_field in cfg.get("variable_fields", {}).items():
        out.append(sc("variable %s is sent as %s (rounded whole number)" % (variable, sf_field), responses=[ok_any], expect={"ok": True},
                      variables=dict(gv, **{variable: 1234.6}), calls_must_contain=['"%s": 1235' % sf_field]))
        out.append(sc("zero variable %s is sent as 0" % variable, responses=[ok_any], expect={"ok": True},
                      variables=dict(gv, **{variable: 0}), calls_must_contain=['"%s": 0' % sf_field]))
    if "has_human_agent" in cfg["fields"] or cfg["fixed_values"]:
        mapped = cfg["fields"]
        if "has_human_agent" in mapped:
            out.append(sc("escalated call sets the human agent flag", responses=[ok_any], args={"outcome": "escalated"}, expect={"ok": True},
                          calls_must_contain=['"%s": true' % mapped["has_human_agent"]]))
            out.append(sc("completed call clears the human agent flag", responses=[ok_any], args={"outcome": "completed"}, expect={"ok": True},
                          calls_must_contain=['"%s": false' % mapped["has_human_agent"]]))
        for key in ("closed_at", "last_message_at"):
            if key in mapped:
                out.append(sc("%s is filled in" % key, responses=[ok_any], expect={"ok": True}, calls_must_contain=['"%s": "20' % mapped[key]]))
        for sf_field, fixed in cfg["fixed_values"].items():
            out.append(sc("fixed value %s is always sent" % sf_field, responses=[ok_any], expect={"ok": True},
                          calls_must_contain=['"%s": %s' % (sf_field, json_dumps(fixed))]))
    return out


BUILDERS = {"verify_caller": build_verify, "lookup_record": build_lookup, "search_records": build_search,
            "create_record": build_create, "update_record": build_update, "save_transcript": build_save_transcript,
            "identify_caller": build_identify_caller, "verify_contact_email": build_verify_email}


def _prune_helpers(src):
    """Remove nested helper functions that nothing calls, so the pasted tool stays short."""
    for _ in range(10):
        tree = ast.parse(src)
        main = [n for n in tree.body if isinstance(n, ast.FunctionDef)][0]
        nested = [n for n in main.body if isinstance(n, ast.FunctionDef)]
        lines = src.split("\n")
        removed = False
        for fn in nested:
            rest = "\n".join(lines[: fn.lineno - 1] + lines[fn.end_lineno:])
            if not re.search(r"\b%s\b" % re.escape(fn.name), rest):
                start = fn.lineno - 1
                end = fn.end_lineno
                while end < len(lines) and lines[end].strip() == "":
                    end += 1
                src = "\n".join(lines[:start] + lines[end:])
                removed = True
                break
        if not removed:
            break
    return src


def render_tool(name, template, params, sf, where):
    """Returns dict(source, description, variables_written, scenarios)."""
    transport_connector = sf.get("transport") == "connector"
    if template == "save_transcript":
        connector_tool = params.get("connector_tool", "") if transport_connector else ""
        if transport_connector and not connector_tool:
            raise SpecError("%s: with salesforce.transport 'connector' the save_transcript tool needs params.connector_tool (<connector name>_<operationId> of the upsert operation)" % where)
        params = dict(params, connector_tool=connector_tool)
    else:
        connector_tool = (params.get("connector_tool") or sf.get("connectorTool", "")) if transport_connector else ""
        if transport_connector:
            if not connector_tool:
                raise SpecError("%s: salesforce.transport is 'connector' but salesforce.connectorTool (the tool name Python calls) is missing" % where)
            if template == "create_record":
                raise SpecError("%s: create_record needs the REST transport; the connector transport reads (verify_caller, lookup_record, search_records, identify_caller), changes records (update_record with params.write_connector_tool) and saves transcripts" % where)
            if template == "update_record" and not params.get("write_connector_tool"):
                raise SpecError("%s: with salesforce.transport 'connector' update_record needs params.write_connector_tool (<connector name>_<operationId> of the update operation)" % where)
        if template == "update_record":
            params = dict(params, write_connector_tool=params.get("write_connector_tool", "") if transport_connector else "")
    if template not in BUILDERS:
        raise SpecError("%s: unknown template '%s' (available: %s)" % (where, template, ", ".join(sorted(BUILDERS))))
    b = BUILDERS[template](name, params, where)
    sig, uses_optional = _signature(b["args"])
    body = _read(template + ".py.tmpl")
    common = _read("_common.py.part")
    auth = sf.get("auth", {})
    common = (common.replace("__INSTANCE_URL__", repr(sf["instanceUrl"].rstrip("/")))
              .replace("__API_VERSION__", repr(sf.get("apiVersion", "v60.0")))
              .replace("__TOKEN_VARIABLE__", repr(auth.get("tokenVariable", "salesforce_access_token")))
              .replace("__CONNECTOR_TOOL__", repr(connector_tool))
              .replace("__CFG__", py_literal(b["cfg"]))
              .replace("__ARGS_DICT__", b["args_dict"]))
    src = (body.replace("__NAME__", name).replace("__SIGNATURE__", sig)
           .replace("__DOCSTRING__", _docstring(b["description"], b["args"], b["returns"]))
           .replace("__COMMON__", common.rstrip("\n") + "\n"))
    if connector_tool and template != "save_transcript":
        # connector mode never calls Salesforce directly: drop the REST branch, the unused settings and anything left unreferenced
        rest_branch = ('''  def _query(soql):
    if CONNECTOR_TOOL:
      return _query_via_connector(soql)
    resp, err = _request("GET", "/query", params={"q": soql})
    if err:
      return None, err
    return (resp.json().get("records") or []), None
''')
        if rest_branch in src:
            src = src.replace(rest_branch, "  def _query(soql):\n    return _query_via_connector(soql)\n")
        src = "\n".join(l for l in src.split("\n") if not l.startswith(("  INSTANCE_URL =", "  API_VERSION =", "  TOKEN_VARIABLE =")))
    if not b["cfg"].get("scope_field"):
        # no row-level scope configured: drop the scope code, so the tool does not mention verified_scope_id at all
        # (the console lists every tool that mentions a variable when you try to delete it)
        src = src.replace("    scope_sql, scope_err = _scope_clause()\n    if scope_err:\n      return scope_err\n", "").replace(" + scope_sql", "")
    src = _prune_helpers(src)
    if uses_optional:
        src = "from typing import Optional\n\n" + src
    try:
        tree = ast.parse(src)
    except SyntaxError as e:
        raise SpecError("%s: generated tool does not compile (line %s: %s)" % (where, e.lineno, e.msg))
    fn = [n for n in tree.body if isinstance(n, ast.FunctionDef)][0]
    doc = ast.get_docstring(fn) or ""
    variables = []
    for v in b["written"]:
        t, default, desc = STATE_VARS.get(v) or ("STRING", "", "Set by the %s tool." % name)
        variables.append({"name": v, "type": t, "default": default, "description": desc})
    reads_gate = template not in NO_GATE and bool(b["cfg"].get("require_verified", True))
    scenarios = b["scenarios"]()
    if transport_connector:
        scenarios = [dict(sc, transport="connector", connector_tool=connector_tool) for sc in scenarios
                     if not (sc["variables"] or {}).get("__no_token__")]     # no token to miss: the platform holds it
    return {"source": src, "description": doc, "variables": variables, "scenarios": scenarios, "needs_verify": reads_gate,
            "writes_gate": template in ("verify_caller", "verify_contact_email")}
