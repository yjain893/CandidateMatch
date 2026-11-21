# Import, set up, test, troubleshoot

## Always do these before importing
1. `python3 scripts/validate_package.py <zip or folder>` shows 0 errors (build_agent.py already runs it and refuses to zip otherwise).
2. `python3 scripts/selftest_tools.py <out>/_selftest/scenarios.json` all scenarios pass (`build_agent.py --selftest` runs it).
3. Optional live proof, read-only, no token: `python3 scripts/live_read_check.py <package> --tool <name> --org <alias> --args '{...}' [--vars '{"caller_verified": true, "verified_scope_id": "..."}']`.
4. For a first-ever import in a project, import the **smoke package** (`assets/example-smoke/spec.json`, one agent, one tool) first; if it imports, import the real one.
   The generator reproduces the keys of two real console exports (Python tool, guardrails, and the OAuth Salesforce toolset with `environment.json`). Callback file paths and the non-default guardrail types come from the documentation and have not been imported by this skill.
5. OAuth packages: the toolset's secret version and token endpoint come from `environment.json` on import. The secret version path must exist in the target project and its service agent needs the Accessor role, otherwise the first call returns a 403.

## Import (Google CX Agent Studio console)
1. Open https://ces.cloud.google.com and pick the Google Cloud project.
2. In the app list open the app's context menu -> Import agent, or Create agent -> Import as new. Choose the zip.
3. An import creates the app, agents, tools, toolsets, guardrails and variables. Open the app and check "Tools", "Guardrails" and the variables.

## Set up after import
| Step | Why |
|---|---|
| Set the variable `salesforce_access_token` (POC): get a token with `sf org auth show-access-token --target-org <alias>` and paste it as the variable's default value. It expires in about two hours | The package ships it empty on purpose |
| Production OAuth: follow `setup-gcp-and-salesforce.md` (Secret Manager API, secret, Accessor role for the CES service agent, Salesforce app with the `api` scope and a Run As user), then test with `sf_oauth_check.py` | Secrets never live in the package |
| Check each agent's instructions show no red underline | An unresolved `{@TOOL: x}` means the tool name is not attached to the agent |
| Confirm the guardrails are enabled (the console shows a toggle) | Exports omit `enabled` when false |
| Deployment: choose channel and modality (voice or text) in the deployment settings | The app does not deploy itself |
| Create a version snapshot once it works | Roll-back point |

## Test in the simulator (Preview agent)
Run the scenarios from the design proposal. Minimum set:
1. Happy path with valid details: greeting, verification, answer, goodbye (`end_session` success).
2. Wrong detail twice, then correct: attempts counted, same message each time, no hint about which detail was wrong.
3. Three wrong attempts: lockout and escalation.
4. Unknown record: identical answer to a wrong detail.
5. System error: empty or expired token -> apology and escalation (callback fires).
6. Asking for another customer's data after verification: refused or not found (row-level scope).
7. Sensitive or out-of-scope topic: escalation or polite refusal.
8. Silence, interruption, a number said in words ("one two three four") and with fillers.
9. Writes (if any): the agent reads details back and waits for a yes before `caller_confirmed` is true.
10. Transcript saving (if used): finish a call normally, escalate one and lock one out; each leaves one `Voice_Call_Transcript__c` row with the right turns, outcome and Order/Account. Check the trace for `tool: transcript saved ...`. A caller hang-up is not saved (see `transcripts.md`).
Open the trace for each turn: tool inputs, results, variables, guardrail triggers.

## Troubleshooting
| Symptom | Likely cause and fix |
|---|---|
| Red underline "There is a problem with your instructions" | `{@TOOL: x}` not attached to the agent, wrong case, or the tool was removed. Attach it or fix the name |
| Tool returns `token_missing` | The token variable is empty. Set it |
| `salesforce_auth_failed` (401) | Token expired (about two hours) or wrong org. Get a new token; check you used the right alias |
| `salesforce_error` with code 400 | A field or object name does not exist or is not visible to the integration user. Run `sf_discover.py` and check field-level security |
| `salesforce_error` with code 403 | The integration user lacks object, field or API access |
| Always "details do not match" | No matching test data, phone stored in another field, or the order number format differs (check `pad` and normalization) |
| Console message "Secret Manager API has not been used" | Enable the API in the project (needed only for OAuth toolsets and API key auth) |
| `salesforce_error` with `code: 403` from the connector call | The OAuth chain failed. Test Salesforce alone with `sf_oauth_check.py`; then the secret value and the Secret Accessor role. See `lessons-learned.md` |
| Salesforce answers `scope parameter not supported` or `no valid scopes defined` | Leave Google's OAuth scopes empty; select the `api` scope in the Salesforce app |
| No transcript row after a call | Order of checks: the Run As user has the permission set; the connector operation `save_transcript` exists and its fields match Salesforce; the app is `SEQUENTIAL`; the agent lists `save_transcript` in its tools; the trace shows the tool call before `end_session` and its result. The tool's printed lines name the failing step; a 400 means a field or picklist value is not in Salesforce |
| The call ends silently after the tool step | A system error was escalated without speaking. Add the `escalate_on_system_error` callback; read the tool's `error` in Test Tool |
| Import rejects the zip | Compare with a fresh console export of a tiny app; run `validate_package.py <export> --inspect`; suspect toolsets or callback paths first and report the exact message |
| Agent says things the tool did not return | Tighten constraint 7-style rules, add an `llm_policy` guardrail on agent responses, lower thinking level, or return fewer fields |
| Greeting is generated, not the fixed one | The `static_greeting` callback is not attached, or the session-start event differs; check the trace |
| Slow replies | Remove `AGENT_RESPONSE` policies you do not need, reduce tools, use `thinkingLevel: LOW`, keep tools under 5 seconds |

## Reporting to the user
After building, say exactly: what was verified (validator, N offline scenarios, live read-only checks against which records), what was not (the console import, anything
marked DOCUMENTED or UNVERIFIED in export-format.md), and the manual steps left for them.
