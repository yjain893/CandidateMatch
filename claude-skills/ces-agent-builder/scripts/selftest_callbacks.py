#!/usr/bin/env python3
"""Behaviour tests for the callback templates, run against the callbacks inside a built package.

  selftest_callbacks.py PACKAGE_DIR

The CES runtime classes (Part, LlmResponse, CallbackContext, LlmRequest) are faked from the documented Python runtime reference,
so this proves the logic of each callback, not the live platform. Callbacks whose template has no test here are only compiled.
"""
import json
import os
import re
import sys


class FunctionCall:
    def __init__(self, name, args):
        self.name, self.args = name, args


class FunctionResponse:
    def __init__(self, name, response):
        self.name, self.response = name, response


class Part:
    def __init__(self, text=None, function_call=None, function_response=None, kind=None, extra=None):
        self.text, self.function_call, self.function_response, self.kind, self.extra = text, function_call, function_response, kind, extra or {}

    def has_function_call(self, name):
        return bool(self.function_call and self.function_call.name == name)

    def has_function_response(self, name):
        return bool(self.function_response and self.function_response.name == name)

    @classmethod
    def from_text(cls, text=None):
        return cls(text=text, kind="text")

    @classmethod
    def from_function_call(cls, name, args):
        return cls(function_call=FunctionCall(name, args), kind="call")

    @classmethod
    def from_end_session(cls, *, reason, escalated=False):
        return cls(kind="end", extra={"reason": reason, "escalated": escalated})

    @classmethod
    def from_customized_response(cls, *, content, disable_barge_in=False, **kw):
        return cls(text=content, kind="custom", extra={"disable_barge_in": disable_barge_in})


class Content:
    def __init__(self, parts):
        self.parts = parts


class LlmResponse:
    def __init__(self, content):
        self.content = content

    @classmethod
    def from_parts(cls, parts):
        return cls(Content(list(parts)))


class Config:
    def __init__(self):
        self.hidden = []

    def hide_tool(self, name):
        self.hidden.append(name)


class LlmRequest:
    def __init__(self, parts=None):
        self.contents = [Content(parts or [])]
        self.config = Config()


class CallbackContext:
    def __init__(self, variables=None, user_input=None, agent_output=None):
        self.variables = variables or {}
        self.state = self.variables
        self._user, self._agent = user_input or [], agent_output or []
        self.agent_name = "Root agent"

    def get_last_user_input(self):
        return self._user

    def set_variable(self, key, value):
        self.variables[key] = value

    def get_last_agent_output(self):
        return self._agent


class FakeTool:
    """Stands in for the `tools` global: tools.<name>(args) returns what the test configured, or raises."""
    def __init__(self, result=None, error=None):
        self.result, self.error, self.calls = result, error, []

    def __getattr__(self, name):
        def call(args):
            self.calls.append((name, args))
            if self.error:
                raise self.error
            return self.result
        return call


class Wrapped:
    """A response object with .json(), as a connector call returns."""
    def __init__(self, body):
        self._body = body
        self.status_code = 200

    def json(self):
        return self._body


def identify(src):
    """Which template a callback file comes from, read from markers in its code. The console export names the folders
    after_model_callbacks_01 and so on, so the template name is not in the path (and exports may hold hand-written callbacks)."""
    markers = (("LOOKUP_TOOL =", "greet_known_caller"), ("SAVE_TOOL =", "save_transcript_on_end"), ("hide_tool(", "hide_tools"), ("GREETING =", "static_greeting"),
               ("WATCHED =", "escalate_on_system_error"), ("REQUIRED =", "mandatory_text"), ("PATTERNS =", "redact_output"),
               ("no user activity", "inactivity_prompt"))
    for needle, name in markers:
        if needle in src:
            return name
    return None


def load(path):
    src = open(path, encoding="utf-8").read()
    ns = {"Part": Part, "LlmResponse": LlmResponse, "LlmRequest": LlmRequest, "CallbackContext": CallbackContext}
    exec(compile(src, path, "exec"), ns)
    return src, ns


def texts(resp):
    return [p.text for p in resp.content.parts if p.text]


def names(resp):
    return [(p.function_call.name if p.function_call else p.kind) for p in resp.content.parts]


def t_static_greeting(src, ns):
    fn, out = ns["before_model_callback"], []
    greeting = re.search(r"GREETING = (.+)", src).group(1)
    placeholders = sorted(set(re.findall(r"\{(\w+)\}", greeting)))
    variables = {p: "VALUE_" + p for p in placeholders}
    r = fn(CallbackContext(variables, [Part.from_text("<event>session start</event>")]), LlmRequest())
    if r is None or not texts(r):
        return ["no greeting returned at session start"]
    for p in placeholders:
        if "VALUE_" + p not in texts(r)[-1]:
            out.append("placeholder {%s} was not filled from the variables" % p)
    if "{" in texts(r)[-1]:
        out.append("an unfilled placeholder is left in the greeting")
    if fn(CallbackContext(variables, [Part.from_text("hello")]), LlmRequest()) is not None:
        out.append("it replied to a normal turn (it must only act at session start)")
    if "DISCLAIMER = ''" not in src and not any(p.kind == "custom" and p.extra.get("disable_barge_in") for p in r.content.parts):
        out.append("a disclaimer is configured but is not spoken without barge-in")
    return out


def t_escalate(src, ns):
    fn, out = ns["before_model_callback"], []
    watched = eval(re.search(r"WATCHED = (\[.*?\])", src).group(1))
    name = watched[0] if watched else "any_tool"

    def with_result(result, tool=name):
        return LlmRequest([Part(function_response=FunctionResponse(tool, {"result": result}), kind="resp")])

    r = fn(CallbackContext(), with_result({"ok": False, "error": "salesforce_error", "system_error": True}))
    if r is None or "end" not in names(r) or not texts(r):
        out.append("a system error did not produce a spoken apology plus an end of session")
    elif not [p for p in r.content.parts if p.kind == "end"][0].extra["escalated"] and "ESCALATE = True" in src:
        out.append("the session end is not marked escalated")
    r = fn(CallbackContext(), with_result({"verified": False, "ok": False, "error": "locked_out"}))
    if r is None or "end" not in names(r):
        out.append("locked_out did not escalate")
    if fn(CallbackContext(), with_result({"verified": False, "ok": False, "error": "not_verified"})) is not None:
        out.append("an ordinary not_verified result escalated (the caller must be allowed to retry)")
    if fn(CallbackContext(), with_result({"ok": True})) is not None:
        out.append("a successful result escalated")
    if watched and fn(CallbackContext(), with_result({"system_error": True}, tool="some_other_tool")) is not None:
        out.append("an unwatched tool triggered the escalation")
    if fn(CallbackContext(), LlmRequest([Part.from_text("hi")])) is not None:
        out.append("a plain text turn triggered the escalation")
    return out


def t_inactivity(src, ns):
    fn = ns["before_model_callback"]
    r = fn(CallbackContext(user_input=[Part.from_text("no user activity detected")]), LlmRequest())
    out = [] if r is not None and texts(r) else ["silence did not get the fixed prompt"]
    if fn(CallbackContext(user_input=[Part.from_text("my order is 102")]), LlmRequest()) is not None:
        out.append("a normal turn got the silence prompt")
    return out


def t_redact(src, ns):
    fn = ns["after_model_callback"]
    r = fn(CallbackContext(), LlmResponse.from_parts([Part.from_text("Your card 4111 1111 1111 1111 and SSN 123-45-6789 are on file."), Part.from_function_call("x", {})]))
    out = []
    if r is None:
        return ["card and SSN patterns were not removed"]
    spoken = " ".join(texts(r))
    if "4111" in spoken or "123-45-6789" in spoken:
        out.append("sensitive numbers are still in the reply")
    if not [p for p in r.content.parts if p.function_call]:
        out.append("non-text parts were dropped")
    if fn(CallbackContext(), LlmResponse.from_parts([Part.from_text("Your order is on its way.")])) is not None:
        out.append("clean text was rewritten")
    return out


def t_mandatory(src, ns):
    fn = ns["after_model_callback"]
    required = re.search(r"REQUIRED = (.+)", src).group(1).strip("'\"")
    resp = lambda: LlmResponse.from_parts([Part.from_text("How can I help?")])
    r = fn(CallbackContext({"first_turn": True}, agent_output=[Part.from_text("How can I help?")]), resp())
    out = []
    if r is None or texts(r)[0] != required:
        out.append("the required text was not put first on the first turn")
    if fn(CallbackContext({"first_turn": False}, agent_output=[Part.from_text("x")]), resp()) is not None:
        out.append("it acted after the first turn")
    if fn(CallbackContext({"first_turn": True}, agent_output=[Part.from_text(required + " Hello")]), resp()) is not None:
        out.append("it repeated text the agent had already said")
    return out


def t_save_on_end(src, ns):
    fn = ns["after_model_callback"]
    tool = re.search(r"SAVE_TOOL = '([^']+)'", src).group(1)
    out = []

    def run(parts):
        return fn(CallbackContext(), LlmResponse.from_parts(parts))

    for label, args, want in (("success", {"reason": "success"}, "completed"), ("escalated", {"reason": "escalate_to_human", "session_escalated": True}, "escalated"),
                              ("tool failure", {"reason": "tool_failure: x", "session_escalated": True}, "escalated"),
                              ("verification failed", {"reason": "verification_failed"}, "verification failed")):
        r = run([Part.from_text("Goodbye."), Part.from_function_call("end_session", args)])
        if r is None or names(r) != ["text", tool, "end_session"]:
            out.append("%s: the save call was not placed between the goodbye and end_session (got %s)" % (label, names(r) if r else None))
            continue
        got = r.content.parts[1].function_call.args.get("outcome")
        if got != want:
            out.append("%s: outcome %r, expected %r" % (label, got, want))
    r = run([Part.from_function_call("end_session", {"reason": "system problem"})])
    if r is None or r.content.parts[0].function_call.args.get("outcome") != "system error":
        out.append("a system reason did not become the 'system error' outcome")
    if run([Part.from_text("Still talking.")]) is not None:
        out.append("it acted on a turn that does not end the call")
    if run([Part.from_function_call(tool, {}), Part.from_function_call("end_session", {"reason": "success"})]) is not None:
        out.append("it added the save call twice")
    if fn(CallbackContext(), LlmResponse(None)) is not None:
        out.append("it failed on an empty response instead of ignoring it")
    return out


def t_greet(src, ns):
    fn, out = ns["before_model_callback"], []
    mode = re.search(r"MODE = '([^']+)'", src).group(1)
    known = {"caller_status": "known", "first_name": "John", "email": "john@example.com", "contact_id": "003000000000001AAA", "account_id": "001000000000001AAA"}
    unknown = {"caller_status": "unknown", "first_name": ""}
    start = [Part.from_text("<event>session start</event>")]

    def ctx():
        return CallbackContext({"company_name": "Abbott"}, list(start))

    def reply_to_call(result):
        # tool_call mode: the greeting is built when the tool result is back in the request
        return LlmRequest([Part(function_response=FunctionResponse("identify_caller", {"result": result} if "caller_status" in result else result), kind="resp")])

    def last(r):
        return texts(r)[-1] if r is not None and texts(r) else ""

    if mode == "direct":
        for label, result in (("a dict", known), ("a wrapped dict", {"result": known}), ("a response object", Wrapped(known))):
            ns["tools"] = FakeTool(result)
            c = ctx()
            r = fn(c, LlmRequest())
            if "John" not in last(r) or "Abbott" not in last(r) or "{" in last(r):
                out.append("known caller (%s): greeting is %r" % (label, last(r)))
            want = {"caller_status": "known", "caller_name": "John", "caller_email": "john@example.com", "caller_contact_id": "003000000000001AAA", "caller_account_id": "001000000000001AAA"}
            for k, v in want.items():
                if c.variables.get(k) != v:
                    out.append("known caller (%s): variable %s = %r, expected %r" % (label, k, c.variables.get(k), v))
        if ns["tools"].calls != [("identify_caller", {"include_details": True})]:
            out.append("the lookup tool was not called once with include_details: %s" % ns["tools"].calls)
        ns["tools"] = FakeTool(unknown)
        c = ctx()
        r = fn(c, LlmRequest())
        if "John" in last(r) or "Abbott" not in last(r) or "Hello," not in last(r):
            out.append("unknown caller: greeting is %r" % last(r))
        if c.variables.get("caller_status") != "unknown" or c.variables.get("caller_email"):
            out.append("unknown caller: variables %s" % c.variables)
        ns["tools"] = FakeTool(error=RuntimeError("boom"))
        c = ctx()
        r = fn(c, LlmRequest())
        if "Abbott" not in last(r) or c.variables.get("caller_status") != "unknown":
            out.append("a failing lookup must still greet, as an unknown caller (got %r, %s)" % (last(r), c.variables.get("caller_status")))
        ns.pop("tools", None)
        c = ctx()
        r = fn(c, LlmRequest())
        if "Abbott" not in last(r) or c.variables.get("caller_status") != "unknown":
            out.append("without the tools global the greeting must still work, as an unknown caller")
        ns["tools"] = FakeTool(dict(known, first_name=""))
        c = ctx()
        r = fn(c, LlmRequest())
        if "Hello," not in last(r) or c.variables.get("caller_status") != "known":
            out.append("a known contact without a first name gets the greeting without a name, and stays known (got %r)" % last(r))
        class NoSetContext(CallbackContext):
            def set_variable(self, key, value):
                raise RuntimeError("variables are read only here")

        ns["tools"] = FakeTool(known)
        r = fn(NoSetContext({"company_name": "Abbott"}, list(start)), LlmRequest())
        if "John" not in last(r) or "Abbott" not in last(r):
            out.append("when variables cannot be set the caller must still be greeted by name (got %r)" % last(r))
        ns["tools"] = FakeTool(known)
        if fn(CallbackContext({"company_name": "Abbott"}, [Part.from_text("hello")]), LlmRequest()) is not None or ns["tools"].calls:
            out.append("a normal turn must neither greet nor call the tool")
    else:
        r = fn(ctx(), LlmRequest())
        if r is None or names(r) != ["identify_caller"]:
            out.append("session start must ask for the lookup tool call (got %s)" % (names(r) if r else None))
        for label, result in (("known", known), ("unknown", unknown)):
            r = fn(CallbackContext({"company_name": "Abbott"}, list(start)), reply_to_call(result))
            if label == "known" and ("John" not in last(r) or "{" in last(r)):
                out.append("known caller: greeting is %r" % last(r))
            if label == "unknown" and ("John" in last(r) or "Abbott" not in last(r)):
                out.append("unknown caller: greeting is %r" % last(r))
        if fn(CallbackContext({}, [Part.from_text("hello")]), LlmRequest()) is not None:
            out.append("a normal turn must be left alone")
    return out


def t_hide(src, ns):
    fn = ns["before_model_callback"]
    hidden = eval(re.search(r"for tool_name in (\[.*?\]):", src).group(1))
    req = LlmRequest()
    r = fn(CallbackContext(), req)
    out = []
    if sorted(req.config.hidden) != sorted(hidden):
        out.append("hid %s, expected %s" % (req.config.hidden, hidden))
    if r is not None:
        out.append("it replaced the model response (it should only hide tools)")
    return out


TESTS = {"static_greeting": t_static_greeting, "escalate_on_system_error": t_escalate, "inactivity_prompt": t_inactivity,
         "redact_output": t_redact, "mandatory_text": t_mandatory, "save_transcript_on_end": t_save_on_end, "hide_tools": t_hide,
         "greet_known_caller": t_greet}


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = sys.argv[1]
    total = failed = 0
    for d in sorted(os.listdir(os.path.join(root, "agents"))):
        jf = os.path.join(root, "agents", d, d + ".json")
        if not os.path.isfile(jf):
            continue
        agent = json.load(open(jf))
        for key, entries in agent.items():
            if not key.endswith("Callbacks"):
                continue
            for cb in entries:
                path = os.path.join(root, cb["pythonCode"])
                label = "?"
                try:
                    src, ns = load(path)
                    label = identify(src) or os.path.basename(os.path.dirname(cb["pythonCode"]))
                except Exception as e:
                    print("FAIL %s/%s: does not load: %s" % (d, label, e))
                    failed += 1
                    total += 1
                    continue
                if label not in TESTS:
                    print("skip %s/%s: compiled, no behaviour test" % (d, label))
                    continue
                total += 1
                try:
                    problems = TESTS[label](src, ns)
                except Exception as e:
                    problems = ["raised %s: %s" % (type(e).__name__, e)]
                if problems:
                    failed += 1
                    print("FAIL %s/%s" % (d, label))
                    for p in problems:
                        print("       - " + p)
                else:
                    print("ok   %s/%s" % (d, label))
    print("CALLBACK TESTS: %d tested, %d failed" % (total, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
