# Saving the call transcript to Salesforce

Goal: when a voice or chat session ends, the whole conversation (caller and agent turns, time, outcome, links to the Order and Account) is stored in one Salesforce record.

## Status: VERIFIED IN THE PREVIEW SIMULATOR (one completed call, Nov 2026)
A call finished in Preview saved one `Voice_Call_Transcript__c` row: outcome Completed, 7 turns, 57 seconds, caller verified, Order and Account linked, 14 lines of `Caller:`/`Agent:` text, no system events. The console export afterwards held the tool, the after-model callback, the connector operation and `toolExecutionMode: SEQUENTIAL` exactly as generated.

| Part | Status |
|---|---|
| Tool, callback, connector operation, sequential mode accepted by the console and exported unchanged | VERIFIED (third real export) |
| `context.events`, `context.session_id` and event timestamps as the tool reads them | VERIFIED (text, session id `simulator-<uuid>`, start, end and duration all present) |
| After-model callback inserting the save call in front of `end_session`, saved before the call ends under SEQUENTIAL | VERIFIED for the Completed outcome |
| Save through the connector (PATCH by session id) with the Order and Account links | VERIFIED. The tool tries three body shapes and logs which one worked; the row exists, so one did |
| Caller turns carried `<context>agent speaking was interrupted ...</context>` notes | FOUND in the real row; the template now strips them (re-paste the tool in agents built earlier) |
| Escalated, System error and Verification failed outcomes | Offline only |
| Card and SSN masking, truncation of very long calls, a second save of one session | Offline only |
| Salesforce object, fields, permission set | Deployed by the user; the skill only dry-ran them |
| A hidden tool (`hide_tools`) still being executed when a callback inserts its call | UNVERIFIED (the user did not add the hide callback). If the platform refuses it, drop the callback and rely on the tool description |
| A caller who hangs up without `end_session` | NOT SAVED (known gap) |
| Calls over a real phone number | UNVERIFIED |

Check a test call without opening the console:
```bash
sf data query -o <alias> -q "SELECT Id, Session_Id__c, Outcome__c, Turn_Count__c, Duration_Seconds__c, Order__c, Account__c FROM Voice_Call_Transcript__c ORDER BY CreatedDate DESC LIMIT 5"
```
Preview sessions have ids that start with `simulator-`.

## Design
```
agent decides to end the call (end_session: finished, escalated or system error)
  -> after_model callback (save_transcript_on_end) inserts save_transcript(outcome) in front of end_session
  -> save_transcript (Python tool) builds the text from context.events, redacts, truncates, adds links
  -> connector operation save_transcript (PATCH /sobjects/Voice_Call_Transcript__c/Session_Id__c/<session id>)
  -> one row per call; a second save of the same session updates the same row (no duplicates)
```
- **Known gap: a caller who hangs up without the agent ending the call is not saved**, because the hook only runs when the model emits `end_session`. Whether Google offers a session-ended hook for that case is UNVERIFIED. If hang-ups matter, add the Conversations API pull (below) as a backstop; it keys on the same session id.
- Keyed by the session id, so a second save (or the API backstop) updates the same row instead of adding one. Upsert by external id is Salesforce's documented behaviour; the skill did not write test rows.
- Optional `hide_tools` keeps the tool out of the model's view (unverified together with the hook). Without it the tool description says "do not call it yourself" and the instructions never mention it, which is the verified setup.
- `toolExecutionMode` must be `SEQUENTIAL`. In parallel mode `end_session` can finish the call before the save runs. The builder forces it and refuses an explicit PARALLEL; the validator warns on an imported package.
- If the save fails the call still ends (the tool returns `system_error`); the failure shows in the trace. A missed transcript never blocks the caller.

## Spec (see `assets/example-pharma-transcript/spec.json`)
1. Toolset operation: `{"kind": "upsert_record", "operationId": "save_transcript", "sobject": "Voice_Call_Transcript__c", "external_id_field": "Session_Id__c", "path_param": "session_id", "fields": [...]}`. The fields must match the Salesforce fields; the schema sets `additionalProperties: false`.
2. Tool: `{"name": "save_transcript", "template": "save_transcript", "params": {"connector_tool": "<toolset>_save_transcript"}}`. Omit `connector_tool` to use the REST transport with the token variable instead.
3. Agent: list `save_transcript` and `end_session` in `tools`; callback `afterModel: save_transcript_on_end {tool: "save_transcript"}` (this is the verified setup). Optional: `beforeModel: hide_tools {tools: ["save_transcript"]}` so the model can never call it; add it only after saving works, because a hidden tool being run by a callback is unverified.
4. Turn log redaction on (`app.logging.redaction: true`): Google's own redaction runs before Google stores logs, but the Salesforce copy is yours; the tool also masks card and SSN patterns (`redact_patterns`).

`save_transcript` params: `sobject`, `external_id_field`, `fields` (map from logical name to Salesforce field), `links` (Salesforce field to variable; default `Order__c` from `verified_record_id`, `Account__c` from `verified_scope_id`), `redact_patterns` (name to regex), `max_chars` (120000), `max_attempts`, `path_param`, `connector_tool`.

## Salesforce side (the user deploys; the skill never does)
Object `Voice_Call_Transcript__c`: `Session_Id__c` (external id, unique), `Transcript__c` (long text), `Started_At__c`, `Ended_At__c`, `Duration_Seconds__c`, `Turn_Count__c`, `Outcome__c` (picklist), `Caller_Verified__c`, `Agent_Name__c`, lookups `Order__c`, `Account__c`.
Permission set for the Run As user: create and edit on the object and its fields, nothing else. Assign it to the integration user named in the External Client App's Run As.
Ready-made copies live in `assets/salesforce-transcript-metadata/` (object with 11 fields, permission set `Voice_Agent_Transcript_Writer`); copy them into the user's `force-app/main/default/` and adjust names if the spec uses other fields. Provide these as files, check with `sf project deploy start --dry-run`, and let the user run the real deploy.

## Privacy checklist (raise it in the design proposal)
- A transcript holds personal data and sometimes health or payment details. Restrict the object (sharing and field-level security), set a retention period, and decide who may read it.
- Voice: a recording or transcription notice is usually required; the `static_greeting` disclaimer parameter speaks one.
- Redaction patterns are a safety net, not a guarantee. Say so.
- Never put the transcript text in logs the tool prints (the tool prints only counts and status).

## Other ways to get transcripts (mention as alternatives)
- **Conversations API**: pull finished sessions later (`turns[].messages[]`, role, chunks) and load them into Salesforce from a scheduled job. Nothing in the call path, but needs an API client with Google credentials and is not real time.
- **BigQuery export** of conversation data for analytics.
Choose the end-of-call tool when the transcript must sit next to the Order within seconds; choose the API pull when the call path must stay minimal.

## Tests
- `python3 $SKILL_DIR/scripts/build_agent.py <spec> --selftest` runs the tool scenarios (saved fields, escalation hint, never verified, truncation, no session id, empty transcript, 401, 500, missing fields).
- `python3 $SKILL_DIR/scripts/selftest_callbacks.py <package>` tests the callbacks.
- In the console: end a call by finishing the task, by escalation and by a wrong-detail lockout; open the record each time and compare turns, outcome and links. Then hang up mid-call and note whether a record appears (expected: none, see the known gap).
