def get_order_status(order_number: str) -> dict:
  """Gets the status, order date, end date and total amount of one order. Call it after the caller is verified and has given the order number. If error is not_found, ask the caller to check the order number.

  Args:
    order_number: The order number the caller gave, for example "102" or "00000102".

  Returns:
    dict: ok and order_status, order_date, end_date, total_amount. If error is not_found nothing matched; if system_error is true, apologize and escalate.
  """
  # ---- org settings (generated from the spec: change them there, not here) ----
  CONNECTOR_TOOL = 'query_salesforce_find_order'   # when set, Salesforce is reached through the Salesforce connector tool (platform OAuth)
  CFG = {'sobject': 'Order',
     'lookup': {'field': 'OrderNumber', 'normalize': 'digits', 'pad': 8},
     'return_fields': {'order_status': 'Status',
                       'order_date': 'EffectiveDate',
                       'end_date': 'EndDate',
                       'total_amount': 'TotalAmount'},
     'scope_field': '',
     'require_verified': True,
     'remember_id_as': 'last_order_id'}
  ARGS = {"lookup": order_number}

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

  def _require_verified():
    if CFG.get("require_verified", True) and not context.variables.get("caller_verified"):
      return _fail("not_verified", "The caller must be verified before this can be done.")
    return None

  def _scope_clause():
    # row level security: only records that belong to the verified caller
    field = CFG.get("scope_field")
    if not field:
      return "", None
    scope = context.variables.get("verified_scope_id")
    if not scope:
      return "", _fail("not_verified", "The caller must be verified before this can be done.")
    return " AND " + field + " = '" + _soql_text(scope) + "'", None

  try:
    blocked = _require_verified()
    if blocked:
      return blocked
    value = _normalize_key(ARGS["lookup"], CFG["lookup"])
    if not value:
      return _fail("invalid_input", "A valid value is needed to look this up.")
    scope_sql, scope_err = _scope_clause()
    if scope_err:
      return scope_err
    fields = ["Id"] + list(CFG["return_fields"].values())
    soql = ("SELECT " + ", ".join(dict.fromkeys(fields)) + " FROM " + CFG["sobject"] +
            " WHERE " + CFG["lookup"]["field"] + " = '" + _soql_text(value) + "'" + scope_sql + " LIMIT 1")
    records, err = _query(soql)
    if err:
      return err
    if not records:
      return _fail("not_found", "No matching record was found.")
    if CFG.get("remember_id_as") and records[0].get("Id"):
      context.variables[CFG["remember_id_as"]] = records[0]["Id"]
    out = {"ok": True}
    out.update(_map_fields(records[0], CFG["return_fields"]))
    return out
  except Exception as e:
    print("tool: unexpected error:", type(e).__name__, str(e)[:200])
    return _fail("tool_error", "The request could not be completed right now.", system=True)
