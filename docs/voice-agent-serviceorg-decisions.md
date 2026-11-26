# Voice agent (Google CX Agent Studio) + serviceOrg: decisions, mistakes, ideas and open items

Written 2026-11-25 from the long Claude Code session of 18 to 25 Nov 2026 (transcript: `~/.claude/projects/<this-project>/570ea90f-a49c-4507-a6a6-2f35c579aeed.jsonl`; this workstream is the user messages from 2026-11-20 07:26 on). Purpose: a new session on this topic should not have to guess. Facts marked **(unverified)** were not confirmed.
Deliberately left out of this file so it is safe to publish: consumer keys and secrets, the Google Cloud project id and number, the sandbox host name, personal usernames. Where to find them is noted in section 2.

Other topics that came out of the same session and have their own files/sessions: Candidate Matcher V2 (`docs/candidate-matcher-v2-decisions.md`), Cases from transcripts (section 11 is a boundary note), token estimates (section 12 is a boundary note).

## 1. The project in one paragraph
A voice agent built in **Google CX Agent Studio (CES)** that talks to Salesforce. Flow, exactly as the user wrote the script: greet the caller **by name** (looked up from caller ID), verify by **email** (3 tries), give **order status**, **change the shipping address**, say a polite goodbye, and **save the whole call transcript to Salesforce**. It was first built against `demoOrg` (a Developer Edition org, Pharma/Abbott demo data) and then cloned for `serviceOrg` (a sandbox) where the transcript goes to `Chat_Conversation__c.Transcript__c`. A reusable Claude skill, `ces-agent-builder`, generates the agents and was updated as lessons came in.

## 2. How the user works (rules to follow)
- **Do not change the existing demoOrg agent**; use a copy/clone for new work ("I want to clone that agent and use it for the service org"). The user pastes console files themselves; Claude produces files and instructions.
- **"Give me the change in files. Do not deploy them. I'll deploy them manually."** was the standing rule early on. Later the user explicitly said "Deploy" for specific items (two permission sets, then the Apex classes, then the Case work). Default: show the files, run a **check-only** deploy (`sf project deploy start -o <alias> --dry-run ...`), ask, then deploy.
- **Plan first when asked** ("Do not do anything. First show me the plan and the files").
- **Same branch for all of this: `feature/voice-agent-transcript`.** The user does not want separate branches for customer service ("have all these changes in the same voice agent transcript branch itself"). **"Do not push the files to the branch. Just make the changes in the local itself."** Never push unless the user says so. The repo `yjain893/CandidateMatch` is **public**.
- **Never put a secret in a file or message.** The user did paste a consumer key and secret into chat on 2026-11-20 and a consumer key on 2026-11-24: **treat those as exposed and rotate them** (see section 10 item 8). The skill's rule: never ask the user to paste a key or secret; use `sf_oauth_check.py` (hidden prompts).
- Very simple language, step by step instructions, short answers; the user explains things to non-technical colleagues.
- **Script fidelity:** "Don't change anything from the script." No Abbott rules ("exclude D6 as well. I don't want any Abbott rules"). See 5.
- Org aliases: `demoOrg` (Developer Edition), `serviceOrg` (sandbox; real name of the admin user is in `sf org list`). Google console region `us`. The Google project id, the connector's server/tokens and the secret names live in `ces-agents/abbott-customer-service-serviceorg-baseline/import-ready/` (git-excluded on this Mac via `.git/info/exclude`) and in the console; ask the user rather than guessing.

## 3. What exists today (files and what they are)
| Path | What |
|---|---|
| `ces-agents/abbott-customer-service/` | demoOrg agent: `README.md`, `design.md` (the approved design), `spec.json`, `instructions/root.txt`, `console/` (paste-ready tools, callbacks, instruction, connector schema), `out/` (importable zip, placeholders for key/project), `spike/` (callback test, no longer needed) |
| `ces-agents/abbott-customer-service-serviceorg-baseline/` | serviceOrg agent copy: same layout; Salesforce reached through the Apex endpoint; transcript to `Chat_Conversation__c`; `import-ready/` (git-excluded; holds the project id and consumer key, never commit) |
| `ces-agents/exported-from-google-console/Pharma_Order_Assistant_exported_2026-11-21/` | the user's latest console export, sanitized (key and project id replaced by placeholders). The folder was renamed from "console exports" because the name was unclear |
| `docs/Voice-Agent-Setup-and-Lessons-Learned.{html,pdf}` | learnings PDF (20 pages: GCP, connected app, errors and fixes, transcript and phone chapters) |
| `claude-skills/ces-agent-builder/` | repo copy of the skill (the live one is `~/.claude/skills/ces-agent-builder/`; **the repo copy is behind the live skill unless re-synced**) |
| `force-app/main/default/classes/VoiceAgentApi*.cls` | Apex REST endpoint for serviceOrg (see 7) |
| `force-app/main/default/permissionsets/Voice_Agent_*.permissionset-meta.xml` | permission sets (see 7) |
| `force-app/main/default/objects/Voice_Call_Transcript__c` and permission set `Voice_Agent_Transcript_Writer` | the original transcript object, **demoOrg only**, obsolete for serviceOrg |
| `scripts/apex/voice_cs_demo_*.apex`, `voice_cs_rollback_test.apex` | demoOrg demo data, cleanup, rolled-back write test |
| `scripts/apex/serviceorg_demo_create.apex`, `serviceorg_demo_cleanup.apex`, `serviceorg_demo_rollback_test.apex` | serviceOrg demo data (create has been run) |

Skill (live at `~/.claude/skills/ces-agent-builder/`): `SKILL.md`, `scripts/` (`build_agent.py`, `validate_package.py`, `sf_discover.py`, `sf_oauth_check.py`, `export_console_files.py`, `compare_to_export.py`, `selftest_callbacks.py`, `run_examples.py`), `references/` (lessons-learned, caller-id-verification, transcripts, token-estimates, setup-gcp-and-salesforce...), `assets/` (7 example agents, tool and callback templates, transcript object metadata).

## 4. Architecture (verified in Preview)
1. **Python tool wraps Salesforce and calls a Salesforce connector** (an OpenAPI toolset in CES: OAuth client-credentials, secret in **Secret Manager**). The connector is **not attached to the agent**; the model only sees the Python tools. This was verified and keeps the model from calling the connector directly.
2. Connector settings: server = the org's host, token endpoint `<host>/services/oauth2/token`, consumer key, secret version path, **Google's OAuth scopes field left EMPTY** (a scope sent to Salesforce gives `invalid_request: scope parameter not supported`); the `api` scope is selected in the Salesforce **External Client App** instead ("Manage user data via APIs"; "Full access" does not work for client credentials).
3. **Python tools** (`identify_caller`, `verify_caller_email`, `get_order_status`, `get_shipping_address`, `update_shipping_address`, `save_transcript` + the system `end_session`) call the connector by name (`query_salesforce_<operationId>`). Tools return only chosen fields, one message for every failure, never confirm that an order exists, never invent a business fact.
4. **Variables:** `company_name` (static, "Abbott"), `telephony-caller-id` (exact name; platform fills it on real calls, a default is set for Preview and **must be cleared before go-live**), `caller_status`, `caller_name`, `caller_email`, `caller_contact_id`, `caller_account_id`, `last_order_id`, `caller_verified`, `verification_attempts`.
5. **Callbacks on the Root agent:** before agent `lookup_caller_on_start`; before model `greet_known_caller`, `escalate_on_system_error`, `inactivity_prompt`; after model `save_transcript_on_end` (adds closing words if the model ended silently, runs `save_transcript` before `end_session`). App tool execution mode **Sequential** (otherwise `end_session` can end the call before the transcript saves). Both default guardrails switched on.
6. Verified behaviours: a callback can run a tool directly (`mode: direct`); variables set by a before-model callback reach the model **one turn late**; text returned by a callback is **shown in chat but not spoken** while the model's own speech is; `<state_update>` notes show changed variables to the model.

## 5. Decisions taken, with the reason
### 5.1 Connector + Python tool together (20 Nov)
The user asked when to use the Salesforce connector and when Python. Decision: **both**: Python for logic (normalise phone digits, pad order numbers to 8, escape values, compare in code, return only chosen fields); the connector for the authenticated call to Salesforce. Reason: a free-form SOQL tool let the model write queries and phone matching failed; Python makes it deterministic and testable. Bearer-token-as-variable (a demo shortcut that put a live token in an export) was replaced by OAuth client credentials + Secret Manager.

### 5.2 The Abbott customer service script (21 Nov)
The user supplied a full call script (greeting by stored name and client name from a variable, email verification with max 3 tries, order status, address change, closing). Decisions:
- **Follow the script exactly.** The assistant had proposed extras D1 to D7; the user **rejected all** ("don't change anything from the script", then "exclude D6 as well. I don't want any Abbott rules"): D1 hashed email instead of plain, D2 postal-code check before an address change, D3 orders limited to the caller's account, D4 unknown-caller flow (order number + email), D5 status rule on which orders may be changed, D6 Abbott medical rules (escalate if caller reports a side effect; no medical advice), D7 extra guardrail on replies. **All rejected**; they are recorded in `design.md` section 10 as "could be added later in one step".
- Consequences the user accepted (listed in `design.md` s.10): any caller who passes the email check can read/change any order number; no second check or status rule on address changes (Shipped and Delivered orders can be changed); the email on file sits in a variable the AI can read (the instruction forbids saying it); caller ID can be spoofed.
- Gap filled by the assistant (user did not object): unknown number gives a greeting without a name, a short apology and a transfer to a team member.
- Client name goes in a CX variable `company_name` (static "Abbott").

### 5.3 Greeting, name and goodbye behaviours (21 to 23 Nov)
- Greeting text from a callback shown but not spoken: **the model speaks the greeting** (`speak: model`; the callback only looks the caller up; the instruction holds the exact words).
- Name missing in the spoken greeting: lookup moved to a **before-agent callback** plus a note written into the model request.
- Silent start when the user clicks the mic and says nothing: an explicit first-turn cue in the before-model callback and instruction text ("when I say nothing, the voice agent must start the conversation and greet me").
- Call ended without a goodbye: stronger instruction plus `closing_texts` in the end hook.
- The user confirmed each fix in Preview ("It is working now").

### 5.4 Git and file hygiene (21 Nov)
All voice work stays on `feature/voice-agent-transcript`. Obsolete files were listed and the user chose what to delete; the console export folder was renamed to `exported-from-google-console/`; the latest user export replaced the older one in the repo (sanitized). The skill was added to the same branch under `claude-skills/`.

### 5.5 Transcript saving (20 to 21 Nov, then serviceOrg 24 Nov)
- demoOrg: custom object `Voice_Call_Transcript__c` (+ permission set `Voice_Agent_Transcript_Writer`) with order/account links, outcome, verified flag; saved by the `save_transcript` tool, hooked into the end of the call.
- serviceOrg: the user chose to reuse the **existing `Chat_Conversation__c`** (no new object). Mapping: transcript to `Transcript__c`, `Conversation_Identifier__c` = session id (external id, so a repeat updates), `Start_Timestamp__c`, `End_Timestamp__c`, `Closed_At__c`, `Last_Message_At__c`, `Message_Count__c` (caller turns), `Has_Human_Agent__c` (true when escalated), fixed `Conversation_Status__c = Closed`. Not saved because the object has no field: outcome, caller verified, order/account links ("tell me if you want fields added" is open).
- Transcript text is redacted (card number, SSN patterns), `<event>` and `<context>` notes stripped, cut at 120,000 characters.

### 5.6 Moving to serviceOrg (24 Nov)
1. The user wanted the agent connected to `serviceOrg` and transcripts in `Chat_Conversation__c.Transcript__c`; **do not touch the existing agent, clone it**.
2. A new External Client App was created in serviceOrg; Run As user, client credentials flow, IP relaxation; secret stored in Secret Manager under a new name (`serviceorg-client-secret`, version 1) with the CES service account as Secret Accessor.
3. **Integration user attempt:** an integration user on the **Salesforce Integration** license with profile *Minimum Access - API Only Integrations* was created. Two permission sets were deployed (`Voice_Agent_Chat_Conversation_Writer` assigned; `Voice_Agent_Customer_Service` could **not** be assigned: that license cannot have Read/Edit on Account, Contact or Order).
4. **Options given and chosen:** (1) **Apex lookup** (chosen: "Apex lookup (recommended)"), (2) full-license Run As, (3) get another full license. The chosen Apex class `VoiceAgentApi` exposes `/services/apexrest/voiceagent/query` (two fixed lookups: order by number, contacts by last four phone digits, plus the pattern the tool sends) and `/voiceagent/order/{id}` (PATCH, only five shipping fields). A permission set `Voice_Agent_Apex_Access` lets the integration user call the class. Deployed and tests passed (8 of 8).
5. **It did not work** (see mistakes, 6.9): the integration license cannot query Contact/Order even through Apex. **Final working setup: the connected app's Run As user is the admin user on a full license** ("for the integration user I have used the admin user, and it is working fine for me now"). Accepted risks (stated to the user): the agent acts with admin permissions, depends on that person's account; **before anything real, switch Run As to a dedicated full-license user with only the permission sets we wrote.**
6. Demo data in serviceOrg (names start `DEMO - `): orders 00000109 to 00000114 (109, 110 Draft; 111, 112 Activated; 113 Shipped; 114 Delivered), contacts John (+14155550201), Maria (0202), Ahmed (0203); one product and price book entry. The existing contact Peter is the main test caller; his phone was changed by the user to 5155550101, so the Preview default must be `+15155550101` (and email peter's address; see the serviceOrg README). A phone number that matches **more than one contact is treated as unknown**: two contacts must never share a number.

### 5.7 Phone number (21 Nov, research only)
Google can provide a number from the console: **Deploy > Connect to a platform > Google Telephony Platform (GTP)**, connection type **standard PSTN** (the default is a virtual number an ordinary phone cannot dial). Real PSTN numbers only for apps in the **`us`** multi-region (in `eu` virtual numbers only). Callers from India dial +1 and the number as an international call. Free: no permanent free number; the browser widget in the Deploy tab tests without a phone; CES pricing seen: $0.50 per session (+ $0.0025/s over 5 minutes); number price not found; credits unconfirmed. **Never tried in practice.** Ideas not pursued: Twilio adapter, SIP trunk from a carrier, DTMF for order numbers, forwarding an existing number.

## 6. Mistakes made (so they are not repeated)
1. **Free-form SOQL tool** let the model build queries; phones stored as "(416) 555-0142" did not match. Fixed by Python normalisation.
2. **The agent invented a delivery date** ("Friday, 28th November") from a generated fallback default; no delivery-date field exists. Rule: never default a business fact. End date is the order's EndDate.
3. **A live access token was in an export** (variable defaults export in plain text). Rule: secrets ship empty; validate every export.
4. **Two SOQL operations on the same path** (`GET /query`): the second silently overwrote the first, so a tool called an operation that was not in the schema. Fix: one shared operation with a pattern allowing both shapes; the generator refuses duplicates; the validator checks every connector name a tool calls.
5. **Permission set deploy errors:** description over 255 characters; field-level security on `FirstName` and the address component fields (`Order.ShippingStreet` etc.) is invalid. Grant object permissions only; restrict what the agent changes in the tool and the schema.
6. **Template `%` formatting clash** (`%s` inside a template string) and **tests that hardcoded field names** broke when custom field maps were used. Fixed with plain string joins and scenarios that read field names from the config.
7. **Greeting shown but not spoken**, name missing, silent start, no goodbye: see 5.3 and the skill's lessons 33 to 35.
8. **Resource exhausted** in Preview: CES quota "RunSession LLM tokens per minute" is 1,000 and is not adjustable; test slower or wait.
9. **Assumed Apex would bypass the license limit; it does not (assistant's mistake, 24 Nov).** The Salesforce Integration license cannot access Contact/Account/Order even through Apex ("sObject type 'Contact' is not supported"). A test running as an API-only user reproduced the exact error, and rewriting dynamic SOQL as static SOQL did not help. The extra "Salesforce API Integration" add-on (5 free seats) did not help in a test and was **not assigned** (the auto-mode safety check blocked the assignment because it uses a license seat the user had not approved).
10. **Phone collision:** the assistant's demo contact John and the user's existing contact Peter shared 4155550101, so the lookup returned two matches and the agent treated the caller as unknown ("it's telling me to connect with the team member"). Fixed by moving the DEMO contacts to 0201 to 0203. Later Peter's number changed to 5155550101 and the Preview default was not updated, causing the same symptom again.
11. **`import-ready/` holds the project id and consumer key**: it is excluded from git locally only. Do not copy it into tracked folders.
12. Caught earlier: shell quoting/zsh glob problems (`--include=*.cls` gives "no matches found" in zsh); an `Edit` that aborted when the search text mismatched (nothing written); consumer secret copied with a trailing space is a classic cause of `invalid_client`.
13. The full list of 35 numbered errors with causes and fixes is in the skill (`references/lessons-learned.md`) and the learnings PDF; read it before debugging.

## 7. serviceOrg objects in play (so nothing is rediscovered)
- `Chat_Conversation__c` already existed: `Transcript__c` (long text 131,072), `Conversation_Identifier__c` (required unique external id, 100), timestamps, `Message_Count__c`, `Conversation_Status__c` (Open/Closed), `Has_Human_Agent__c`, `Analysis_Status__c`, `Transcript_Hash__c`. It also drives `Chat_Analytics__c` records (an AI analysis: bot resolution, escalation reasons) that existed before this work; the first four conversations (24 Nov 09:15 to 09:31) were failed test calls from the license-limit period and correctly show "Not Resolved / escalated".
- Permission sets in serviceOrg: `Voice_Agent_Chat_Conversation_Writer` (assigned to the integration user and to the admin user; has since gained field access for Case and token fields), `Voice_Agent_Apex_Access` (assigned to the integration user), `Voice_Agent_Customer_Service` (deployed, unassignable to the Integration license, no longer needed).
- The integration user exists but is idle (Run As is the admin user). The Apex class `VoiceAgentApi` is deployed in its original dynamic-query form and **works for admin-level users**. A stricter static-SOQL rewrite and an extra test (`worksForAnApiOnlyIntegrationUser`) exist **locally only** and fail by design under the license limit; do not deploy them without a decision.

## 8. Ideas discussed, with status
| Idea | Status |
|---|---|
| Generic "read any field / update any field" tools instead of one tool per field (user: "it should be dynamic") | **Plan only, not approved.** Proposal: two tools (`get_order_field`, `update_order_field`) driven by an **allowed-field list** in the spec (spoken names, SF field, type, max length, read/write), safety rules in code (never Status, TotalAmount, AccountId, OrderNumber, price book; read back old value; refuse on Salesforce error). Four decisions are waiting on the user: which fields may change, confirmation read-back (yes/no), locks once Activated, allowed list vs fully open (assistant recommends the list). |
| Conversations API backstop for hang-ups (a caller who hangs up leaves no transcript) | Not built. Known gap, worse on real phone calls |
| DTMF keypad for order numbers | Not built |
| Dedicated full-license Run As user with only our permission sets | Recommended before real use; not done |
| Phone number (GTP, PSTN, `us` region) | Researched only |
| D1 to D7 (see 5.2) | Rejected; could be added later |
| Block address changes on Shipped/Delivered | Not done (script has no status rule); the user was told |
| A skills spike for tool-in-callback | Done, no longer needed |
| Token estimates per call | Separate topic, see 12 |
| Case creation from transcripts | Separate topic, see 11 |

## 9. Verified vs unverified
**Verified in Preview:** the greeting by name, email check, order status, address read and change on a Draft order, transcript saved with links (demoOrg), transcript saved to `Chat_Conversation__c` (serviceOrg, with admin Run As), callback-run tool, Sequential execution, the goodbye, silent-start greeting.
**Not verified:** address change on an **Activated** order in demoOrg (serviceOrg demo includes Activated/Shipped/Delivered orders to test), other state/country values, real caller ID, **real phone calls**, the `tool_call` fallback mode, hang-up transcripts, the inactivity prompt and system-error apology being **heard** (they are callback text), the red "22 Steps" row seen once in an earlier Preview (never inspected), whether deleting a phone channel releases the number.

## 10. Open items
1. Generic field tools: the four decisions in section 8.
2. Dedicated full-license Run As user for serviceOrg; tell the owner of the admin account (the agent depends on it).
3. Remove the unused `Voice_Agent_Customer_Service` permission set and idle integration user (user was asked, no answer).
4. Decide whether `Chat_Conversation__c` needs fields for outcome, caller verified and order/account links.
5. Real phone number and a hang-up backstop.
6. Update the repo copy of the skill (`claude-skills/ces-agent-builder/`) from the live skill when the user wants it pushed.
7. Commit the local serviceOrg agent files, Apex files, scripts and permission sets to `feature/voice-agent-transcript` when the user says so (nothing is pushed unless asked).
8. **Rotate exposed credentials:** the demoOrg connected app consumer key and secret were pasted in chat on 20 Nov, and the serviceOrg consumer key on 24 Nov (the serviceOrg secret was never pasted). The assistant told the user that anything pasted is exposed.
9. The serviceOrg README still shows Peter's old number (+14155550101); the Preview default must be +15155550101.
10. Real use: the Abbott compliance question (a regulated healthcare company; demo with fictional data only; recording and data rules need a compliance check).
11. Pull a repository-wide check that no consumer key, secret or project id is in tracked files before any push (the last scan found none; the sandbox host name does appear in the already-pushed serviceOrg agent files, which is a host name and not a secret).

## 11. Boundary note: Cases from transcripts (own session)
Live in serviceOrg: a trigger `ChatConversationCaseTrigger` on `Chat_Conversation__c` (Status = Closed with a non-blank transcript) queues `CaseFromTranscriptQueueable`, which calls `CaseFromTranscript.createCase`, a prompt template `Create_Case_From_Transcript` (activated by the user) and creates a Case with subject, description, category, `Origin = Phone` and a lookup `Case.Chat_Conversation__c`. **This changes the end of every voice call in serviceOrg (a Case appears).** It is not pushed to git and the user said the manager had not yet approved changes to the voice agent; check before telling anyone it is live. A new Draft version of the "Summarise Case All Components" template adds the call transcript through `CaseTranscriptsForPrompt` (not yet published).

## 12. Boundary note: token estimates (own session)
Callbacks cannot read real token counts (verified); real counts exist in Cloud Logging (`LLM` and `TTS` spans, with the session id) after turning on "Enable Cloud Logging" in the app's logging settings. The chosen path: estimate in callbacks (`token_count_input`, `token_count_output`) with calibration, saved to five `Est_*_Tokens__c` fields on `Chat_Conversation__c` (deployed). Console steps are **not done**. Files: `ces-agents/token-usage-spike/`, the two callbacks under the serviceOrg agent's `console/callbacks/`, skill template and `references/token-estimates.md`.


## Folder cleanup, 26 Nov 2026
The folders `ces-agents/abbott-customer-service` (the older demoOrg agent), `ces-agents/exported-from-google-console` and `ces-agents/token-usage-spike` were deleted by the user's decision (superseded; they remain in git history). `ces-agents` now holds the baseline agent `abbott-customer-service-serviceorg-baseline`, the optimized copy `abbott-customer-service-serviceorg-optimized` and nothing else; the learnings document moved to `docs/Voice-Agent-Setup-and-Lessons-Learned.pdf` (updated 26 Nov with the token chapter). The baseline's estimate callbacks and `Est_*` fields were removed from its spec; it is labelled `Voice_Agent_Name__c = Baseline`. Mentions of the deleted folders in this file are historical.
