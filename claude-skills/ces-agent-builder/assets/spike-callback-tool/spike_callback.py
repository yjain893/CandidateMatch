from typing import Optional

def before_model_callback(
    callback_context: CallbackContext,
    llm_request: LlmRequest
) -> Optional[LlmResponse]:
  """SPIKE: at session start, reports what a callback is allowed to do, so we know before building the real agent."""
  for part in callback_context.get_last_user_input():
    if part.text != "<event>session start</event>":
      continue
    report = []
    try:
      res = tools.spike_echo({})
      report.append("tools works, result type " + type(res).__name__)
      if isinstance(res, dict):
        report.append("result keys " + ",".join(sorted(res.keys())))
    except Exception as e:
      report.append("tools FAILED with " + type(e).__name__ + " " + str(e)[:80])
    report.append("variable written by the tool reads as " + str(callback_context.variables.get("spike_var")))
    callback_context.set_variable("spike_cb_var", "set-by-callback")
    report.append("variable set by the callback reads as " + str(callback_context.variables.get("spike_cb_var")))
    caller_id = str(callback_context.variables.get("telephony-caller-id") or "")
    report.append("caller id present " + str(bool(caller_id)) + ", last four digits " + caller_id[-4:])
    return LlmResponse.from_parts(parts=[Part.from_text(text="Spike result. " + ". ".join(report) + ".")])
  return None
