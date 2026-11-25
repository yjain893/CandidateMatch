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


class Ev:
    """A session event: who said what."""
    def __init__(self, author, text):
        self.author = author
        self.content = Content([Part.from_text(text)])

    def is_user(self):
        return self.author == "user"


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
    def __init__(self, variables=None, user_input=None, agent_output=None, events=None):
        self.events = events or []
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
    markers = (("def before_agent_callback(", "lookup_caller_on_start"), ("LOOKUP_TOOL =", "greet_known_caller"), ("SAVE_TOOL =", "save_transcript_on_end"), ("hide_tool(", "hide_tools"), ("GREETING =", "static_greeting"),
               ("WATCHED =", "escalate_on_system_error"), ("REQUIRED =", "mandatory_text"), ("PATTERNS =", "redact_output"),
               ("CHARS_PER_TOKEN_OUT =", "token_count_output"), ("CHARS_PER_TOKEN =", "token_count_input"),
               ("no user activity", "inactivity_prompt"))
    for needle, name in markers:
        if needle in src:
            return name
    return None


def load(path):
    src = open(path, encoding="utf-8").read()
    ns = {"Part": Part, "LlmResponse": LlmResponse, "LlmRequest": LlmRequest, "CallbackContext": CallbackContext, "Content": Content}
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
    r = run([Part.from_text("Sorry."), Part.from_function_call("end_session", {"reason": "system problem"})])
    save_parts = [p for p in r.content.parts if p.function_call and p.function_call.name == tool] if r else []
    if not save_parts or save_parts[0].function_call.args.get("outcome") != "system error":
        out.append("a system reason did not become the 'system error' outcome")
    if run([Part.from_text("Still talking.")]) is not None:
        out.append("it acted on a turn that does not end the call")
    if run([Part.from_function_call(tool, {}), Part.from_function_call("end_session", {"reason": "success"})]) is not None:
        out.append("it added the save call twice")
    if fn(CallbackContext(), LlmResponse(None)) is not None:
        out.append("it failed on an empty response instead of ignoring it")
    closing = eval(re.search(r"CLOSING = (\{.*\})", src).group(1))
    ends = {"completed": {"reason": "success"}, "escalated": {"reason": "escalate_to_human", "session_escalated": True},
            "verification failed": {"reason": "verification_failed"}, "system error": {"reason": "system problem"}}
    for outcome, args in ends.items():
        silent = run([Part.from_function_call("end_session", args)])
        if outcome in closing:
            if silent is None or names(silent) != ["text", tool, "end_session"] or texts(silent)[0] != closing[outcome]:
                out.append("%s: a call ended without words must get the closing text before the save and end_session (got %s)" % (outcome, names(silent) if silent else None))
            talked = run([Part.from_text("My own goodbye."), Part.from_function_call("end_session", args)])
            if talked is None or texts(talked) != ["My own goodbye."]:
                out.append("%s: the model's own words must be left alone (got %s)" % (outcome, texts(talked) if talked else None))
        elif silent is None or "text" in names(silent):
            out.append("%s: no closing text is configured, so none may be added" % outcome)
    return out


def t_greet(src, ns):
    fn, out = ns["before_model_callback"], []
    mode = re.search(r"MODE = '([^']+)'", src).group(1)
    speak = re.search(r"SPEAK = '([^']+)'", src).group(1)
    tell = "TELL = True" in src
    known = {"caller_status": "known", "first_name": "John", "email": "john@example.com", "contact_id": "003000000000001AAA", "account_id": "001000000000001AAA"}
    unknown = {"caller_status": "unknown", "first_name": ""}
    start = [Part.from_text("<event>session start</event>")]
    want_known = {"caller_status": "known", "caller_name": "John", "caller_email": "john@example.com", "caller_contact_id": "003000000000001AAA", "caller_account_id": "001000000000001AAA"}

    def ctx(cls=CallbackContext):
        return cls({"company_name": "Abbott"}, list(start))

    def last(r):
        return texts(r)[-1] if r is not None and texts(r) else ""

    def silent_or_greets(label, r, name_expected):
        # speak model: the callback never answers (the agent says the greeting); speak callback: it answers, by name or not
        if speak == "model":
            if r is not None:
                out.append("%s: with speak model the callback must not answer, it said %r" % (label, last(r)))
        elif ("John" in last(r)) != name_expected or "Abbott" not in last(r):
            out.append("%s: greeting is %r" % (label, last(r)))

    def reply_to_call(result):
        return LlmRequest([Part(function_response=FunctionResponse("identify_caller", {"result": result}), kind="resp")])

    def noted(req):
        return " ".join(p.text for p in req.contents[-1].parts if p.text)

    if mode == "direct":
        for label, result in (("a dict", known), ("a wrapped dict", {"result": known}), ("a response object", Wrapped(known))):
            ns["tools"] = FakeTool(result)
            c = ctx()
            req = LlmRequest()
            silent_or_greets("known caller (%s)" % label, fn(c, req), True)
            if speak == "model" and "has just connected" not in noted(req):
                out.append("known caller (%s): the model must get the cue to speak first (got %r)" % (label, noted(req)))
            if speak == "model" and not tell and "caller_name" in noted(req):
                out.append("known caller (%s): tell_model is off, so no caller note is wanted (got %r)" % (label, noted(req)))
            if speak == "model" and tell and ("caller_name: John" not in noted(req) or "caller_status: known" not in noted(req)):
                out.append("known caller (%s): the model must be told the name in its own request (got %r)" % (label, noted(req)))
            for k, v in want_known.items():
                if c.variables.get(k) != v:
                    out.append("known caller (%s): variable %s = %r, expected %r" % (label, k, c.variables.get(k), v))
        if ns["tools"].calls != [("identify_caller", {"include_details": True})]:
            out.append("the lookup tool was not called once with include_details: %s" % ns["tools"].calls)
        ns["tools"] = FakeTool(unknown)
        c = ctx()
        req = LlmRequest()
        silent_or_greets("unknown caller", fn(c, req), False)
        if speak == "model" and tell and ("caller_status: unknown" not in noted(req) or "caller_name" in noted(req)):
            out.append("unknown caller: the model must be told the caller is unknown, with no name (got %r)" % noted(req))
        if c.variables.get("caller_status") != "unknown" or c.variables.get("caller_email"):
            out.append("unknown caller: variables %s" % c.variables)
        ns["tools"] = FakeTool(error=RuntimeError("boom"))
        c = ctx()
        silent_or_greets("failing lookup", fn(c, LlmRequest()), False)
        if c.variables.get("caller_status") != "unknown":
            out.append("a failing lookup must leave the caller as unknown (got %s)" % c.variables.get("caller_status"))
        ns.pop("tools", None)
        c = ctx()
        silent_or_greets("no tools global", fn(c, LlmRequest()), False)
        if c.variables.get("caller_status") != "unknown":
            out.append("without the tools global the caller must be unknown")
        ns["tools"] = FakeTool(dict(known, first_name=""))
        c = ctx()
        r = fn(c, LlmRequest())
        if c.variables.get("caller_status") != "known" or (speak == "callback" and "Hello," not in last(r)):
            out.append("a known contact without a first name stays known, and is greeted without a name (got %r, %s)" % (last(r), c.variables.get("caller_status")))

        class NoSetContext(CallbackContext):
            def set_variable(self, key, value):
                raise RuntimeError("variables are read only here")

        ns["tools"] = FakeTool(known)
        req = LlmRequest()
        silent_or_greets("variables cannot be set", fn(ctx(NoSetContext), req), True)
        if speak == "model" and tell and "caller_name: John" not in noted(req):
            out.append("when variables cannot be set the model must still be told the name in its request (got %r)" % noted(req))
        # an earlier before-agent callback already looked the caller up: no second lookup, same note
        ns["tools"] = FakeTool(known)
        c = CallbackContext({"company_name": "Abbott", "caller_status": "known", "caller_name": "John"}, list(start))
        req = LlmRequest()
        silent_or_greets("already looked up", fn(c, req), True)
        if ns["tools"].calls:
            out.append("a caller already looked up must not be looked up again (calls: %s)" % ns["tools"].calls)
        if speak == "model" and tell and "caller_name: John" not in noted(req):
            out.append("already looked up: the model must still be told the name (got %r)" % noted(req))
        # a request that cannot be changed must not break the call
        ns["tools"] = FakeTool(known)
        req = LlmRequest()
        req.contents[-1].parts = ()
        try:
            fn(ctx(), req)
        except Exception as e:
            out.append("a request that cannot be changed must not raise (%s)" % type(e).__name__)
        # the first model input is only notes, not the session start event: it must still count as the start
        ns["tools"] = FakeTool(known)
        c = CallbackContext({"company_name": "Abbott"}, [Part.from_text("<state_update>caller_status: known</state_update>")],
                            events=[Ev("user", "<event>session start</event>"), Ev("user", "<state_update>caller_status: known</state_update>")])
        req = LlmRequest()
        fn(c, req)
        if speak == "model" and "has just connected" not in noted(req):
            out.append("when the first input is only notes the model must still get the cue (got %r)" % noted(req))
        # a later turn: the agent has spoken and the caller has answered
        ns["tools"] = FakeTool(known)
        later = [Ev("user", "<event>session start</event>"), Ev("agent", "Hello John."), Ev("user", "Hi")]
        req = LlmRequest()
        if fn(CallbackContext({"company_name": "Abbott"}, [Part.from_text("Hi")], events=later), req) is not None or ns["tools"].calls or noted(req):
            out.append("a later turn must neither answer, look the caller up again, nor get the cue (calls %s, request %r)" % (ns["tools"].calls, noted(req)))
    else:
        r = fn(ctx(), LlmRequest())
        if r is None or names(r) != ["identify_caller"]:
            out.append("session start must ask for the lookup tool call (got %s)" % (names(r) if r else None))
        for label, result in (("known", known), ("unknown", unknown)):
            silent_or_greets("%s caller, result back" % label, fn(CallbackContext({"company_name": "Abbott"}, list(start)), reply_to_call(result)), label == "known")
        if fn(CallbackContext({}, [Part.from_text("hello")], events=[Ev("agent", "Hello.")]), LlmRequest()) is not None:
            out.append("a normal turn must be left alone")
    return out


def t_lookup_agent(src, ns):
    fn, out = ns["before_agent_callback"], []
    known = {"caller_status": "known", "first_name": "John", "email": "john@example.com", "contact_id": "003000000000001AAA", "account_id": "001000000000001AAA"}
    unknown = {"caller_status": "unknown", "first_name": ""}
    want_known = {"caller_status": "known", "caller_name": "John", "caller_email": "john@example.com", "caller_contact_id": "003000000000001AAA", "caller_account_id": "001000000000001AAA"}

    def ctx(variables=None, cls=CallbackContext):
        return cls(variables or {}, [Part.from_text("<event>session start</event>")])

    for label, result in (("a dict", known), ("a wrapped dict", {"result": known}), ("a response object", Wrapped(known))):
        ns["tools"] = FakeTool(result)
        c = ctx()
        if fn(c) is not None:
            out.append("known caller (%s): the callback must not answer, only store the caller" % label)
        for k, v in want_known.items():
            if c.variables.get(k) != v:
                out.append("known caller (%s): variable %s = %r, expected %r" % (label, k, c.variables.get(k), v))
        if ns["tools"].calls != [("identify_caller", {"include_details": True})]:
            out.append("the lookup tool was not called once with include_details: %s" % ns["tools"].calls)
    ns["tools"] = FakeTool(unknown)
    c = ctx()
    fn(c)
    if c.variables.get("caller_status") != "unknown" or c.variables.get("caller_email") or c.variables.get("caller_name"):
        out.append("unknown caller: variables %s" % c.variables)
    for label, tools in (("a failing lookup", FakeTool(error=RuntimeError("boom"))), ("no tools global", None)):
        if tools is None:
            ns.pop("tools", None)
        else:
            ns["tools"] = tools
        c = ctx()
        fn(c)
        if c.variables.get("caller_status") != "unknown":
            out.append("%s must leave the caller as unknown (got %s)" % (label, c.variables.get("caller_status")))
    ns["tools"] = FakeTool(known)
    c = ctx({"caller_status": "known", "caller_name": "John"})
    fn(c)
    if ns["tools"].calls:
        out.append("a caller already looked up must not be looked up again (calls: %s)" % ns["tools"].calls)

    class NoSetContext(CallbackContext):
        def set_variable(self, key, value):
            raise RuntimeError("variables are read only here")

    ns["tools"] = FakeTool(known)
    try:
        fn(ctx(cls=NoSetContext))
    except Exception as e:
        out.append("variables that cannot be set must not break the call (%s)" % type(e).__name__)
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


def _const(src, name):
    return float(re.search(r"^\s*" + name + r" = ([0-9.]+)", src, re.M).group(1))


def t_token_in(src, ns):
    fn = ns["before_model_callback"]
    cpt = _const(src, "CHARS_PER_TOKEN")
    extra = int(_const(src, "FIXED_OVERHEAD_CHARS"))
    out = []
    ctx = CallbackContext()
    req = LlmRequest([Part.from_text("x" * 350), Part.from_function_call("get_order_status", {"order_number": "112"})])
    letters = 350 + len("get_order_status") + len(str({"order_number": "112"})) + extra
    if fn(ctx, req) is not None:
        out.append("it replaced the model call (it should only measure)")
    want = int(round(letters / cpt))
    if ctx.variables.get("tokens_in_est") != want:
        out.append("tokens_in_est %s, expected %s" % (ctx.variables.get("tokens_in_est"), want))
    fn(ctx, req)
    if ctx.variables.get("tokens_in_est") != 2 * want:
        out.append("the second call did not add to the running total")
    # a request that also carries an instruction text and tool definitions is counted too
    req.config.system_instruction = "y" * 700
    req.config.tools = ["z" * 100]
    ctx2 = CallbackContext()
    fn(ctx2, req)
    want2 = int(round((letters + 700 + len(str("z" * 100))) / cpt))
    if ctx2.variables.get("tokens_in_est") != want2:
        out.append("instruction and tool text not counted: %s, expected %s" % (ctx2.variables.get("tokens_in_est"), want2))
    # a broken request must never break the call
    class Broken:
        @property
        def contents(self):
            raise RuntimeError("boom")
    try:
        if fn(CallbackContext(), Broken()) is not None:
            out.append("a broken request changed the flow")
    except Exception as e:
        out.append("a broken request raised " + type(e).__name__)
    return out


def t_token_out(src, ns):
    fn = ns["after_model_callback"]
    cpt, cpt_tts = _const(src, "CHARS_PER_TOKEN_OUT"), _const(src, "CHARS_PER_TOKEN_TTS")
    wps, tps = _const(src, "WORDS_PER_SECOND"), _const(src, "TTS_TOKENS_PER_SECOND")
    out = []
    ctx = CallbackContext(variables={"tokens_in_est": 1000})
    text = "Your order status is Activated."
    resp = LlmResponse.from_parts([Part.from_text(text), Part.from_function_call("save_transcript", {"outcome": "completed"})])
    before = [(p.text, p.function_call) for p in resp.content.parts]
    if fn(ctx, resp) is not None:
        out.append("it replaced the reply (it should only measure)")
    if [(p.text, p.function_call) for p in resp.content.parts] != before:
        out.append("it changed the reply")
    written = len(text) + len("save_transcript") + len(str({"outcome": "completed"}))
    want = {"tokens_out_est": int(round(written / cpt)), "tts_in_est": int(round(len(text) / cpt_tts)),
            "tts_out_est": int(round(len(text.split()) / wps * tps))}
    for k, v in want.items():
        if ctx.variables.get(k) != v:
            out.append("%s %s, expected %s" % (k, ctx.variables.get(k), v))
    total = 1000 + sum(want.values())
    if ctx.variables.get("tokens_total_est") != total:
        out.append("tokens_total_est %s, expected %s" % (ctx.variables.get("tokens_total_est"), total))
    # a reply that is only a tool call is not spoken: no voice tokens
    ctx2 = CallbackContext()
    fn(ctx2, LlmResponse.from_parts([Part.from_function_call("get_order_status", {"order_number": "1"})]))
    if ctx2.variables.get("tts_in_est") or ctx2.variables.get("tts_out_est"):
        out.append("a tool-call-only reply was counted as speech")
    if not ctx2.variables.get("tokens_out_est"):
        out.append("a tool call was not counted as model output")
    # partial streaming chunks are skipped, empty replies are ignored
    ctx3 = CallbackContext()
    part = LlmResponse.from_parts([Part.from_text("hello there")])
    part.partial = True
    fn(ctx3, part)
    fn(ctx3, LlmResponse(None))
    fn(ctx3, None)
    if ctx3.variables.get("tokens_out_est"):
        out.append("a partial or empty reply was counted")
    return out


TESTS = {"static_greeting": t_static_greeting, "escalate_on_system_error": t_escalate, "inactivity_prompt": t_inactivity,
         "redact_output": t_redact, "mandatory_text": t_mandatory, "save_transcript_on_end": t_save_on_end, "hide_tools": t_hide,
         "greet_known_caller": t_greet, "lookup_caller_on_start": t_lookup_agent,
         "token_count_input": t_token_in, "token_count_output": t_token_out}


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
