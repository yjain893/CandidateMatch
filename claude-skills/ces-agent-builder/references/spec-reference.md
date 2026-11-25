# spec.json reference (input of scripts/build_agent.py)

Paths inside the spec are relative to the spec file. Working examples: `assets/example-smoke/spec.json` (smallest),
`assets/example-pharma/spec.json` (a real voice agent), `assets/example-all-features/spec.json` (every feature, used as a regression test).

```
{ "app": {...}, "salesforce": {...}, "variables": [...], "tools": [...], "toolsets": [...], "guardrails": [...], "agents": [...] }
```

## app
| key | default | notes |
|---|---|---|
| displayName | required | also the zip root folder name |
| description | "" | not sent to the model |
| channel | voice | voice \| chat \| both. chat omits audioProcessingConfig and disables DTMF |
| defaultLanguage | en-US | voice languages: see app-config-reference.md |
| supportedLanguages, multilingual | none | adds languageSettings |
| timeZone | America/Los_Angeles | IANA name |
| model, thinkingLevel, temperature | voice: gemini-composite-v2; chat: gemini-3.5-flash (MEDIUM) | thinkingLevel DEFAULT\|LOW\|MEDIUM\|HIGH, written only for text models (composite models carry none) |
| persona | CONCISE | CONCISE \| CHATTY |
| voice | {name, speakingRate 1.0, ambientSound, ambientVolumeDb} | speakingRate 0.25 to 2.0 |
| inactivityTimeout | 10s | seconds string |
| bargeInAwareness, disableDtmf, disableBargeIn | true, false(chat: true), false | |
| logging | {retentionDays 365, redaction false, cloudLogging false} | |
| errorHandling | {strategy FALLBACK_RESPONSE, maxFallbackAttempts 1, escalateOnEnd true, customFallbackMessage} | strategy NONE\|FALLBACK_RESPONSE\|END_SESSION |
| toolExecutionMode | PARALLEL | or SEQUENTIAL |
| rootAgent | first agent | displayName |
| globalInstructionFile | none | text file, becomes global_instruction.txt |

## salesforce
```
{"orgAlias": "demoOrg", "instanceUrl": "https://<my-domain>.my.salesforce.com", "apiVersion": "v68.0",
 "auth": {"mode": "bearer_variable", "tokenVariable": "salesforce_access_token"}}
 or
 "auth": {"mode": "oauth_client_credentials", "clientId": "<consumer key>", "clientSecretVersion": "projects/P/secrets/S/versions/latest"}   // no scopes: Salesforce rejects a scope in the request
```
- `bearer_variable` (POC and backend-injected token): Python template tools and toolsets read the token from the variable. The package ships it **empty**.
- `oauth_client_credentials` (production): toolsets use it (the platform fetches tokens and reads the secret from Secret Manager). Python template tools can only use it with `"transport": "connector"`.
- `transport`: `rest` (default, Python calls Salesforce with `ces_requests` and the token variable) or `connector` (Python calls the Salesforce connector tool; read-only templates). With `connector` also set `"connectorTool": "<connector name>_<operationId>"`.

## variables
`{"name", "type": STRING|NUMBER|INTEGER|BOOLEAN|OBJECT|ARRAY, "default", "description"}` or `"schema": {...}` for objects/arrays.
Template tools and callbacks add the variables they need automatically (`caller_verified`, `verified_record_id`, `verified_scope_id`,
`verification_attempts`, `first_turn`, and the token variable). Use `{{name}}` (static, config) or `{name}` (dynamic, written by tools) in instructions.

## tools
Template tool: `{"name": "snake_case", "template": "<template>", "params": {...}, "description": "optional override", "executionType": "SYNCHRONOUS"}`.
Custom tool: `{"name": "snake_case", "file": "tools_src/name.py"}` (the file must define `def name(...)`).

Field spec used by create/update/search: `{"param", "field", "type": string|text|number|boolean|date|picklist|phone|email, "required", "allowed": [...], "max_length", "doc", "op" (search only)}`.
Return mapping: `{"output_key": "Salesforce.Field.Path"}`, for example `{"order_status": "Status", "account_name": "Account.Name"}`.
Key spec: `{"param", "field", "normalize": none|digits|alnum_upper, "pad": 8, "doc"}`.

| template | params |
|---|---|
| verify_caller | sobject, identifier{param,field,normalize,pad,doc}, factor{param,field,kind: phone\|email\|text\|digits_last_n, last_n, doc}, return_fields, scope_field, max_attempts (3), description |
| lookup_record | sobject, lookup{...key spec}, return_fields, scope_field, require_verified (true), remember_id_as (a variable that receives the record Id), connector_tool (query operation override), description |
| search_records | sobject, filters[{param,field,op: = != < > <= >= LIKE,type,allowed,max_length,doc}], return_fields, scope_field, require_verified, require_filter (true), order_by, max_rows (5) |
| create_record | sobject, fields[], fixed_values{Field: value}, scope_assignments{Field: variable}, return_fields, require_verified, require_confirmation (true) |
| update_record | sobject, lookup{...key spec}, fields[], scope_field, require_verified, require_confirmation (true), write_connector_tool (required with the connector transport), connector_tool (query operation override), remember_id_as |
| identify_caller | connector_tool (query operation override), caller_id_variable (`telephony-caller-id`), phone_fields (Phone, MobilePhone), name_field (FirstName), email_field (Email), account_field (AccountId), match_digits (10), max_candidates (20) |
| verify_contact_email | max_attempts (3), email_variable (`caller_email`), description |
| save_transcript | connector_tool (required with `salesforce.transport: "connector"`), sobject (`Voice_Call_Transcript__c`), external_id_field (`Session_Id__c`), fields{logical name: Salesforce field}, links{Salesforce field: variable}, redact_patterns{name: regex}, max_chars (120000), max_attempts, path_param (`session_id`) |

Result contract (all templates): success has `ok: true`; failures have `ok: false` plus `error` (`not_verified`, `not_found`, `invalid_input`,
`not_confirmed`, `locked_out`, `token_missing`, `salesforce_auth_failed`, `salesforce_error`, `tool_error`) and `message`; system problems add
`system_error: true`. `verify_caller` additionally returns `verified` and `attempts_remaining`.
Rules enforced at build time: tools that need a verified caller require a `verify_caller` tool; `scope_field` on any tool requires `scope_field` on
`verify_caller`; picklist fields need `allowed`.

## toolsets (Salesforce connector as an OpenAPI toolset)
```
{"name": "salesforce_connector", "type": "salesforce_openapi", "title": "...", "description": "...",
 "operations": [
  {"kind": "get_record", "operationId": "get_case_by_id", "sobject": "Case", "fields": ["Id","CaseNumber"], "description": "..."},
  {"kind": "create_record" | "update_record", "operationId": "...", "sobject": "Case", "fields": [{"name","type","required","description","enum"}]},
  {"kind": "apex_rest", "operationId": "...", "method": "get", "path": "/services/apexrest/x", "params": [{"name","type","required","description","in"}], "body_fields": [...], "response_fields": {"k": "string"}},
  {"kind": "soql_query", "operationId": "...", "allow_free_soql": true},   // refused unless the user accepted the risk
  {"kind": "upsert_record", "operationId": "save_transcript", "sobject": "Voice_Call_Transcript__c", "external_id_field": "Session_Id__c", "path_param": "session_id", "fields": [{"name","type","description","enum"}]}   // PATCH by external id, 201 or 204
 ]}
```
Extra keys: `"server_includes_version": true` (server URL ends with `/services/data/<version>` and paths are `/query`, which is how the console's Server field works; use it when you paste the generated schema into the console),
`q_pattern` (regex the query must match), `q_description`, `response_fields` (`"Name"` or `{"name","type"}` or `{"name":"Account","type":"object","properties":["Phone"]}`).
Agents attach operations with `"toolsets": [{"toolset": "salesforce_connector", "toolIds": ["get_case_by_id"]}]`.

## guardrails
Default when omitted: default_safety (strict) + default_prompt_security. Types and keys: see guardrails-guide.md.
Placement: `"scope": "app"` (default) or `"scope": "agent"` with `"agents": ["name"]`. `llm_policy` uses `policy_scope`, not `scope`.

## agents
```
{"displayName": "Root agent", "description": "", "instructionFile": "instructions/root.txt" (or "instruction": "text"),
 "tools": ["authenticate_user", "end_session"], "toolsets": [...], "childAgents": [...], "guardrails": [...], "modelSettings": {...},
 "callbacks": {"beforeModel": [{"template": "...", "params": {...}, "description": "..."} | {"file": "x.py"}], "afterModel": [...],
               "beforeAgent": [...], "afterAgent": [...], "beforeTool": [...], "afterTool": [...]}}
```
Callback templates: `static_greeting {greeting with {variable} placeholders, disclaimer}` (before model), `inactivity_prompt {text}` (before model),
`escalate_on_system_error {tools[], message, escalate}` (before model), `mandatory_text {text}` (after model), `redact_output {patterns{}, replacement}` (after model),
`lookup_caller_on_start {tool (identify_caller)}` (before AGENT: looks the caller up once, before the agent's first turn, and stores name, email and ids in variables, so the agent knows the name when it speaks first; the folder layout for before-agent callbacks follows the same pattern as the others but was not yet seen in a real export),
`greet_known_caller {tool (identify_caller), mode (direct | tool_call), speak (model | callback), greeting, greeting_unknown, disclaimer}` (before model: runs the caller lookup at session start and stores the caller in variables; `speak: model` (default) leaves the greeting to the agent, whose instruction holds the exact words, which is what a voice call needs, and writes the caller into the model's own request because variables set here reach the model only on its next turn; `speak: callback` makes the callback say it (greeting must then contain {caller_name}), and that showed as text but was not heard; `direct` calls the tool from the callback, `tool_call` asks the platform for the tool call; the tool must be on the agent),
`hide_tools {tools[]}` (before model: keeps tools out of the model's view; code and callbacks can still run them),
`save_transcript_on_end {tool, closing_texts}` (after model: inserts the tool call, with an outcome of completed, escalated, verification failed or system error, in front of `end_session`; `closing_texts` maps an outcome to words that are added first when the model ended the call without saying anything).
Using `save_transcript_on_end` forces `app.toolExecutionMode` to `SEQUENTIAL` (an explicit PARALLEL is an error) and requires the tool on that agent. See `transcripts.md`.

## Toolset files written
`toolsets/<name>/<name>.json`, `toolsets/<name>/open_api_toolset/open_api_schema.yaml` (servers url is `$env_var`) and `environment.json` with the real server URL, token endpoint and secret version, exactly like a console export.

## Build outputs
`build_agent.py spec.json --out DIR [--selftest] [--no-zip] [--force]` writes the package folder, the zip, and `DIR/_selftest/scenarios.json`.
It validates, and refuses to zip when validation or the self-test fails.
