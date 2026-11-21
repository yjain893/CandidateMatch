"""Callback templates (Python code run by CES before/after model, tool and agent steps).

Callback signatures and the helper classes (Part, LlmResponse, CallbackContext) come from the CES Python runtime
reference; the patterns come from the official best-practices page. See references/guardrails-guide.md.
"""
import ast

from .common import SpecError, need

HEADER = "from typing import Optional\n\n"


def _lit(s):
    return repr(str(s))


def static_greeting(p):
    greeting = need(p, "greeting", "callback static_greeting")
    disclaimer = p.get("disclaimer", "")
    return "before_model_callback", HEADER + '''def before_model_callback(
    callback_context: CallbackContext,
    llm_request: LlmRequest
) -> Optional[LlmResponse]:
  """Speaks a fixed greeting when the session starts, which saves a model call and cuts latency."""
  GREETING = %s
  DISCLAIMER = %s

  def _fill(text):
    # {variable_name} placeholders are filled from the session variables
    values = {k: v for k, v in callback_context.variables.items() if isinstance(v, (str, int, float, bool))}
    try:
      return text.format(**values)
    except (KeyError, IndexError, ValueError):
      return text

  for part in callback_context.get_last_user_input():
    if part.text == "<event>session start</event>":
      parts = []
      if DISCLAIMER:
        # the caller cannot interrupt the disclaimer
        parts.append(Part.from_customized_response(content=_fill(DISCLAIMER), disable_barge_in=True))
      parts.append(Part.from_text(text=_fill(GREETING)))
      return LlmResponse.from_parts(parts=parts)
  return None
''' % (_lit(greeting), _lit(disclaimer)), []


def mandatory_text(p):
    text = need(p, "text", "callback mandatory_text")
    return "after_model_callback", HEADER + '''def after_model_callback(
    callback_context: CallbackContext,
    llm_response: LlmResponse
) -> Optional[LlmResponse]:
  """Makes sure the first reply contains required wording (for example a recording notice)."""
  REQUIRED = %s
  if callback_context.variables.get("first_turn"):
    callback_context.variables["first_turn"] = False
    for part in callback_context.get_last_agent_output():
      if part.text and REQUIRED in part.text:
        return None
    return LlmResponse.from_parts(parts=[Part.from_text(REQUIRED), *llm_response.content.parts])
  return None
''' % _lit(text), [{"name": "first_turn", "type": "BOOLEAN", "default": True, "description": "True until the first agent reply has been checked by the mandatory text callback."}]


def escalate_on_system_error(p):
    tools = p.get("tools") or []
    message = p.get("message", "Sorry, something went wrong on our side. Let me connect you with a team member.")
    escalate = bool(p.get("escalate", True))
    return "before_model_callback", HEADER + '''def before_model_callback(
    callback_context: CallbackContext,
    llm_request: LlmRequest
) -> Optional[LlmResponse]:
  """When a tool reports a system error, stop immediately instead of letting the model improvise."""
  WATCHED = %s          # empty list means every tool
  MESSAGE = %s
  ESCALATE = %s
  for part in llm_request.contents[-1].parts:
    if not part.function_response:
      continue
    if WATCHED and part.function_response.name not in WATCHED:
      continue
    response = part.function_response.response or {}
    result = response.get("result", response)
    if isinstance(result, dict) and (result.get("system_error") or result.get("error") == "locked_out"):
      return LlmResponse.from_parts(parts=[
          Part.from_text(MESSAGE),
          Part.from_end_session(reason="tool_failure: " + str(result.get("error")), escalated=ESCALATE),
      ])
  return None
''' % (repr(list(tools)), _lit(message), repr(escalate)), []


def inactivity_prompt(p):
    text = p.get("text", "Are you still there?")
    return "before_model_callback", HEADER + '''def before_model_callback(
    callback_context: CallbackContext,
    llm_request: LlmRequest
) -> Optional[LlmResponse]:
  """Fixed reply when the caller goes quiet (instead of a generated one)."""
  for part in callback_context.get_last_user_input():
    if part.text and "no user activity detected" in part.text:
      return LlmResponse.from_parts(parts=[Part.from_text(text=%s)])
  return None
''' % _lit(text), []


def redact_output(p):
    patterns = p.get("patterns") or {
        "card number": r"\b(?:\d[ -]?){13,16}\b",
        "social security number": r"\b\d{3}-\d{2}-\d{4}\b",
    }
    replacement = p.get("replacement", "[removed]")
    return "after_model_callback", HEADER + '''import re


def after_model_callback(
    callback_context: CallbackContext,
    llm_response: LlmResponse
) -> Optional[LlmResponse]:
  """Removes sensitive patterns from what the agent is about to say."""
  PATTERNS = %s
  REPLACEMENT = %s
  changed = False
  parts = []
  for part in llm_response.content.parts:
    if part.text:
      text = part.text
      for pattern in PATTERNS.values():
        text = re.sub(pattern, REPLACEMENT, text)
      if text != part.text:
        changed = True
      parts.append(Part.from_text(text=text))
    else:
      parts.append(part)
  return LlmResponse.from_parts(parts=parts) if changed else None
''' % (repr(patterns), _lit(replacement)), []


def save_transcript_on_end(p):
    tool = p.get("tool", "save_transcript")
    return "after_model_callback", HEADER + '''def after_model_callback(
    callback_context: CallbackContext,
    llm_response: LlmResponse
) -> Optional[LlmResponse]:
  """Just before the call ends, runs the transcript tool so the whole call is saved (Google's 'call a tool on session end' pattern)."""
  SAVE_TOOL = %s
  if llm_response is None or llm_response.content is None or not llm_response.content.parts:
    return None
  parts = list(llm_response.content.parts)
  for part in parts:
    if part.has_function_call(SAVE_TOOL):
      return None          # already there
  for index, part in enumerate(parts):
    if part.has_function_call("end_session"):
      args = part.function_call.args or {}
      reason = str(args.get("reason", ""))
      if args.get("session_escalated"):
        outcome = "escalated"
      elif "verif" in reason.lower():
        outcome = "verification failed"
      elif "tool_failure" in reason or "system" in reason.lower():
        outcome = "system error"
      else:
        outcome = "completed"
      save = Part.from_function_call(name=SAVE_TOOL, args={"outcome": outcome})
      return LlmResponse.from_parts(parts=parts[:index] + [save] + parts[index:])
  return None
''' % _lit(tool), []


def greet_known_caller(p):
    greeting = need(p, "greeting", "callback greet_known_caller")
    unknown = need(p, "greeting_unknown", "callback greet_known_caller")
    tool = p.get("tool", "identify_caller")
    mode = p.get("mode", "direct")
    if mode not in ("direct", "tool_call"):
        raise SpecError("callback greet_known_caller: mode must be 'direct' (the callback runs the tool) or 'tool_call' (it asks for the tool call and greets when the result is back)")
    if "{caller_name}" not in greeting:
        raise SpecError("callback greet_known_caller: params.greeting must contain {caller_name}")
    return "before_model_callback", HEADER + '''import time


def before_model_callback(
    callback_context: CallbackContext,
    llm_request: LlmRequest
) -> Optional[LlmResponse]:
  """At session start: recognises the caller from their phone number (exactly one Salesforce contact), then speaks the greeting, by first name when known.
  Whatever goes wrong, the caller still hears a greeting."""
  GREETING_KNOWN = %s
  GREETING_UNKNOWN = %s
  DISCLAIMER = %s
  LOOKUP_TOOL = %s
  MODE = %s          # direct: this callback runs the tool; tool_call: it asks for the tool call and greets when the result is back

  def _details(res):
    # the tool result may be a dict, a dict wrapped in {"result": ...}, or a response object
    if hasattr(res, "json") and callable(res.json):
      try:
        res = res.json()
      except Exception:
        res = {}
    if isinstance(res, dict) and "caller_status" not in res and isinstance(res.get("result"), dict):
      res = res["result"]
    return res if isinstance(res, dict) else {}

  def _set(key, value):
    try:
      callback_context.set_variable(key, value)
    except Exception as e:
      print("callback: could not set variable", key, type(e).__name__)

  def _greeting(details):
    name = str(details.get("first_name") or "").strip()
    values = {k: v for k, v in callback_context.variables.items() if isinstance(v, (str, int, float, bool))}
    values["caller_name"] = name

    def _fill(text):
      try:
        return text.format(**values)
      except (KeyError, IndexError, ValueError):
        return text

    parts = []
    if DISCLAIMER:
      parts.append(Part.from_customized_response(content=_fill(DISCLAIMER), disable_barge_in=True))
    parts.append(Part.from_text(text=_fill(GREETING_KNOWN if (details.get("caller_status") == "known" and name) else GREETING_UNKNOWN)))
    return LlmResponse.from_parts(parts=parts)

  if MODE == "tool_call":
    for part in llm_request.contents[-1].parts:
      if part.function_response and part.function_response.name == LOOKUP_TOOL:
        return _greeting(_details(part.function_response.response or {}))
  for part in callback_context.get_last_user_input():
    if part.text != "<event>session start</event>":
      continue
    if MODE == "tool_call":
      return LlmResponse.from_parts(parts=[Part.from_function_call(name=LOOKUP_TOOL, args={})])
    try:
      started = time.time()
      details = {}
      try:
        details = _details(getattr(tools, LOOKUP_TOOL)({"include_details": True}))
      except Exception as e:
        print("callback: caller lookup failed:", type(e).__name__)
      print("callback: caller lookup took", round(time.time() - started, 2), "seconds")
      known = details.get("caller_status") == "known"
      _set("caller_status", "known" if known else "unknown")
      if known:
        _set("caller_name", str(details.get("first_name") or ""))
        _set("caller_email", str(details.get("email") or ""))
        _set("caller_contact_id", str(details.get("contact_id") or ""))
        _set("caller_account_id", str(details.get("account_id") or ""))
      return _greeting(details)
    except Exception as e:
      print("callback: fell back to the plain greeting:", type(e).__name__)
      return _greeting({})
  return None
''' % (_lit(greeting), _lit(unknown), _lit(p.get("disclaimer", "")), _lit(tool), _lit(mode)), []


def hide_tools(p):
    tools = p.get("tools") or []
    if not tools:
        raise SpecError("callback hide_tools needs params.tools (the tool names to keep away from the model)")
    return "before_model_callback", HEADER + '''def before_model_callback(
    callback_context: CallbackContext,
    llm_request: LlmRequest
) -> Optional[LlmResponse]:
  """Keeps internal tools out of the model's view; callbacks and other tools can still run them."""
  for tool_name in %s:
    llm_request.config.hide_tool(tool_name)
  return None
''' % repr(list(tools)), []


TEMPLATES = {
    "static_greeting": static_greeting,
    "mandatory_text": mandatory_text,
    "escalate_on_system_error": escalate_on_system_error,
    "inactivity_prompt": inactivity_prompt,
    "redact_output": redact_output,
    "save_transcript_on_end": save_transcript_on_end,
    "hide_tools": hide_tools,
    "greet_known_caller": greet_known_caller,
}


def render_callback(spec, where):
    """spec: {template, params, description}. Returns (type_function_name, source, extra_variables)."""
    t = spec.get("template")
    if t not in TEMPLATES:
        raise SpecError("%s: unknown callback template '%s' (available: %s)" % (where, t, ", ".join(sorted(TEMPLATES))))
    fn, src, variables = TEMPLATES[t](spec.get("params", {}))
    try:
        ast.parse(src)
    except SyntaxError as e:
        raise SpecError("%s: generated callback does not compile: %s" % (where, e))
    return fn, src, variables
