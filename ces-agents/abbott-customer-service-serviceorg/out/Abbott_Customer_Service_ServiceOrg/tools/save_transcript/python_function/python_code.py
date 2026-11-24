def save_transcript(outcome: str = "") -> dict:
  """Saves the transcript of this call to Salesforce. It runs automatically when the call ends. Do not call it yourself.

  Args:
    outcome: How the call ended: completed, escalated or system error. The end-of-call hook fills this in; leave it empty otherwise.

  Returns:
    dict: ok and a message. If system_error is true the transcript was not saved.
  """
  # ---- org settings (generated from the spec: change them there, not here) ----
  INSTANCE_URL = 'https://app-momentum-4398--dev.sandbox.my.salesforce.com'
  API_VERSION = 'v68.0'
  TOKEN_VARIABLE = 'salesforce_access_token'
  CONNECTOR_TOOL = 'query_salesforce_save_transcript'   # when set, Salesforce is reached through the Salesforce connector tool (platform OAuth)
  CFG = {'sobject': 'Chat_Conversation__c',
     'external_id_field': 'Conversation_Identifier__c',
     'fields': {'transcript': 'Transcript__c',
                'started_at': 'Start_Timestamp__c',
                'ended_at': 'End_Timestamp__c',
                'closed_at': 'Closed_At__c',
                'last_message_at': 'Last_Message_At__c',
                'turn_count': 'Message_Count__c',
                'has_human_agent': 'Has_Human_Agent__c'},
     'links': {},
     'fixed_values': {'Conversation_Status__c': 'Closed'},
     'redact_patterns': {'card number': '\\b(?:\\d[ -]?){13,16}\\b',
                         'social security number': '\\b\\d{3}-\\d{2}-\\d{4}\\b'},
     'max_chars': 120000,
     'max_attempts': 3,
     'path_param': 'session_id',
     'connector_tool': 'query_salesforce_save_transcript'}
  ARGS = {"outcome": outcome}

  def _fail(error, message, system=False, **extra):
    out = {"ok": False, "error": error, "message": message}
    if system:
      out["system_error"] = True
    out.update(extra)
    return out

  def _request(method, path, params=None, body=None):
    token = str(context.variables.get(TOKEN_VARIABLE) or "").strip()
    if not token:
      print("tool: variable", TOKEN_VARIABLE, "is empty")
      return None, _fail("token_missing", "The system is not connected right now.", system=True)
    headers = {"Authorization": "Bearer " + token, "Accept": "application/json"}
    url = INSTANCE_URL + "/services/data/" + API_VERSION + path
    if method == "GET":
      resp = ces_requests.get(url, params=params, headers=headers)
    else:
      headers["Content-Type"] = "application/json"
      if method == "POST":
        resp = ces_requests.post(url, json=body, headers=headers)
      else:
        resp = ces_requests.patch(url, json=body, headers=headers)
    if resp.status_code == 401:
      print("tool: Salesforce rejected the access token (401)")
      return None, _fail("salesforce_auth_failed", "The system is not available right now.", system=True)
    if resp.status_code >= 400:
      print("tool: Salesforce returned status", resp.status_code)
      return None, _fail("salesforce_error", "The system is not available right now.", system=True, code=resp.status_code)
    return resp, None

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

  import datetime
  import re
  import urllib.parse

  def _epoch_iso(value):
    # session event times are seconds, milliseconds or microseconds since 1970; anything else is ignored
    try:
      num = float(value)
    except (TypeError, ValueError):
      return None
    if num > 1e14:
      num = num / 1e6
    elif num > 1e11:
      num = num / 1e3
    if num < 1e9:
      return None
    return datetime.datetime.fromtimestamp(num, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

  def _seconds_between(first, last):
    try:
      a = datetime.datetime.strptime(first, "%Y-%m-%dT%H:%M:%SZ")
      b = datetime.datetime.strptime(last, "%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError):
      return None
    return max(int((b - a).total_seconds()), 0)

  def _redact(text):
    for pattern in (CFG.get("redact_patterns") or {}).values():
      text = re.sub(pattern, "[removed]", text)
    return text

  def _clean(text):
    # the platform adds notes such as <context>agent speaking was interrupted ...</context> to caller turns; they are not the caller's words
    text = re.sub(r"<context>.*?</context>", " ", str(text), flags=re.S)
    return " ".join(text.split())

  def _collect():
    # caller and agent turns, one per line; tool calls, tool results and system events are left out
    lines, first, last, turns = [], None, None, 0
    for ev in list(getattr(context, "events", None) or []):
      parts = getattr(getattr(ev, "content", None), "parts", None) or []
      texts = []
      for part in parts:
        try:
          text = part.text_or_transcript()
        except Exception:
          text = getattr(part, "text", None)
        text = _clean(text) if text else ""
        if text and not text.startswith("<event>"):
          texts.append(text)
      if not texts:
        continue
      is_user = ev.is_user() if hasattr(ev, "is_user") else str(getattr(ev, "author", "")) == "user"
      if is_user:
        turns += 1
      lines.append(("Caller: " if is_user else "Agent: ") + " ".join(texts))
      stamp = _epoch_iso(getattr(ev, "timestamp", None))
      if stamp:
        first = first or stamp
        last = stamp
    return lines, first, last, turns

  def _outcome(hint):
    word = str(hint or "").lower()
    if "escalat" in word:
      return "Escalated"
    if "verif" in word:
      return "Verification failed"
    if "system" in word or "tool_failure" in word:
      return "System error"
    if "complet" in word or context.variables.get("caller_verified"):
      return "Completed"
    if int(context.variables.get("verification_attempts") or 0) >= int(CFG.get("max_attempts", 3)):
      return "Verification failed"
    return "Unknown"

  def _save_through_connector(session_id, body):
    # How the connector maps a request body is not documented, so three argument shapes are tried in turn
    path_arg = {CFG.get("path_param", "session_id"): session_id}
    shapes = [dict(path_arg, **body), dict(path_arg, body=body), dict(path_arg, requestBody=body)]
    status, detail = None, ""
    for index, args in enumerate(shapes):
      try:
        res = getattr(tools, CFG["connector_tool"])(args)
      except Exception as e:
        status, detail = getattr(e, "status_code", None), str(e)[:300]
        print("tool: connector call failed with argument shape", index, type(e).__name__, status)
        if status == 401:
          break
        continue
      status = getattr(res, "status_code", 200)
      if not isinstance(status, int) or status < 400:
        print("tool: transcript saved through the connector with argument shape", index)
        return None
      detail = str(getattr(res, "text", ""))[:300]
      print("tool: connector returned", status, "for argument shape", index)
      if status == 401:
        break
    kind = "salesforce_auth_failed" if status == 401 else "salesforce_error"
    return _fail(kind, "The transcript could not be saved.", system=True, code=status, detail=detail)

  try:
    session_id = str(getattr(context, "session_id", "") or "").strip()
    if not session_id:
      return _fail("invalid_input", "There is no session id to save the transcript under.")
    lines, first, last, turns = _collect()
    if not lines:
      return _fail("empty_transcript", "There was nothing to save.")
    text = _redact("\n".join(lines))
    limit = int(CFG.get("max_chars", 120000))
    if len(text) > limit:
      text = text[:limit] + "\n[transcript truncated]"
    names = CFG["fields"]
    body = {}

    def put(key, value):
      if names.get(key) and value is not None:
        body[names[key]] = value

    ended = last or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    put("transcript", text)
    put("started_at", first)
    put("ended_at", ended)
    put("duration_seconds", _seconds_between(first, ended) if first else None)
    put("turn_count", turns)
    put("caller_verified", bool(context.variables.get("caller_verified")))
    outcome = _outcome(ARGS.get("outcome"))
    put("outcome", outcome)
    put("closed_at", ended)
    put("last_message_at", last or ended)
    put("has_human_agent", outcome == "Escalated")
    for sf_field, fixed in (CFG.get("fixed_values") or {}).items():
      body[sf_field] = fixed
    put("agent_name", (str(getattr(context, "agent_name", "") or "")[:80]) or None)
    for sf_field, variable in (CFG.get("links") or {}).items():
      value = context.variables.get(variable)
      if value:
        body[sf_field] = str(value)

    if CFG.get("connector_tool"):
      err = _save_through_connector(session_id, body)
    else:
      path = "/sobjects/" + CFG["sobject"] + "/" + CFG["external_id_field"] + "/" + urllib.parse.quote(session_id, safe="")
      _resp, err = _request("PATCH", path, body=body)
    if err:
      return err
    return {"ok": True, "message": "Transcript saved.", "characters": len(text)}
  except Exception as e:
    print("tool: unexpected error:", type(e).__name__, str(e)[:200])
    return _fail("tool_error", "The transcript could not be saved.", system=True)
