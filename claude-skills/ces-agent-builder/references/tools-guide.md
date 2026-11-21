# Tools: what to use when, and how the generated Python tools work

## Choosing the tool type

| Situation | Use | Notes |
|---|---|---|
| Anything involving normalization, checks, verification, shaping the output | **Python tool** (`python_template` or custom file) | Google's own best practice: wrap APIs in Python tools |
| Call Salesforce with typed, safe inputs and let Google handle OAuth | **Salesforce connector** = OpenAPI toolset with explicit operations | Production auth uses OAuth client credentials + Secret Manager |
| Server-side logic you want to test and deploy in Salesforce | Apex REST endpoint + connector operation (`apex_rest`) | Explicit params, logic in Salesforce. Provide the Apex as files; never deploy for the user |
| End the call, escalate, speak exactly, DTMF | System tools `end_session`, `customize_response` | Listed in the agent's tools by name |
| Answer from documents | Data store / file search tool | Not generated; add in the console |
| Reach other systems | MCP toolset, other OpenAPI tools | Not generated; add in the console |
| Free-form SOQL for the model | Avoid. `soql_query` needs the user's explicit opt-in | The model can then read anything the integration user can |

The Salesforce connector in the console (Create tool -> Salesforce) is the OpenAPI tool with Salesforce defaults (server, auth, generated schema). Python tools
run in a sandbox (Python 3.12; stdlib, pydantic, numpy, protobuf; public internet only; HTTP via `ces_requests`; no private network).

## Authentication modes (decide in the interview)

| Mode | Use for | How |
|---|---|---|
| `bearer_variable` | Proof of concept, demos, or production where a backend injects a fresh token as a session variable | Variable `salesforce_access_token`, shipped **empty**. Get a token with `sf org auth show-access-token --target-org <alias>` (it expires in about two hours) |
| `oauth_client_credentials` | Production | External Client App (or Connected App) with the client credentials flow and a Run As integration user; client secret in Secret Manager; enable the Secret Manager API; grant `roles/secretmanager.secretAccessor` to the CES service agent. Only toolsets can use it |

Never put a token or client secret in the spec, the package or a variable default.

## The eight template tools (assets/tool-templates)

All are one self-contained function (helpers nested inside). Settings sit in a `CFG` block at the top of the generated function.
Shared contract: success `ok: true`; failure `ok: false`, `error`, `message`; platform/system problems add `system_error: true`.

| Template | What it does | Writes variables |
|---|---|---|
| `verify_caller` | Finds one record by an identifier (normalized), compares a second detail (phone, email, text, last N digits) in code, counts failures, locks out after N, returns only chosen fields. The detail itself is never put in the query and never returned | `caller_verified`, `verified_record_id`, `verified_scope_id`, `verification_attempts` |
| `lookup_record` | One record by key, only mapped fields, needs `caller_verified`, scoped to the verified Account/Contact. `remember_id_as` stores the record's Id in a variable | none (or the variable named in `remember_id_as`) |
| `search_records` | Up to `max_rows` records with whitelisted filters (type checked, picklists validated, LIKE stripped of wildcards) | none |
| `create_record` | Creates a record from whitelisted validated fields, fixed values and scope assignments; requires `caller_confirmed: true`; returns mapped fields of the new record | none |
| `update_record` | Finds the record (inside the caller's scope when `scope_field` is set), then PATCHes only the whitelisted fields the caller gave; requires `caller_confirmed: true` unless `require_confirmation: false`. With the connector transport it writes through a dedicated update operation (`write_connector_tool`) | none (or `remember_id_as`) |
| `identify_caller` | Recognises the caller from the phone number in `telephony-caller-id`: finds exactly one Contact (with an Account) whose phone matches on the trailing digits, stores first name, email, contact id and account id. Meant to be run by the `greet_known_caller` callback. See `caller-id-verification.md` | `caller_status`, `caller_name`, `caller_email`, `caller_contact_id`, `caller_account_id` |
| `verify_contact_email` | Compares the email the caller says (spoken forms like "at", "dot", "at the rate" and spelled letters are normalised) with the stored contact email, in code; counts tries, locks out after N, uniform failure message | `caller_verified`, `verification_attempts` |
| `save_transcript` | Builds the call transcript from the session events, masks card and SSN patterns, truncates, links the verified Order and Account, and upserts one record keyed by the session id. Meant to be run by the `save_transcript_on_end` callback, not by the model. See `transcripts.md` | none |

Security properties each template enforces (and the self-test proves): no SOQL injection (digits only or escaped quotes), verification gate,
row-level scope, uniform failure messages, no token in results, no crash on 401/500/missing token.

Parameters for each template: spec-reference.md. When the user needs something the templates do not cover (joins, aggregates, calling two APIs,
non-Salesforce APIs), write a **custom Python tool** following the rules below, then add scenarios or a short selftest of its own.

## Writing a custom Python tool

```python
from typing import Optional

def get_open_balance(account_number: str) -> dict:
  """One or two sentences telling the model when to call this tool.

  Args:
    account_number: The account number the caller gave, digits only.

  Returns:
    dict: ok and balance_due. If system_error is true, apologize and escalate.
  """
  # nested helpers only; return small dicts; never return raw API payloads
```
Rules
1. The file defines a function whose name equals the tool name (snake_case). Docstring = tool description; document every parameter under `Args:`.
2. Flat, typed, descriptive parameters. Optional ones get defaults (`str = ""`, `Optional[float] = None`, `bool = False`).
3. Globals available: `context` (use `context.variables`), `ces_requests` (get/post/put/patch/delete; `.status_code`, `.json()`, `.raise_for_status()`), `tools` (call another tool: `tools.<tool_name>_<operation>({args})`), `get_variable`/`set_variable`, `_session`.
4. Do not `import requests`. Imports are limited to the documented sandbox.
5. Catch every exception and return an error dict; use `print()` for tracing (shows in the trace) but never print tokens or personal data.
6. Return JSON-serializable dicts with the `ok` / `error` / `message` / `system_error` contract so instructions and the escalate callback keep working.
7. Keep synchronous tools fast (about 5 seconds or less; default timeout 30 s). Use `executionType: ASYNCHRONOUS` only for slow work and add instructions for the pending state.
8. Sandbox reaches the public internet only; a Salesforce org with IP login restrictions may reject the sandbox's addresses (check Login IP ranges / connected app IP relaxation).

## Python through the connector (hybrid): `salesforce.transport: "connector"`  (VERIFIED end to end in the console)

Python keeps the logic (normalizing, verification, lockout, scope, returning only chosen fields) and the Salesforce connector does the request and the login.
No token variable and no secret in code: the platform gets the token with OAuth client credentials and reads the client secret from Secret Manager.
This is the recommended production design. A real agent built this way verified callers against Salesforce in the Preview simulator.

```
"salesforce": {"transport": "connector", "connectorTool": "query_salesforce_find_order",
               "auth": {"mode": "oauth_client_credentials", "clientId": "...", "clientSecretVersion": "projects/P/secrets/S/versions/latest"}}
"toolsets": [{"name": "query_salesforce", "type": "salesforce_openapi", "server_includes_version": true,
              "operations": [{"kind": "soql_query", "operationId": "find_order", "allow_free_soql": true,
                              "q_pattern": "^SELECT [A-Za-z0-9_., ]+ FROM Order WHERE OrderNumber = '[0-9]{1,8}' LIMIT 1$",
                              "response_fields": ["Id", {"name": "TotalAmount", "type": "number"}, {"name": "Account", "type": "object", "properties": ["Phone"]}]}]}]
```
- `connectorTool` is `<connector name>_<operationId>` and the generated code calls `getattr(tools, connectorTool)({"q": soql})`. Verified: the name resolves and the call works.
- **The connector does not have to be attached to the agent** (verified): the agent's tool list can hold only the Python tool and `end_session`, so the model cannot call the connector itself. Do not attach it.
- Reads: `verify_caller`, `lookup_record`, `search_records`, `identify_caller`. Writes through the connector: `update_record` (needs `params.write_connector_tool`, an operation of kind `update_record`) and `save_transcript` (needs `params.connector_tool` and an `upsert_record` operation). `create_record` still needs the REST transport.
- **One operation per path and method.** Every `soql_query` operation is `GET /query`, so a toolset can hold only one; the generator refuses a second. To allow several query shapes, give the one operation a `q_pattern` that is an alternation of the shapes (see `example-caller-id-service`). The offline tests check that every query a tool builds matches that pattern.
- The generated code tolerates a plain Salesforce body or a `{"result": ...}` wrapper, and maps 401 to `salesforce_auth_failed`, other 4xx/5xx to `salesforce_error` (with the status in `code`).
- The `q_pattern` regex limits what a query may look like. Whether the platform enforces it is UNVERIFIED; treat the read-only Salesforce Run As user as the real boundary. Several tools that need different queries need either one operation per query shape (each with its own pattern) or an Apex REST endpoint (`apex_rest` kind).
- Leave `oauthConfig.scopes` empty for Salesforce. The validator errors on a scope together with a Salesforce token endpoint.
- Declare the state variables the tool writes (`caller_verified`, `verified_record_id`, `verified_scope_id`, `verification_attempts`); the builder adds them to app.json, add them by hand when pasting the script into an existing app.
- If the call fails with `salesforce_error` and a 403, test Salesforce OAuth on its own first (`sf_oauth_check.py`), then the secret's permissions (see lessons-learned.md).

## Salesforce connector (OpenAPI toolset) operations (build_agent.py `toolsets`)

- `get_record` pins the `fields` query parameter with a one-value enum, so the model cannot ask for other fields.
- `create_record` / `update_record` use `additionalProperties: false` bodies with the listed fields only.
- `apex_rest` for your own endpoints (path must start with `/services/apexrest/`).
- `soql_query` only with `allow_free_soql: true` and the user's explicit acceptance.
- Server comes from `servers[0].url` (the instance URL). Auth from `salesforce.auth`.
- Operations are callable from Python as `<toolset name>_<operationId>` (verified). Whether they appear as `{@TOOL: ...}` names for the agent was not tested because the recommended design does not attach them.

## Tool naming and counts
Distinct verb-first snake_case names, at most about 5 tools per agent, remove unused tools. Reserved: `end_session`, `transfer_to_agent`, `customize_response`.
