def authenticate_user(order_number: str, phone_number: str) -> dict:
  """Verifies a caller by checking the order number and the phone number registered in Salesforce. Call this once the caller has given both. If verified is true, the details in the result can be shared with the caller. If verified is false, do not share anything.

  Args:
    order_number: The order number the caller gave, for example "1234" or "00001234".
    phone_number: The phone number registered with the order, in any format.

  Returns:
    dict: verified (true or false) and a message. When verified is true it also has order_number, order_status, order_date, end_date, total_amount. If error is not_verified the caller may retry (see attempts_remaining). If system_error is true or error is locked_out, stop and escalate.
  """
  # ---- org settings (generated from the spec: change them there, not here) ----
  CONNECTOR_TOOL = 'query_salesforce_find_order'   # <connector name>_<operationId>
  CFG = {'sobject': 'Order',
     'identifier': {'field': 'OrderNumber', 'normalize': 'digits', 'pad': 8},
     'factor': {'field': 'Account.Phone', 'kind': 'phone'},
     'return_fields': {'order_number': 'OrderNumber',
                       'order_status': 'Status',
                       'order_date': 'EffectiveDate',
                       'end_date': 'EndDate',
                       'total_amount': 'TotalAmount'},
     'scope_field': 'AccountId',
     'max_attempts': 3,
     'attempts_variable': 'verification_attempts'}
  ARGS = {"identifier": order_number, "factor": phone_number}

  def _digits(value):
    return "".join(ch for ch in str(value or "") if ch.isdigit())

  def _soql_text(value):
    # escape a text value so it is safe between single quotes in SOQL
    return str(value).replace("\\", "\\\\").replace("'", "\\'")

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

  def _map_fields(record, mapping):
    return {key: _get_path(record, path) for key, path in mapping.items()}

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

  def _normalize_key(value, cfg):
    kind = cfg.get("normalize", "none")
    raw = str(value or "").strip()
    if kind == "digits":
      out = _digits(raw)
      if out and cfg.get("pad"):
        out = out.zfill(int(cfg["pad"]))
      return out
    if kind == "alnum_upper":
      return "".join(ch for ch in raw.upper() if ch.isalnum() or ch == "-")
    return raw

  def _norm_factor(value):
    cfg = CFG["factor"]
    kind = cfg.get("kind", "phone")
    raw = str(value or "").strip()
    if kind == "phone":
      return _digits(raw)[-10:]
    if kind == "digits_last_n":
      return _digits(raw)[-int(cfg.get("last_n", 4)):]
    if kind == "email":
      return raw.lower()
    return " ".join(raw.lower().split())

  def _factor_valid(norm):
    kind = CFG["factor"].get("kind", "phone")
    if kind == "phone":
      return len(norm) >= 7
    if kind == "digits_last_n":
      return len(norm) == int(CFG["factor"].get("last_n", 4))
    if kind == "email":
      return "@" in norm
    return len(norm) >= 2

  try:
    attempts_var = CFG.get("attempts_variable", "verification_attempts")
    attempts = int(context.variables.get(attempts_var) or 0)
    if attempts >= CFG["max_attempts"]:
      return {"verified": False, "ok": False, "error": "locked_out", "message": "Too many failed attempts."}

    ident = _normalize_key(ARGS["identifier"], CFG["identifier"])
    factor = _norm_factor(ARGS["factor"])
    if not ident or not _factor_valid(factor):
      return {"verified": False, "ok": False, "error": "invalid_input",
              "message": "A valid identifier and verification detail are both needed."}

    fields = ["Id", CFG["identifier"]["field"], CFG["factor"]["field"]] + list(CFG["return_fields"].values())
    if CFG.get("scope_field"):
      fields.append(CFG["scope_field"])
    soql = ("SELECT " + ", ".join(dict.fromkeys(fields)) + " FROM " + CFG["sobject"] +
            " WHERE " + CFG["identifier"]["field"] + " = '" + _soql_text(ident) + "' LIMIT 1")
    records, err = _query(soql)
    if err:
      err["verified"] = False
      return err

    def _not_verified():
      count = attempts + 1
      context.variables[attempts_var] = count
      return {"verified": False, "ok": False, "error": "not_verified",
              "message": "The details do not match our records.",
              "attempts_remaining": max(CFG["max_attempts"] - count, 0)}

    if not records:
      return _not_verified()
    record = records[0]
    stored = _norm_factor(_get_path(record, CFG["factor"]["field"]))
    # a blank value on the record never counts as a match
    if not stored or stored != factor:
      return _not_verified()

    context.variables["caller_verified"] = True
    context.variables["verified_record_id"] = record.get("Id")
    if CFG.get("scope_field"):
      context.variables["verified_scope_id"] = _get_path(record, CFG["scope_field"])
    context.variables[attempts_var] = 0
    out = {"verified": True, "ok": True, "message": "The caller is verified."}
    out.update(_map_fields(record, CFG["return_fields"]))
    return out
  except Exception as e:
    print("tool: unexpected error:", type(e).__name__, str(e)[:200])
    return {"verified": False, "ok": False, "error": "tool_error", "system_error": True,
            "message": "The request could not be completed right now."}