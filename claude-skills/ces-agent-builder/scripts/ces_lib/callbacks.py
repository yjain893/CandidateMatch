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
    closing = p.get("closing_texts") or {}
    for key in closing:
        if key not in ("completed", "escalated", "verification failed", "system error"):
            raise SpecError("callback save_transcript_on_end: closing_texts key '%s' must be one of completed, escalated, verification failed, system error" % key)
    return "after_model_callback", HEADER + '''def after_model_callback(
    callback_context: CallbackContext,
    llm_response: LlmResponse
) -> Optional[LlmResponse]:
  """Just before the call ends, runs the transcript tool so the whole call is saved (Google's 'call a tool on session end' pattern)."""
  SAVE_TOOL = %s
  CLOSING = %s          # outcome -> words to add when the model ends the call without saying anything
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
      before = parts[:index]
      spoken = any((p.text or "").strip() for p in parts if p.text)
      if CLOSING.get(outcome) and not spoken:
        before = before + [Part.from_text(text=CLOSING[outcome])]
      save = Part.from_function_call(name=SAVE_TOOL, args={"outcome": outcome})
      return LlmResponse.from_parts(parts=before + [save] + parts[index:])
  return None
''' % (_lit(tool), repr(dict(closing))), []


def greet_known_caller(p):
    speak = p.get("speak", "model")
    if speak not in ("model", "callback"):
        raise SpecError("callback greet_known_caller: speak must be 'model' (the callback only looks the caller up and the agent says the greeting from its instructions: this is what a voice call needs) or 'callback' (the callback speaks the greeting itself: it shows as text but was not voiced in practice)")
    greeting = need(p, "greeting", "callback greet_known_caller") if speak == "callback" else p.get("greeting", "")
    unknown = need(p, "greeting_unknown", "callback greet_known_caller") if speak == "callback" else p.get("greeting_unknown", "")
    tool = p.get("tool", "identify_caller")
    mode = p.get("mode", "direct")
    tell = bool(p.get("tell_model", False))
    if mode not in ("direct", "tool_call"):
        raise SpecError("callback greet_known_caller: mode must be 'direct' (the callback runs the tool) or 'tool_call' (it asks for the tool call and greets when the result is back)")
    if speak == "callback" and "{caller_name}" not in greeting:
        raise SpecError("callback greet_known_caller: params.greeting must contain {caller_name}")
    return "before_model_callback", HEADER + '''import time


def before_model_callback(
    callback_context: CallbackContext,
    llm_request: LlmRequest
) -> Optional[LlmResponse]:
  """At session start: recognises the caller from their phone number (exactly one Salesforce contact) and stores who they are in variables.
  With SPEAK model the agent then says the greeting from its instructions; with SPEAK callback this callback speaks it (that shows as text but was not voiced on a call).
  Whatever goes wrong, the call carries on and the caller still gets a greeting."""
  GREETING_KNOWN = %s
  GREETING_UNKNOWN = %s
  DISCLAIMER = %s
  LOOKUP_TOOL = %s
  MODE = %s          # direct: this callback runs the tool; tool_call: it asks for the tool call and carries on when the result is back
  SPEAK = %s         # model: the agent says the greeting from its instructions; callback: this callback speaks it
  CUE = %s           # told to the model on the first turn so that it speaks first
  TELL = %s          # True: also write the caller into the model's request (off by default: a before-agent callback already stores the caller)

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

  def _tell_model(details):
    # changes a before-model callback makes to variables reach the model only on its NEXT turn, because this turn's request is already built:
    # so the caller is also written into the request itself, in the form the platform uses for variable changes
    known = details.get("caller_status") == "known"
    name = str(details.get("first_name") or "").strip()
    note = "<state_update>caller_status: " + ("known" if known else "unknown") + "</state_update>"
    if known and name:
      note += "<state_update>caller_name: " + name + "</state_update>"
    try:
      llm_request.contents[-1].parts.append(Part.from_text(text=note))
    except Exception as e:
      print("callback: could not add the caller note to the request:", type(e).__name__)

  def _first_turn():
    # nobody has spoken yet: no agent words and no real caller words (events, state updates and notes do not count)
    for ev in list(getattr(callback_context, "events", None) or []):
      for part in (getattr(getattr(ev, "content", None), "parts", None) or []):
        try:
          text = str(part.text_or_transcript() or "").strip()
        except Exception:
          text = str(getattr(part, "text", "") or "").strip()
        if not text:
          continue
        is_user = ev.is_user() if hasattr(ev, "is_user") else str(getattr(ev, "author", "")) == "user"
        if not is_user:
          return False
        if not text.startswith(("<event>", "<state_update>", "<context>")):
          return False
    return True

  def _cue():
    # the model only speaks first when it is clearly told to
    try:
      llm_request.contents[-1].parts.append(Part.from_text(text=CUE))
    except Exception as e:
      print("callback: could not add the greeting cue to the request:", type(e).__name__)

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
        return _greeting(_details(part.function_response.response or {})) if SPEAK == "callback" else None
  at_start = any(part.text == "<event>session start</event>" for part in callback_context.get_last_user_input()) or _first_turn()
  for _once in ([1] if at_start else []):
    if MODE == "tool_call":
      return LlmResponse.from_parts(parts=[Part.from_function_call(name=LOOKUP_TOOL, args={})])
    try:
      status = str(callback_context.variables.get("caller_status") or "")
      if status:
        # a before-agent callback already looked the caller up
        details = {"caller_status": status, "first_name": str(callback_context.variables.get("caller_name") or "")}
      else:
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
      if SPEAK == "callback":
        return _greeting(details)
      if TELL:
        _tell_model(details)
      _cue()
      return None
    except Exception as e:
      print("callback: carried on without the lookup:", type(e).__name__)
      return _greeting({}) if SPEAK == "callback" else None
  return None
''' % (_lit(greeting), _lit(unknown), _lit(p.get("disclaimer", "")), _lit(tool), _lit(mode), _lit(speak), _lit(p.get("speak_cue", "The caller has just connected and has not said anything yet. Greet them now, exactly as your instructions say, without waiting for them to speak.")), repr(tell)), []


def lookup_caller_on_start(p):
    tool = p.get("tool", "identify_caller")
    return "before_agent_callback", HEADER + '''import time


def before_agent_callback(
    callback_context: CallbackContext
) -> Optional[Content]:
  """Before the agent's first turn: recognises the caller from their phone number (exactly one Salesforce contact) and stores who they are in variables,
  so the agent already knows the name when it speaks first. Runs once per call; whatever goes wrong, the call carries on."""
  LOOKUP_TOOL = %s

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

  if callback_context.variables.get("caller_status"):
    return None          # already looked up on this call
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
  return None
''' % _lit(tool), []


TOKEN_VARIABLES = [
    {"name": "tokens_in_est", "type": "NUMBER", "default": 0, "description": "Estimated tokens the model read on this call (letters / chars_per_token)."},
    {"name": "tokens_out_est", "type": "NUMBER", "default": 0, "description": "Estimated tokens the model wrote on this call."},
    {"name": "tts_in_est", "type": "NUMBER", "default": 0, "description": "Estimated tokens of text sent to the voice on this call."},
    {"name": "tts_out_est", "type": "NUMBER", "default": 0, "description": "Estimated tokens of sound produced by the voice on this call."},
    {"name": "tokens_total_est", "type": "NUMBER", "default": 0, "description": "Sum of the four estimates above."},
]
TOKEN_DEBUG_VARIABLE = {"name": "token_calibration", "type": "STRING", "default": "", "description": "Calibration log: letter counts per model call. Only while token_estimate debug is on."}


def _num(p, key, default):
    try:
        v = float(p.get(key, default))
    except (TypeError, ValueError):
        raise SpecError("token estimate: %s must be a number" % key)
    if v <= 0:
        raise SpecError("token estimate: %s must be greater than zero" % key)
    return v


def token_count_input(p):
    cpt = _num(p, "chars_per_token_in", 3.5)
    overhead = int(float(p.get("fixed_overhead_chars", 0)))
    debug = bool(p.get("debug", False))
    src = HEADER + """def before_model_callback(
    callback_context: CallbackContext,
    llm_request: LlmRequest
) -> Optional[LlmResponse]:
  \"\"\"Counts the letters in what is about to be sent to the model and adds the estimated input tokens to a running total. Only measures: never changes the request.\"\"\"
  CHARS_PER_TOKEN = __CPT__          # calibrate: letters in the request / real input tokens from the logs
  FIXED_OVERHEAD_CHARS = __OVERHEAD__    # letters the model reads that this callback cannot see (set while calibrating)
  DEBUG = __DEBUG__
  try:
    def _len(value):
      return len(str(value)) if value is not None else 0

    def _part(part):
      n = _len(getattr(part, "text", None))
      call = getattr(part, "function_call", None)
      if call:
        n += _len(getattr(call, "name", None)) + _len(getattr(call, "args", None))
      reply = getattr(part, "function_response", None)
      if reply:
        n += _len(getattr(reply, "name", None)) + _len(getattr(reply, "response", None))
      return n

    def _content(content):
      if content is None:
        return 0
      if isinstance(content, str):
        return len(content)
      return sum(_part(x) for x in (getattr(content, "parts", None) or []))

    conversation = sum(_content(c) for c in (getattr(llm_request, "contents", None) or []))
    config = getattr(llm_request, "config", None)
    instruction = _content(getattr(config, "system_instruction", None)) if config is not None else 0
    tool_defs = 0
    if config is not None:
      for tool in (getattr(config, "tools", None) or []):
        tool_defs += _len(tool)
    letters = conversation + instruction + tool_defs + FIXED_OVERHEAD_CHARS
    tokens = int(round(letters / CHARS_PER_TOKEN))
    callback_context.set_variable("tokens_in_est", int(callback_context.variables.get("tokens_in_est") or 0) + tokens)
    if DEBUG:
      note = "IN conv=%d instr=%d tools=%d fixed=%d est=%d" % (conversation, instruction, tool_defs, FIXED_OVERHEAD_CHARS, tokens)
      previous = str(callback_context.variables.get("token_calibration") or "")
      callback_context.set_variable("token_calibration", (previous + " | " + note)[-1500:])
  except Exception as e:
    print("callback: token count failed:", type(e).__name__)
  return None
"""
    src = src.replace("__CPT__", repr(cpt)).replace("__OVERHEAD__", repr(overhead)).replace("__DEBUG__", repr(debug))
    return "before_model_callback", src, TOKEN_VARIABLES + ([TOKEN_DEBUG_VARIABLE] if debug else [])


def token_count_output(p):
    cpt_out = _num(p, "chars_per_token_out", 3.5)
    cpt_tts = _num(p, "chars_per_token_tts", 3.0)
    wps = _num(p, "words_per_second", 2.2)
    tps = _num(p, "tts_tokens_per_second", 25.0)
    debug = bool(p.get("debug", False))
    src = HEADER + """def after_model_callback(
    callback_context: CallbackContext,
    llm_response: LlmResponse
) -> Optional[LlmResponse]:
  \"\"\"Adds the estimated output and voice tokens of this reply to the running totals. Only measures: never changes the reply. Keep it FIRST in the after-model list.\"\"\"
  CHARS_PER_TOKEN_OUT = __CPT_OUT__      # calibrate against the real output token count in the logs
  CHARS_PER_TOKEN_TTS = __CPT_TTS__      # letters spoken / real voice input tokens
  WORDS_PER_SECOND = __WPS__             # speaking speed of the voice
  TTS_TOKENS_PER_SECOND = __TPS__        # voice output tokens per second of sound
  DEBUG = __DEBUG__
  try:
    if llm_response is None or llm_response.content is None or not llm_response.content.parts:
      return None
    if getattr(llm_response, "partial", False):
      return None
    spoken = []
    written = 0
    for part in llm_response.content.parts:
      text = getattr(part, "text", None)
      if text:
        written += len(text)
        spoken.append(text)
      call = getattr(part, "function_call", None)
      if call:
        written += len(str(getattr(call, "name", "") or "")) + len(str(getattr(call, "args", "") or ""))
    spoken_text = " ".join(spoken)
    words = len(spoken_text.split())
    out_tokens = int(round(written / CHARS_PER_TOKEN_OUT))
    tts_in = int(round(len(spoken_text) / CHARS_PER_TOKEN_TTS))
    tts_out = int(round(words / WORDS_PER_SECOND * TTS_TOKENS_PER_SECOND))

    def _add(name, amount):
      total = int(callback_context.variables.get(name) or 0) + amount
      callback_context.set_variable(name, total)
      return total

    _add("tokens_out_est", out_tokens)
    _add("tts_in_est", tts_in)
    _add("tts_out_est", tts_out)
    callback_context.set_variable("tokens_total_est", sum(int(callback_context.variables.get(n) or 0) for n in ("tokens_in_est", "tokens_out_est", "tts_in_est", "tts_out_est")))
    if DEBUG:
      note = "OUT written=%d spoken=%d words=%d out=%d tts_in=%d tts_out=%d" % (written, len(spoken_text), words, out_tokens, tts_in, tts_out)
      previous = str(callback_context.variables.get("token_calibration") or "")
      callback_context.set_variable("token_calibration", (previous + " | " + note)[-1500:])
  except Exception as e:
    print("callback: token count failed:", type(e).__name__)
  return None
"""
    src = (src.replace("__CPT_OUT__", repr(cpt_out)).replace("__CPT_TTS__", repr(cpt_tts)).replace("__WPS__", repr(wps))
              .replace("__TPS__", repr(tps)).replace("__DEBUG__", repr(debug)))
    return "after_model_callback", src, []


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
    "lookup_caller_on_start": lookup_caller_on_start,
    "token_count_input": token_count_input,
    "token_count_output": token_count_output,
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
