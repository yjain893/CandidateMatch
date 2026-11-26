from typing import Optional

import time


def before_agent_callback(
    callback_context: CallbackContext
) -> Optional[Content]:
  """Before the agent's first turn: recognises the caller from their phone number (exactly one Salesforce contact) and stores who they are in variables,
  so the agent already knows the name when it speaks first. Runs once per call; whatever goes wrong, the call carries on."""
  LOOKUP_TOOL = 'identify_caller'

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
