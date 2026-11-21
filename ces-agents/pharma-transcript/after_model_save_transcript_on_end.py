from typing import Optional

def after_model_callback(
    callback_context: CallbackContext,
    llm_response: LlmResponse
) -> Optional[LlmResponse]:
  """Just before the call ends, runs the transcript tool so the whole call is saved (Google's 'call a tool on session end' pattern)."""
  SAVE_TOOL = 'save_transcript'
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
      elif "tool_failure" in reason or "system" in reason.lower():
        outcome = "system error"
      else:
        outcome = "completed"
      save = Part.from_function_call(name=SAVE_TOOL, args={"outcome": outcome})
      return LlmResponse.from_parts(parts=parts[:index] + [save] + parts[index:])
  return None
