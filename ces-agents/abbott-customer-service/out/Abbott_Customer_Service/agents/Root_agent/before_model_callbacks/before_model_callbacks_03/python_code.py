from typing import Optional

def before_model_callback(
    callback_context: CallbackContext,
    llm_request: LlmRequest
) -> Optional[LlmResponse]:
  """Fixed reply when the caller goes quiet (instead of a generated one)."""
  for part in callback_context.get_last_user_input():
    if part.text and "no user activity detected" in part.text:
      return LlmResponse.from_parts(parts=[Part.from_text(text='Are you still there?')])
  return None
