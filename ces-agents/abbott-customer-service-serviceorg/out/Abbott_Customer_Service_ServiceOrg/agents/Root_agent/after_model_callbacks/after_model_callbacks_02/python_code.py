from typing import Optional

def after_model_callback(
    callback_context: CallbackContext,
    llm_response: LlmResponse
) -> Optional[LlmResponse]:
  """Just before the call ends, runs the transcript tool so the whole call is saved (Google's 'call a tool on session end' pattern)."""
  SAVE_TOOL = 'save_transcript'
  CLOSING = {'completed': 'Thanks for reaching out to us. Have a good day.', 'verification failed': "I'm sorry, I'm not able to verify you today. Thank you for calling. Goodbye.", 'escalated': "I'm connecting you with a team member now."}          # outcome -> words to add when the model ends the call without saying anything
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
