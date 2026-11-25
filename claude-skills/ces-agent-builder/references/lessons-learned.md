# Lessons learned: errors we hit building a Salesforce voice agent on CX Agent Studio, and the fixes

Every row happened in practice. Read the matching row before debugging.

## Instructions and tools
| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Red line "There is a problem with your instructions" under `{@TOOL: Authenticate_user}` | The reference did not match a tool attached to the agent (capital letters, tool never saved, tool removed) | Tool names are lower snake_case and case sensitive; attach the tool to the agent, then copy the exact name into the reference |
| 2 | "Bearer token" field will not accept a pasted token | It is a dropdown of variables, not a text box | Create a text variable, put the token in its default value, select it (`$context.variables.<name>`). Only for demos |
| 3 | An export contained a live access token | Variable defaults are exported in plain text | Ship secrets empty; validate every export; never send an export that holds a secret |
| 4 | Free-form query tool let the model write SOQL; phone numbers did not match | The model builds the query; Salesforce stores phones as typed ("(416) 555-0142") | Python wrapper tool: normalize digits (last 10), pad order numbers to 8, escape or digit-only values, compare in code, return only chosen fields |
| 5 | The agent invented a delivery date | A fallback default ("Friday, 28th November") in generated code, and no delivery-date field exists | Never default a business fact; return only what Salesforce returned; instruct "never guess a date"; EndDate is the order end date |
| 6 | The agent hung up silently on errors | The instruction says escalate, but the model spoke nothing before `end_session` | Use the `escalate_on_system_error` callback (fixed apology plus escalated end) |
| 7 | Verification passed with a blank phone on the record | Comparison ran without a blank-value guard | A blank stored value never matches; tests cover it |
| 8 | Caller sees which detail was wrong | Different messages for unknown order and wrong phone | One message for every failure; never confirm that an order exists |

## Salesforce
| # | Symptom | Cause | Fix |
|---|---|---|---|
| 9 | `sf org display` shows a placeholder, not a token | The CLI now redacts secrets | `sf org auth show-access-token --target-org <alias>` (expires in about two hours) |
| 10 | `invalid_client_id` | Wrong or empty consumer key; shell variables not set in this terminal tab | Re-copy the key; `echo ${#SF_KEY} ${#SF_SECRET}` must show two numbers above 0 |
| 11 | `invalid_grant: no valid scopes defined` | The External Client App has no scope that works for client credentials ("Full access" does not) | Select **Manage user data via APIs (api)**, save, wait a minute |
| 12 | `invalid_request: scope parameter not supported` | A scope was sent in the token request (Google's "OAuth scopes" field was filled) | Leave Google's OAuth scopes field **empty**; the scope belongs to the Salesforce app |
| 13 | `unsupported_grant_type` / `no client credentials user enabled` | Flow not enabled, or no Run As user | Settings tab (flow enablement) and Policies tab (Enable Client Credentials Flow, Run As user) |
| 14 | Token fine, query returns 403 | Run As user lacks API Enabled or field access | Fix the profile or permission set; test with `sf_oauth_check.py --soql` |
| 15 | `IP restricted` | IP Relaxation is "Enforce IP restrictions" and Google's addresses vary | Relax IP restrictions on the app (tighten later) |
| 16 | Orders cannot be activated or deleted | Activation needs order items; an activated order must return to Draft before delete | Create items first; the cleanup script sets Draft before deleting |

## Google Cloud and CX Agent Studio
| # | Symptom | Cause | Fix |
|---|---|---|---|
| 17 | Message "Secret Manager API has not been used in project ... or it is disabled" | The API is off (needed for OAuth and API keys) | Enable the API; wait a few minutes; then retry |
| 18 | Tool returns `salesforce_error` with `code: 403` | The OAuth chain failed (Salesforce login rejected, or the CES service agent cannot read the secret) | Test Salesforce alone first (`sf_oauth_check.py`); then check the secret's Permissions tab and the secret value |
| 19 | The agent works in Preview but the whole call ends after the tool step | System error handled by escalation | Run Test Tool on the Python tool; read the `error` value; use the table above |
| 20 | Worry that Python cannot call a connector that is not attached to the agent | Unverified at first | Verified: it works, and keeps the model from calling the connector directly |
| 21 | Test Tool output looks wrapped (`response.result`) | The console wraps a tool's return value | Read the result object inside; the generated code handles both plain and `{"result": ...}` bodies from the connector |
| 22 | Default Prompt Guardrail seems off | An export with no `enabled` key means disabled | Check each guardrail toggle in the console; the skill writes `enabled: true` |

## Transcripts (verified in the Preview simulator, Nov 2026)
| # | Symptom | Cause | Fix |
|---|---|---|---|
| 23 | Worry that `end_session` finishes the call before the transcript is saved | Tools run in parallel by default | Verified: with app execution mode **Sequential** and the after-model callback, the save ran first and the row appeared (outcome Completed, turns, duration and Order/Account links correct) |
| 24 | Caller lines in the saved transcript start with `<context>agent speaking was interrupted. user only heard '...'...</context>` | The platform adds barge-in notes to the caller's turn | The tool now strips `<context>...</context>` notes (template updated; re-paste the tool in older agents) |
| 25 | Which session is which in Salesforce | Preview sessions get ids that start with `simulator-` | Filter on `Session_Id__c LIKE 'simulator-%'` to separate test calls from real ones |
| 26 | A caller who hangs up leaves no transcript | The hook only runs when the agent emits `end_session` | Known gap; pull finished sessions through the Conversations API as a backstop (same session id, so no duplicates) |
| 27 | A callback's folder in an export is `after_model_callbacks_01`, not its template name | The console numbers callbacks | Tell callbacks apart by their code (`selftest_callbacks.py` does) |

## Customer service agent build (Nov 2026, offline)
| # | Symptom | Cause | Fix |
|---|---|---|---|
| 28 | A tool calls a connector operation that is missing from the generated schema, although the spec lists it | Two `soql_query` operations are both `GET /query`; the second silently replaced the first | One operation whose `q_pattern` allows both query shapes. The generator now refuses duplicates, the validator checks every connector name a tool calls, and the offline tests check each query against the pattern |
| 29 | Permission set deploy fails: "Invalid field permission field name Order.ShippingStreet" (also Contact.FirstName) | Name and address component fields have no field-level security; the description is limited to 255 characters | Grant object permissions only. Limit what the agent changes in the tool and the connector schema, not in the permission set |
| 30 | A greeting by first name needs the lookup before the first word | A callback calling a tool was documented but unproven | Verified in Preview: `mode: direct` works. `assets/spike-callback-tool` is only needed if it stops working; `tool_call` is the fallback |
| 31 | A call ended by a before-model callback may not save its transcript | Inference: the after-model hook probably does not run on a response a before-model callback produced (unverified) | End through the agent's own `end_session` (instructions) when the transcript matters |
| 33 | The greeting appears in the Preview chat but is not heard on the call (seen on two Preview starts) | A text response that a before-model callback returns at session start shows as text but was not voiced. The exact cause is not proven (the call's audio may not be ready that early, or callback text is not voiced) | The agent's own model says the greeting: the callback only looks the caller up and stores variables (`speak: model`, the default), and the instruction holds the exact words. Check it by listening |
| 34 | The call ended with no goodbye (the saved transcript has no closing line) | The model made the `end_session` call with no words, once; an instruction alone is not a guarantee | The instruction says to always speak together with the tool call, and the after-model hook adds closing words (`closing_texts`) when the model ended the call silently |
| 35 | The greeting is now spoken but without the caller's name, although the lookup worked | A before-model callback sets variables after that turn's request is built, so the model sees them only on its next turn | Do the lookup in a before-agent callback (the documented place for setting up state before the agent runs, `lookup_caller_on_start`), and let the before-model callback also write the caller into the request itself (`<state_update>` notes). The instruction reads the name from `{caller_name}` or that note |
| 32 | The AI does not seem to know a flag that is still at its default | Variables reach the AI only as `state_update` events when they change | Use a value that always changes when set (`known` or `unknown`), not a true/false default |

## Working practices that saved time
- Test one hop at a time: Salesforce OAuth in a terminal, then the connector, then the Python tool in Test Tool, then Preview.
- Never ask a user to paste a key or secret into chat. Have them run `sf_oauth_check.py` (hidden prompt, token never printed). If one is pasted anyway, treat it as exposed and rotate it.
- Offline scenarios and a read-only live check prove tool logic before the console is involved; deliberately break a copy of the code to prove the tests notice.
- Read a generated schema before trusting a passing test: tests that never open the schema cannot see a lost operation.
- After the user changes the agent in the console, ask for the new export and diff it (`compare_to_export.py`): it shows what the console kept, renamed or added, and it turned guesses (callback folders, execution mode) into facts.
- Read-only check against the org after a test call (a SELECT on the new object, without the long text field first) proves the whole chain better than the trace alone.
- Docs: Google's pages are available as plain text by appending `.md.txt`; compare any plan with a real console export (it is the ground truth for file layout).
