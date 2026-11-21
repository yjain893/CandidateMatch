# Abbott Customer Service voice agent: what is here and how to use it

Status: built and tested offline, then **tried in the Preview simulator on 21 November**: one full call (greeting by name, email check, order status, address read, address change, goodbye) worked, saved a transcript with links, and changed the address of a Draft order in Salesforce.
The plan it follows is [design.md](design.md): your script exactly, no extra rules.

## What is in this folder
| Path | What it is |
|---|---|
| `spec.json`, `instructions/root.txt` | The agent definition (input of the skill's builder) and its instructions |
| `out/Abbott_Customer_Service.zip` | The importable package (placeholders for the connector login, see below) |
| `console/` | Paste-ready files for adding the agent to an existing app: `tools/`, `callbacks/`, `root_instruction.txt`, `salesforce_schema.json` |
| `spike/` | A 10-minute console test to run first |
| `../../force-app/main/default/permissionsets/Voice_Agent_Customer_Service.permissionset-meta.xml` | Permission set for the integration user (check-only validated) |
| `../../scripts/apex/voice_cs_demo_create.apex`, `voice_cs_demo_cleanup.apex`, `voice_cs_rollback_test.apex` | Demo data, its cleanup, and a rolled-back write test. **Not run** |

## What was checked
- Validator: 0 errors, 0 warnings. 60 offline scenarios across the 6 tools, 4 callback behaviour tests.
- Deliberate breakages of the tools, the callbacks, the connector schema and the validator: all caught.
- Every query a tool builds matches the pattern that locks the connector operation.
- **Proven in Preview:** a callback running the lookup and greeting by name, the stored name and email reaching later tools, email verification, the connector's address update (on a Draft order), the transcript with links.
- **Not checked:** an address change on an Activated order, other state and country values, real caller ID, real phone calls, the `tool_call` fallback mode, the welcome message every time (one start was silent, see below).

## Order of work
1. **Spike: no longer needed.** Your Preview call proved a callback can run the lookup (`direct`). The files stay for a future agent.
2. **Salesforce (you run these; check first):**
   ```bash
   sf project deploy start -o demoOrg --dry-run --source-dir force-app/main/default/permissionsets/Voice_Agent_Customer_Service.permissionset-meta.xml
   ```
   Then the same without `--dry-run`, and assign **Voice Agent Customer Service** next to **Voice Agent Transcript Writer** on the connector's Run As user.
   Demo data (read the file first): `sf apex run -o demoOrg --file scripts/apex/voice_cs_demo_create.apex`. Optional write test: `scripts/apex/voice_cs_rollback_test.apex` (everything is rolled back).
3. **Console**, on a copy of the agent (take a version snapshot first):
   1. Connector: replace the Salesforce tool's schema with `console/salesforce_schema.json`. One shared operation `find_order` serves the order and contact lookups; `update_order_address` and `save_transcript` are new or unchanged. Leave authentication alone.
   2. Variables: static `company_name` = `Abbott`. Dynamic, all Text unless noted: `telephony-caller-id` (exact name), `caller_status`, `caller_name`, `caller_email`, `caller_contact_id`, `caller_account_id`, `last_order_id`, `caller_verified` (Boolean, false), `verification_attempts` (Number, 0).
   3. Python tools: create `identify_caller`, `verify_caller_email`, `get_order_status`, `get_shipping_address`, `update_shipping_address` from `console/tools/`, and replace the code of `save_transcript` with the new file (the transcript links changed).
   4. Root agent: tools = the five above + `save_transcript` + `end_session` (remove `authenticate_user`). Instructions = `console/root_instruction.txt`.
   5. Callbacks on the Root agent, in this order. Before model: `before_model_1_greet_known_caller`, `before_model_2_escalate_on_system_error`, `before_model_3_inactivity_prompt`. After model: replace the code of the existing callback with `after_model_1_save_transcript_on_end` (verification failures get their own outcome). If the spike said `tool_call`, change `MODE = 'direct'` to `MODE = 'tool_call'` in the first one.
   6. App settings: tool execution mode **Sequential** (already set). Switch both default guardrails on.
   7. For Preview only: set the default of `telephony-caller-id` to `+14155550101` (John's demo number). **Clear it before go-live.**
4. **Test** in Preview, then query Salesforce for the transcript row:
   - Your script end to end (John, order status, address change, goodbye).
   - Wrong email twice then right; three wrong (polite end, outcome "Verification failed").
   - A number that is not in Salesforce (clear the default): greeting without a name, then an apology and a transfer to a team member.
   - A tool error (revoke the secret briefly): spoken apology and escalation.
5. Send me the new console export. `compare_to_export.py` shows what the console kept.

## Importing the zip instead
The zip contains placeholders (`REPLACE_WITH_CONSUMER_KEY`, `PROJECT_ID`) for the connector login. Fill them in the package's `toolsets/` and `environment.json` before importing, and never put the secret itself there. Pasting into a copy of your working agent avoids this.

## If the welcome message is silent
It happened once in Preview and the cause is not known (a call at 15:13 greeted correctly). The updated callback always returns a greeting, logs how long the lookup took, and the updated instruction makes the model greet if nobody has. Paste `console/callbacks/before_model_1_greet_known_caller.py` and `console/root_instruction.txt` again. If it still happens, open the first turn in the Preview trace and send me the line `callback: caller lookup took ... seconds` or the error next to it.

## Things to know
- The email on file is stored in the variable `caller_email`, as you asked. The AI can read variables, so the instructions forbid saying it; that is a rule in text.
- Orders are not limited to the caller's account, and an address change needs only the verified email (your script).
- Calls that end through the greeting or system-error callbacks do not save a transcript. Calls that end through `end_session` do.
- A caller who hangs up without the agent ending the call is not saved.
- A real phone number is still to do; see the learnings PDF.
