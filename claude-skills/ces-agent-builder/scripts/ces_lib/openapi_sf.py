"""Generate an OpenAPI 3.0 schema for the Salesforce REST API (the 'Salesforce connector' as an OpenAPI toolset).

Operations (spec toolsets[].operations[]):
  get_record   {operationId, sobject, fields[], description}      GET  /sobjects/{sobject}/{id}   (fields pinned with a one-value enum)
  create_record{operationId, sobject, fields[{name,type,required,description,enum}], description}
  update_record{operationId, sobject, fields[...], description}   PATCH /sobjects/{sobject}/{id}
  upsert_record{operationId, sobject, external_id_field, path_param, fields[{name,type,description,enum}]}   PATCH /sobjects/{sobject}/{externalIdField}/{value}  (create or update by external id)
  soql_query   {operationId, description, allow_free_soql: true, q_pattern, response_fields[], q_description}   GET /query?q=
               (free SOQL, high risk: opt-in only. q_pattern is a regex the model-built query must match, for example one fixed SELECT)
  apex_rest    {operationId, method, path, params[], body_fields[], description}   custom Apex REST endpoint
"""
from .common import SpecError, need

JSON_TYPES = {"string": "string", "text": "string", "phone": "string", "email": "string", "date": "string", "picklist": "string",
              "number": "number", "boolean": "boolean", "integer": "integer"}


def _props(fields):
    props, required = {}, []
    for f in fields:
        p = {"type": JSON_TYPES.get(f.get("type", "string"), "string")}
        if f.get("description"):
            p["description"] = f["description"]
        if f.get("type") == "date":
            p["format"] = "date"
        if f.get("enum") or f.get("allowed"):
            p["enum"] = f.get("enum") or f.get("allowed")
        props[f["name"]] = p
        if f.get("required"):
            required.append(f["name"])
    return props, required


def build_schema(instance_url, api_version, title, operations, relative=False):
    """relative=True: the server URL includes /services/data/<version> (the console's Server field) and paths are /query, /sobjects/...
    Both forms resolve to the same final URL, so use relative=True when you paste the schema into the console's Salesforce tool dialog."""
    base = "" if relative else "/services/data/%s" % api_version
    server = instance_url.rstrip("/") + ("/services/data/%s" % api_version if relative else "")
    paths = {}

    def add(path, method, op):
        taken = paths.setdefault(path, {}).get(method)
        if taken:
            raise SpecError("operations '%s' and '%s' both use %s %s, and an OpenAPI schema holds one operation per path and method. "
                            "Merge them into one operation (for several SOQL query shapes, one operation with a q_pattern that allows each shape)"
                            % (taken["operationId"], op["operationId"], method.upper(), path.replace("/services/data/", "").split("{")[0] or path))
        paths[path][method] = op

    err = {"description": "Salesforce returned an error"}
    for op in operations:
        kind = need(op, "kind", "toolset operation")
        oid = need(op, "operationId", "toolset operation")
        desc = op.get("description", "")
        if kind == "get_record":
            sobject = need(op, "sobject", oid)
            fields = need(op, "fields", oid)
            add("%s/sobjects/%s/{id}" % (base, sobject), "get", {
                "operationId": oid, "summary": desc or "Get one %s record" % sobject, "description": desc,
                "parameters": [
                    {"name": "id", "in": "path", "required": True, "description": "Salesforce record Id", "schema": {"type": "string", "pattern": "^[a-zA-Z0-9]{15,18}$"}},
                    {"name": "fields", "in": "query", "required": False, "description": "Fixed; leave as is", "schema": {"type": "string", "enum": [",".join(fields)], "default": ",".join(fields)}},
                ],
                "responses": {"200": {"description": "The record", "content": {"application/json": {"schema": {"type": "object", "properties": {f.split(".")[0]: {"type": "string"} for f in fields}}}}}, "default": err},
            })
        elif kind in ("create_record", "update_record"):
            sobject = need(op, "sobject", oid)
            props, required = _props(need(op, "fields", oid))
            body = {"required": True, "content": {"application/json": {"schema": {"type": "object", "properties": props, "additionalProperties": False}}}}
            if required and kind == "create_record":
                body["content"]["application/json"]["schema"]["required"] = required
            if kind == "create_record":
                add("%s/sobjects/%s" % (base, sobject), "post", {
                    "operationId": oid, "summary": desc or "Create a %s" % sobject, "description": desc, "requestBody": body,
                    "responses": {"201": {"description": "Created", "content": {"application/json": {"schema": {"type": "object", "properties": {"id": {"type": "string"}, "success": {"type": "boolean"}}}}}}, "default": err}})
            else:
                add("%s/sobjects/%s/{id}" % (base, sobject), "patch", {
                    "operationId": oid, "summary": desc or "Update a %s" % sobject, "description": desc, "requestBody": body,
                    "parameters": [{"name": "id", "in": "path", "required": True, "description": "Salesforce record Id", "schema": {"type": "string", "pattern": "^[a-zA-Z0-9]{15,18}$"}}],
                    "responses": {"204": {"description": "Updated"}, "default": err}})
        elif kind == "upsert_record":
            sobject = need(op, "sobject", oid)
            ext = need(op, "external_id_field", oid)
            path_param = op.get("path_param", "session_id")
            props, required = _props(need(op, "fields", oid))
            body = {"required": True, "content": {"application/json": {"schema": {"type": "object", "properties": props, "additionalProperties": False}}}}
            add("%s/sobjects/%s/%s/{%s}" % (base, sobject, ext, path_param), "patch", {
                "operationId": oid, "summary": desc or "Create or update a %s by %s" % (sobject, ext), "description": desc,
                "parameters": [{"name": path_param, "in": "path", "required": True, "description": "Value of %s that identifies the record" % ext, "schema": {"type": "string"}}],
                "requestBody": body,
                "responses": {"201": {"description": "Created", "content": {"application/json": {"schema": {"type": "object", "properties": {"id": {"type": "string"}, "success": {"type": "boolean"}}}}}},
                              "204": {"description": "Updated"}, "default": err}})
        elif kind == "soql_query":
            if not op.get("allow_free_soql"):
                raise SpecError("%s: soql_query lets the model write any query the integration user can run; set allow_free_soql: true only if the user accepted that risk" % oid)
            qschema = {"type": "string"}
            if op.get("q_pattern"):
                qschema["pattern"] = op["q_pattern"]        # defence in depth; the integration user's permissions are the real boundary
            rec_props = {}
            for f in op.get("response_fields", []):
                # entries: "Name" (string) or {"name": "TotalAmount", "type": "number"} or {"name": "Account", "type": "object", "properties": ["Phone"]}
                fname, ftype = (f, "string") if isinstance(f, str) else (f["name"], f.get("type", "string"))
                if ftype == "object":
                    subs = (f.get("properties") if isinstance(f, dict) else None) or []
                    rec_props[fname] = {"type": "object", "properties": {sp: {"type": "string"} for sp in subs}}
                else:
                    rec_props[fname] = {"type": JSON_TYPES.get(ftype, ftype)}
            item = {"type": "object", "properties": rec_props} if rec_props else {"type": "object"}
            add("%s/query" % base, "get", {
                "operationId": oid, "summary": desc or "Run a SOQL query", "description": desc,
                "parameters": [{"name": "q", "in": "query", "required": True, "description": op.get("q_description", "SOQL query"), "schema": qschema}],
                "responses": {"200": {"description": "Query result", "content": {"application/json": {"schema": {"type": "object", "properties": {"totalSize": {"type": "integer"}, "done": {"type": "boolean"}, "records": {"type": "array", "items": item}}}}}}, "default": err}})
        elif kind == "apex_rest":
            path = need(op, "path", oid)
            method = op.get("method", "get").lower()
            if not path.startswith("/services/apexrest/"):
                raise SpecError("%s: apex_rest path must start with /services/apexrest/" % oid)
            params = []
            for prm in op.get("params", []):
                schema = {"type": JSON_TYPES.get(prm.get("type", "string"), "string")}
                if prm.get("pattern"):
                    schema["pattern"] = prm["pattern"]
                params.append({"name": prm["name"], "in": prm.get("in", "query"), "required": bool(prm.get("required", True)),
                               "description": prm.get("description", ""), "schema": schema})
            # response_fields: {"name": "string"} for plain values, or {"records": ["Id", {"name": "Total", "type": "number"}]} for a list of records
            props = {}
            for k, v in (op.get("response_fields") or {}).items():
                if isinstance(v, list):
                    item_props = {}
                    for f in v:
                        fname, ftype = (f, "string") if isinstance(f, str) else (f["name"], f.get("type", "string"))
                        item_props[fname] = {"type": JSON_TYPES.get(ftype, ftype)}
                    props[k] = {"type": "array", "items": {"type": "object", "properties": item_props}}
                else:
                    props[k] = {"type": JSON_TYPES.get(v, "string")}
            ok_code = "204" if method in ("patch", "delete") and not props else "200"
            responses = {ok_code: {"description": "Result"}, "default": err}
            if props:
                responses[ok_code]["content"] = {"application/json": {"schema": {"type": "object", "properties": props}}}
            item = {"operationId": oid, "summary": desc or oid, "description": desc, "parameters": params, "responses": responses}
            if op.get("body_fields"):
                bprops, required = _props(op["body_fields"])
                schema = {"type": "object", "properties": bprops, "additionalProperties": False}
                if required:
                    schema["required"] = required
                item["requestBody"] = {"required": True, "content": {"application/json": {"schema": schema}}}
            add(path, method, item)
        else:
            raise SpecError("toolset operation %s: unknown kind %s" % (oid, kind))
    return {"openapi": "3.0.3", "info": {"title": title, "version": "1.0.0"}, "servers": [{"url": server}], "paths": paths}
