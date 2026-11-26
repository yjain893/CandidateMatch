def update_shipping_address(order_number: str, street: str = "", city: str = "", state: str = "", postal_code: str = "", country: str = "") -> dict:
  """Changes an order's shipping address. Send only the parts the caller gave. Call after verification, with the order number and the new address.
  
  Args:
    order_number: As the caller said it, for example "102".
    street: New street and number, as said.
    city: Only if given.
    state: Only if given.
    postal_code: Only if given.
    country: Only if given.
  
  Returns:
    dict: ok, updated_fields. not_found, not_confirmed, invalid_input: fix and retry. system_error true: apologize and escalate.
  """
  # ---- org settings (generated from the spec: change them there, not here) ----
  CONNECTOR_TOOL = 'query_salesforce_run_query'   # when set, Salesforce is reached through the Salesforce connector tool (platform OAuth)
  CFG = {'sobject': 'Order',
     'lookup': {'field': 'OrderNumber', 'normalize': 'digits', 'pad': 8},
     'fields': [{'param': 'street',
                 'field': 'ShippingStreet',
                 'type': 'string',
                 'max_length': 255,
                 'doc': 'New street and number, exactly as the caller said it.'},
                {'param': 'city',
                 'field': 'ShippingCity',
                 'type': 'string',
                 'max_length': 40,
                 'doc': 'New city, only if the caller gave one.'},
                {'param': 'state',
                 'field': 'ShippingState',
                 'type': 'string',
                 'max_length': 80,
                 'doc': 'New state or province, only if the caller gave one.'},
                {'param': 'postal_code',
                 'field': 'ShippingPostalCode',
                 'type': 'string',
                 'max_length': 20,
                 'doc': 'New postal code, only if the caller gave one.'},
                {'param': 'country',
                 'field': 'ShippingCountry',
                 'type': 'string',
                 'max_length': 80,
                 'doc': 'New country, only if the caller gave one.'}],
     'scope_field': '',
     'require_verified': True,
     'require_confirmation': False,
     'write_connector_tool': 'query_salesforce_update_order_address',
     'remember_id_as': 'last_order_id'}
  ARGS = {"lookup": order_number, "street": street, "city": city, "state": state, "postal_code": postal_code, "country": country}

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

  def _write_via_connector(tool_name, path_args, body):
    # How the connector maps a request body to arguments is not documented, so three argument shapes are tried in turn
    shapes = [dict(path_args, **body), dict(path_args, body=body), dict(path_args, requestBody=body)]
    status = None
    for index, args in enumerate(shapes):
      try:
        res = getattr(tools, tool_name)(args)
      except Exception as e:
        status = getattr(e, "status_code", None)
        print("tool: connector write failed with argument shape", index, type(e).__name__, status)
        if status == 401:
          break
        continue
      status = getattr(res, "status_code", 200)
      if not isinstance(status, int) or status < 400:
        print("tool: change saved through the connector with argument shape", index)
        return None
      print("tool: connector returned", status, "for argument shape", index)
      if status == 401:
        break
    kind = "salesforce_auth_failed" if status == 401 else "salesforce_error"
    return _fail(kind, "The system is not available right now.", system=True, code=status)

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

  try:
    blocked = _require_verified()
    if blocked:
      return blocked
    if CFG.get("require_confirmation", True) and ARGS.get("caller_confirmed") is not True:
      return _fail("not_confirmed", "Read the change back to the caller and get a clear yes before saving.")
    value = _normalize_key(ARGS["lookup"], CFG["lookup"])
    if not value:
      return _fail("invalid_input", "A valid value is needed to find the record.")
    body = {}
    for spec in CFG["fields"]:
      raw = ARGS.get(spec["param"])
      if raw is None or str(raw).strip() == "":
        continue
      clean, problem = _check_value(spec, raw)
      if problem:
        return _fail("invalid_input", spec["param"] + " " + problem)
      body[spec["field"]] = clean
    if not body:
      return _fail("invalid_input", "At least one value to change is needed.")
    soql = ("SELECT Id FROM " + CFG["sobject"] + " WHERE " + CFG["lookup"]["field"] + " = '" +
            _soql_text(value) + "'" + " LIMIT 1")
    records, err = _query(soql)
    if err:
      return err
    if not records:
      return _fail("not_found", "No matching record was found.")
    record_id = records[0]["Id"]
    if CFG.get("write_connector_tool"):
      err = _write_via_connector(CFG["write_connector_tool"], {"id": record_id}, body)
    else:
      _resp, err = _request("PATCH", "/sobjects/" + CFG["sobject"] + "/" + record_id, body=body)
    if err:
      return err
    if CFG.get("remember_id_as"):
      context.variables[CFG["remember_id_as"]] = record_id
    return {"ok": True, "updated_fields": sorted(body.keys()), "message": "Saved."}
  except Exception as e:
    print("tool: unexpected error:", type(e).__name__, str(e)[:200])
    return _fail("tool_error", "The request could not be completed right now.", system=True)
