def spike_echo() -> dict:
  """Spike test tool. Sets a variable and returns a tiny result. Not part of the real agent."""
  context.variables["spike_var"] = "set-by-tool"
  return {"ok": True, "hello": "from the tool"}
