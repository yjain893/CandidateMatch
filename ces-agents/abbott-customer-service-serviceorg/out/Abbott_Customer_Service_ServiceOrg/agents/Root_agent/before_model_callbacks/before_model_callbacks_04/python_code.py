from typing import Optional

def before_model_callback(
    callback_context: CallbackContext,
    llm_request: LlmRequest
) -> Optional[LlmResponse]:
  """Counts the letters in what is about to be sent to the model and adds the estimated input tokens to a running total. Only measures: never changes the request."""
  CHARS_PER_TOKEN = 3.5          # calibrate: letters in the request / real input tokens from the logs
  FIXED_OVERHEAD_CHARS = 0    # letters the model reads that this callback cannot see (set while calibrating)
  DEBUG = True
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
