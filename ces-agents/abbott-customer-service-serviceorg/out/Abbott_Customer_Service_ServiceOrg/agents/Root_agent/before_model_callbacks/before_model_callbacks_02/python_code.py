from typing import Optional

def before_model_callback(
    callback_context: CallbackContext,
    llm_request: LlmRequest
) -> Optional[LlmResponse]:
  """When a tool reports a system error, stop immediately instead of letting the model improvise."""
  WATCHED = ['get_order_status', 'get_shipping_address', 'update_shipping_address']          # empty list means every tool
  MESSAGE = "I'm sorry, I can't reach our order system right now. Let me connect you with a team member."
  ESCALATE = True
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
