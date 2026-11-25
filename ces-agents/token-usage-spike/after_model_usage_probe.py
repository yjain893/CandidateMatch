from typing import Optional

def after_model_callback(
    callback_context: CallbackContext,
    llm_response: LlmResponse
) -> Optional[LlmResponse]:
  """SPIKE 2: records what the last few session events (callback_context.events) expose, looking for token usage. Never changes the reply."""
  try:
    def names(obj):
      return sorted(n for n in dir(obj) if not n.startswith("_") and n not in (
        "construct", "copy", "dict", "from_orm", "json", "parse_file", "parse_obj", "parse_raw", "schema", "schema_json",
        "update_forward_refs", "validate", "model_computed_fields", "model_config", "model_construct", "model_copy",
        "model_dump", "model_dump_json", "model_extra", "model_fields", "model_fields_set", "model_json_schema",
        "model_parametrized_name", "model_post_init", "model_rebuild", "model_validate", "model_validate_json",
        "model_validate_strings"))

    def describe(label, obj):
      out = [label + " type " + type(obj).__name__]
      if isinstance(obj, dict):
        out.append(label + " keys " + ",".join(sorted(str(k) for k in obj.keys()))[:400])
        for k, v in obj.items():
          low = str(k).lower()
          if "usage" in low or "token" in low or "meta" in low:
            out.append(label + "[" + str(k) + "] = " + repr(v)[:300])
        return out
      out.append(label + " attrs " + ",".join(names(obj))[:500])
      for n in names(obj):
        low = n.lower()
        if "usage" in low or "token" in low or "meta" in low:
          try:
            out.append(label + "." + n + " = " + repr(getattr(obj, n))[:300])
          except Exception as e:
            out.append(label + "." + n + " unreadable " + type(e).__name__)
      try:
        out.append(label + " dump " + obj.model_dump_json()[:600])
      except Exception:
        pass
      return out

    lines = []
    events = callback_context.events
    try:
      count = len(events)
    except Exception:
      count = -1
    lines.append("events type " + type(events).__name__ + " count " + str(count))
    try:
      last = list(events)[-3:]
    except Exception as e:
      last = []
      lines.append("events not iterable " + type(e).__name__)
    for i, ev in enumerate(last):
      lines += describe("event[-" + str(len(last) - i) + "]", ev)
    for name in ("state", "actions"):
      try:
        lines += describe("callback_context." + name, getattr(callback_context, name))
      except Exception as e:
        lines.append(name + " unreadable " + type(e).__name__)
    previous = str(callback_context.variables.get("usage_probe") or "")
    turn = previous.count("=== TURN") + 1
    report = "=== TURN " + str(turn) + " === " + " | ".join(lines)
    callback_context.set_variable("usage_probe", (previous + "\n" + report)[-6000:])
  except Exception as e:
    try:
      callback_context.set_variable("usage_probe", "PROBE FAILED " + type(e).__name__ + " " + str(e)[:200])
    except Exception:
      pass
  return None
