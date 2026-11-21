from typing import Optional

def before_model_callback(
    callback_context: CallbackContext,
    llm_request: LlmRequest
) -> Optional[LlmResponse]:
  """Keeps internal tools out of the model's view; callbacks and other tools can still run them."""
  for tool_name in ['save_transcript']:
    llm_request.config.hide_tool(tool_name)
  return None
