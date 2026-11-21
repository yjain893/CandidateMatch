from typing import Optional

import time


def before_model_callback(
    callback_context: CallbackContext,
    llm_request: LlmRequest
) -> Optional[LlmResponse]:
  """At session start: recognises the caller from their phone number (exactly one Salesforce contact) and stores who they are in variables.
  With SPEAK model the agent then says the greeting from its instructions; with SPEAK callback this callback speaks it (that shows as text but was not voiced on a call).
  Whatever goes wrong, the call carries on and the caller still gets a greeting."""
  GREETING_KNOWN = ''
  GREETING_UNKNOWN = ''
  DISCLAIMER = ''
  LOOKUP_TOOL = 'identify_caller'
  MODE = 'direct'          # direct: this callback runs the tool; tool_call: it asks for the tool call and carries on when the result is back
  SPEAK = 'model'         # model: the agent says the greeting from its instructions; callback: this callback speaks it

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
  for part in callback_context.get_last_user_input():
    if part.text != "<event>session start</event>":
      continue
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
      _tell_model(details)
      return None
    except Exception as e:
      print("callback: carried on without the lookup:", type(e).__name__)
      return _greeting({}) if SPEAK == "callback" else None
  return None
