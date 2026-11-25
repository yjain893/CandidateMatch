from typing import Optional

def after_model_callback(
    callback_context: CallbackContext,
    llm_response: LlmResponse
) -> Optional[LlmResponse]:
  """Adds the estimated output and voice tokens of this reply to the running totals. Only measures: never changes the reply. Keep it FIRST in the after-model list."""
  CHARS_PER_TOKEN_OUT = 3.5      # calibrate against the real output token count in the logs
  CHARS_PER_TOKEN_TTS = 3.0      # letters spoken / real voice input tokens
  WORDS_PER_SECOND = 2.2             # speaking speed of the voice
  TTS_TOKENS_PER_SECOND = 25.0        # voice output tokens per second of sound
  DEBUG = True
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
