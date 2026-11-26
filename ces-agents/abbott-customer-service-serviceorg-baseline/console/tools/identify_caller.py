def identify_caller(include_details: bool = False) -> dict:
  """Recognises the caller from the phone number they are calling from, by looking for exactly one matching Salesforce contact. It runs automatically at the start of the call. Do not call it yourself.

  Args:
    include_details: Internal use by the start-of-call callback: also return the contact's email and ids. Leave empty.

  Returns:
    dict: ok, caller_status (known or unknown) and first_name. If system_error is true the lookup failed and the caller is treated as unknown.
  """
  # ---- org settings (generated from the spec: change them there, not here) ----
  CONNECTOR_TOOL = 'query_salesforce_run_query'   # when set, Salesforce is reached through the Salesforce connector tool (platform OAuth)
  CFG = {'sobject': 'Contact',
     'caller_id_variable': 'telephony-caller-id',
     'phone_fields': ['Phone', 'MobilePhone'],
     'name_field': 'FirstName',
     'email_field': 'Email',
     'account_field': 'AccountId',
     'match_digits': 10,
     'max_candidates': 20}
  ARGS = {"include_details": include_details}

  def _digits(value):
    return "".join(ch for ch in str(value or "") if ch.isdigit())

  def _fail(error, message, system=False, **extra):
    out = {"ok": False, "error": error, "message": message}
    if system:
      out["system_error"] = True
    out.update(extra)
    return out

  def _get_path(record, path):
    # read "Account.Phone" style paths from a Salesforce record
    cur = record
    for part in str(path).split("."):
      if not isinstance(cur, dict):
        return None
      cur = cur.get(part)
    return cur

  def _query_via_connector(soql):
    # the connector tool is called like a function; the platform adds the OAuth token
    try:
      res = getattr(tools, CONNECTOR_TOOL)({"q": soql})
    except Exception as e:
      code = getattr(e, "status_code", None)
      print("tool: connector call failed:", type(e).__name__, code)
      if code == 401:
        return None, _fail("salesforce_auth_failed", "The system is not available right now.", system=True)
      return None, _fail("salesforce_error", "The system is not available right now.", system=True, code=code)
    status = getattr(res, "status_code", 200)
    if status == 401:
      print("tool: connector returned 401")
      return None, _fail("salesforce_auth_failed", "The system is not available right now.", system=True)
    if isinstance(status, int) and status >= 400:
      print("tool: connector returned status", status)
      return None, _fail("salesforce_error", "The system is not available right now.", system=True, code=status)
    data = res.json() if hasattr(res, "json") else res
    if isinstance(data, dict) and "records" not in data and isinstance(data.get("result"), dict):
      data = data["result"]      # some tool responses wrap the body in {"result": ...}
    if not isinstance(data, dict):
      print("tool: unexpected connector response type:", type(data).__name__)
      return None, _fail("tool_error", "The request could not be completed right now.", system=True)
    return (data.get("records") or []), None

  def _query(soql):
    return _query_via_connector(soql)

  def _same_phone(caller_digits, record_digits):
    # compare the trailing digits, so country codes and punctuation do not matter; fewer than 7 digits never match
    n = min(len(caller_digits), len(record_digits), int(CFG.get("match_digits", 10)))
    return n >= 7 and caller_digits[-n:] == record_digits[-n:]

  def _publish(status, contact):
    # the state the rest of the call needs
    contact = contact or {}
    context.variables["caller_status"] = status
    context.variables["caller_name"] = contact.get("first_name", "")
    context.variables["caller_email"] = contact.get("email", "")
    context.variables["caller_contact_id"] = contact.get("contact_id", "")
    context.variables["caller_account_id"] = contact.get("account_id", "")

  def _unknown(message):
    _publish("unknown", None)
    return {"ok": True, "caller_status": "unknown", "first_name": "", "message": message}

  try:
    caller_digits = _digits(context.variables.get(CFG["caller_id_variable"]))
    if len(caller_digits) < 7:
      print("tool: no usable caller number on this call")
      return _unknown("The caller's number is not available.")
    last4 = caller_digits[-4:]
    phone_fields = list(CFG["phone_fields"])
    fields = ["Id", CFG["name_field"], CFG["email_field"], CFG["account_field"]] + phone_fields
    condition = " OR ".join(f + " LIKE '%" + last4 + "'" for f in phone_fields)
    soql = ("SELECT " + ", ".join(dict.fromkeys(fields)) + " FROM " + CFG["sobject"] +
            " WHERE " + CFG["account_field"] + " != null AND (" + condition + ") LIMIT " + str(int(CFG["max_candidates"])))
    records, err = _query(soql)
    if err:
      _publish("unknown", None)
      err["caller_status"] = "unknown"
      return err
    matches = [r for r in records if any(_same_phone(caller_digits, _digits(_get_path(r, f))) for f in phone_fields)]
    if len(matches) != 1:
      print("tool: the caller's number matched", len(matches), "contact(s)")
      return _unknown("No single contact matches this number.")
    rec = matches[0]
    contact = {"first_name": str(_get_path(rec, CFG["name_field"]) or "").strip(),
               "email": str(_get_path(rec, CFG["email_field"]) or "").strip(),
               "contact_id": str(rec.get("Id") or ""), "account_id": str(_get_path(rec, CFG["account_field"]) or "")}
    _publish("known", contact)
    out = {"ok": True, "caller_status": "known", "first_name": contact["first_name"]}
    if ARGS.get("include_details"):
      out.update({"email": contact["email"], "contact_id": contact["contact_id"], "account_id": contact["account_id"]})
    return out
  except Exception as e:
    print("tool: unexpected error:", type(e).__name__, str(e)[:200])
    _publish("unknown", None)
    return _fail("tool_error", "The request could not be completed right now.", system=True, caller_status="unknown")
