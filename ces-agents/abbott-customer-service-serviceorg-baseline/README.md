# Abbott Customer Service agent for the serviceOrg sandbox (the baseline)

A voice assistant that greets the caller by name, verifies them by email, reports order status and changes shipping addresses. Connected to **serviceOrg**. This is the **baseline** agent of the token comparison; the optimized copy is `../abbott-customer-service-serviceorg-optimized`.

## Contents
| Path | What it is |
|---|---|
| `spec.json`, `instructions/root.txt` | The agent definition and its instruction (7,666 letters) |
| `out/Abbott_Customer_Service_ServiceOrg.zip` | Importable package with placeholders (safe to share) |
| `import-ready/` | The same package with the real consumer key and secret version path filled in. **Excluded from git, never commit it.** No secret inside |
| `console/` | Paste-ready files for the console: `tools/` (6 Python tools), `callbacks/` (5), `root_instruction.txt`, `salesforce_schema.json` |

## What it has (nothing else)
- **Variables (10):** `caller_account_id`, `caller_contact_id`, `caller_email`, `caller_name`, `caller_status`, `caller_verified`, `company_name`, `last_order_id`, `telephony-caller-id`, `verification_attempts`.
- **Tools:** `identify_caller`, `verify_caller_email`, `get_order_status`, `get_shipping_address`, `update_shipping_address`, `save_transcript`, plus the built-in `end_session`. The Salesforce connector `query_salesforce` is used only by the Python tools.
- **Callbacks (5):** before agent: caller lookup; before model: greeting, system-error escalation, "Are you still there?"; after model: save the transcript at the end of the call.
- **Transcript label:** `save_transcript` sends `Voice_Agent_Name__c = Baseline`, so the Token Comparison dashboard can tell the agents apart.

## How it reaches Salesforce
Through the Apex endpoint `VoiceAgentApi` (two fixed lookups and a five-field address change). Calls are saved in `Chat_Conversation__c` (transcript, session id in `Conversation_Identifier__c`, status Closed, times, message count, human agent flag, `Voice_Agent_Name__c`). Real token counts are added about 2 minutes later by the Apex job (see `../../docs/token-counts-end-to-end-flow.md`); nothing in the agent counts tokens.

## Put it in the console
Paste the files from `console/` into a **copy** of the app (the zip import was not reliable for us): instruction, the six tools, the callbacks, then the connector schema. Keep Cloud Logging ON (App settings, Logging). For Preview set `telephony-caller-id` to the test contact's phone (and clear it before go-live). Full steps: `../../docs/voice-agent-build-guide.pdf`.

## Rebuild
`python3 ~/.claude/skills/ces-agent-builder/scripts/build_agent.py spec.json --selftest` (validator 0 errors, 66 offline scenarios). Then regenerate `console/` with `export_console_files.py spec.json out/Abbott_Customer_Service_ServiceOrg console`.

## Things to know
- Two contacts must never share a phone number: a number that matches several contacts is treated as unknown.
- Calls that end through the greeting or system-error callbacks do not save a transcript; a caller who hangs up without the agent ending the call is not saved.
- The email on file lives in `caller_email`; the instruction forbids saying it, which is a rule in text.
