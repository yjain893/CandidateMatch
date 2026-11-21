def verify_caller_email(email: str) -> dict:
  """Verifies the caller by comparing the email address they give with the email on their Salesforce contact. Call it once the caller has said their email address. If verified is true, the caller may be helped with their orders. If verified is false, do not share anything.

  Args:
    email: The email address exactly as the caller said it, including spoken words such as "at" and "dot".

  Returns:
    dict: verified (true or false) and a message. If error is not_verified, tell the caller the email could not be verified and ask for another (see attempts_remaining). If error is locked_out, stop and end the call politely. If error is invalid_input, ask the caller to say the email again.
  """
  # ---- org settings (generated from the spec: change them there, not here) ----
  CONNECTOR_TOOL = 'query_salesforce_find_order'   # when set, Salesforce is reached through the Salesforce connector tool (platform OAuth)
  CFG = {'max_attempts': 3, 'email_variable': 'caller_email'}
  ARGS = {"email": email}

  def _soql_text(value):
    # escape a text value so it is safe between single quotes in SOQL
    return str(value).replace("\\", "\\\\").replace("'", "\\'")

  def _fail(error, message, system=False, **extra):
    out = {"ok": False, "error": error, "message": message}
    if system:
      out["system_error"] = True
    out.update(extra)
    return out

  def _check_value(spec, value):
    # returns (clean_value, error_message)
    kind = spec.get("type", "string")
    if kind in ("string", "text", "phone", "email"):
      text = str(value).strip()
      limit = int(spec.get("max_length", 255))
      if len(text) > limit:
        return None, "too long (maximum %d characters)" % limit
      return text, None
    if kind == "number":
      try:
        num = float(value)
      except (TypeError, ValueError):
        return None, "must be a number"
      return (int(num) if num == int(num) else num), None
    if kind == "boolean":
      if isinstance(value, bool):
        return value, None
      text = str(value).strip().lower()
      if text in ("true", "yes", "1"):
        return True, None
      if text in ("false", "no", "0"):
        return False, None
      return None, "must be true or false"
    if kind == "date":
      text = str(value).strip()
      parts = text.split("-")
      if len(parts) == 3 and len(parts[0]) == 4 and parts[0].isdigit() and parts[1].isdigit() and parts[2].isdigit():
        return text, None
      return None, "must be a date like 2026-11-28"
    if kind == "picklist":
      allowed = spec.get("allowed") or []
      for item in allowed:
        if str(item).lower() == str(value).strip().lower():
          return item, None
      return None, "must be one of: " + ", ".join(str(a) for a in allowed)
    return str(value).strip(), None

  import re

  def _spoken_to_email(text):
    # "john dot smith at gmail dot com", "john at the rate gmail dot com", "j o h n at gmail dot com" -> john.smith@gmail.com
    words = str(text or "").lower().replace(",", " ").split()
    out, i = [], 0
    while i < len(words):
      w = words[i]
      if w == "at" and words[i + 1:i + 3] == ["the", "rate"]:
        out.append("@")
        i += 3
        if words[i:i + 1] == ["of"]:
          i += 1
        continue
      if w == "at" and words[i + 1:i + 2] == ["sign"]:
        out.append("@")
        i += 2
        continue
      out.append({"at": "@", "dot": ".", "underscore": "_", "dash": "-", "hyphen": "-", "plus": "+"}.get(w, w))
      i += 1
    return "".join(out).strip(".")

  def _valid(address):
    return re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", address) is not None

  try:
    attempts = int(context.variables.get("verification_attempts") or 0)
    max_attempts = int(CFG["max_attempts"])
    if attempts >= max_attempts:
      return {"verified": False, "ok": False, "error": "locked_out", "message": "Too many failed attempts."}
    heard = _spoken_to_email(ARGS["email"])
    if not _valid(heard):
      # not counted as a try: nothing was compared
      return {"verified": False, "ok": False, "error": "invalid_input", "message": "That does not sound like a complete email address. Ask the caller to say it again."}
    stored = str(context.variables.get(CFG["email_variable"]) or "").strip().lower()
    known = context.variables.get("caller_status") == "known"
    # a blank stored address, or a caller who was not recognised, never matches
    if not known or not stored or stored != heard:
      count = attempts + 1
      context.variables["verification_attempts"] = count
      return {"verified": False, "ok": False, "error": "not_verified", "message": "That email address does not match our records.",
              "attempts_remaining": max(max_attempts - count, 0)}
    context.variables["caller_verified"] = True
    context.variables["verification_attempts"] = 0
    return {"verified": True, "ok": True, "message": "The caller is verified."}
  except Exception as e:
    print("tool: unexpected error:", type(e).__name__, str(e)[:200])
    return {"verified": False, "ok": False, "error": "tool_error", "system_error": True,
            "message": "The request could not be completed right now."}
