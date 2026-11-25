# Abbott Customer Service agent for the serviceOrg sandbox

Same assistant as `../abbott-customer-service`, connected to **serviceOrg** instead of demoOrg. Built and tested offline (65 tool scenarios, 5 callback tests); **not yet tried in the console**.

## How it differs
- The integration user has the Salesforce Integration license, which cannot read Contacts, Accounts or Orders. So the agent reaches them through the Apex endpoint `VoiceAgentApi`, which accepts only two fixed lookups and a five-field address change.
- Calls are saved in `Chat_Conversation__c` (transcript in `Transcript__c`, session id in `Conversation_Identifier__c`, status Closed, start, end, closed time, last message time, message count, human agent flag). There are no fields for outcome, caller verified, order or account, so those are not saved.

## Salesforce files (serviceOrg)
| File | State |
|---|---|
| `classes/VoiceAgentApi.cls` and its `-meta.xml` | check-only validated, **not deployed** |
| `classes/VoiceAgentApiTest.cls` and its `-meta.xml` | 8 of 8 tests pass in the check-only run |
| `permissionsets/Voice_Agent_Apex_Access` | check-only validated, **not deployed**; to be assigned to the integration user |
| `permissionsets/Voice_Agent_Chat_Conversation_Writer` | deployed and assigned |
| `permissionsets/Voice_Agent_Customer_Service` | deployed but cannot be assigned to this license; no longer needed in serviceOrg |

## Google console
Same steps as the demoOrg agent (`../abbott-customer-service/README.md`), with these differences: paste `console/salesforce_schema.json` (server is the sandbox address, three operations: `run_query`, `update_order_address`, `save_transcript`); the connector's login settings use the serviceOrg connected app (new consumer key, new secret in Secret Manager, token URL on the sandbox address, scopes empty). The Python tools are in `console/tools/` and the callbacks in `console/callbacks/`.

## Demo data in serviceOrg and test numbers
Created by `scripts/apex/serviceorg_demo_create.apex` (undo with `serviceorg_demo_cleanup.apex`): 3 `DEMO - ` accounts, 3 contacts, 6 orders (109 to 114: 2 Draft, 2 Activated, 1 Shipped, 1 Delivered).
Test callers: use the existing serviceOrg contact whose phone you set as the `telephony-caller-id` default (keep that default in step with the contact's phone in Salesforce), or the DEMO contacts created by `scripts/apex/serviceorg_demo_create.apex` (John +14155550201, Maria +14155550202, Ahmed +14155550203; fictional). A number that matches more than one contact is treated as unknown.
Two contacts must never share a phone number: the agent treats a number that matches several contacts as unknown.

## Estimated token counts per call (new, not yet in the console)
Google does not let a callback read real token counts, so the agent estimates them: letters seen divided by a ratio. Real numbers exist only in Cloud Logging (`LLM` and `TTS` spans).
Saved on the transcript record in five fields: `Est_Model_Input_Tokens__c`, `Est_Model_Output_Tokens__c`, `Est_Voice_Input_Tokens__c`, `Est_Voice_Output_Tokens__c`, `Est_Total_Tokens__c`.

**Formulas** (starting rates, calibrate them): model input = letters sent to the model / 3.5 (everything it reads: instructions, tools, the whole conversation so far, tool results; added for every model call). Model output = letters the model writes (text plus tool call name and arguments) / 3.5. Voice input = spoken letters / 3. Voice output = spoken words / 2.2 words per second * 25 tokens per second. Total = the four added up.

**Console steps (after the Salesforce fields are deployed):**
1. Variables (Number, default 0): `tokens_in_est`, `tokens_out_est`, `tts_in_est`, `tts_out_est`, `tokens_total_est`. Text variable `token_calibration` (calibration log, remove later).
2. Root agent, **Before model**: add `console/callbacks/before_model_4_token_count_input.py` as the LAST callback.
3. Root agent, **After model**: add `console/callbacks/after_model_1_token_count_output.py` as the FIRST callback, above the save-transcript one (replace its code with `after_model_2_save_transcript_on_end.py` only if it changed).
4. Replace the code of the `save_transcript` Python tool with `console/tools/save_transcript.py` and the Salesforce connector schema with `console/salesforce_schema.json` (the transcript operation gained five number fields).
5. Calibrate (see below), then set the rates in the two files and turn `DEBUG` off.

**Calibration (2 or 3 Preview calls):** run a call, open the `token_calibration` variable, and open Logging > Logs Explorer for the same session id. The log lists, per model call, `conv=` (letters of conversation), `instr=` and `tools=` (letters of instructions and tool definitions, 0 if the request does not carry them), `fixed=`. Compare with the real `input token count` of the same `LLM` span:
- If `instr` and `tools` are 0, the request does not include them: set `FIXED_OVERHEAD_CHARS` to (real tokens * 3.5 - conv letters), about 14,000 for this agent.
- Real ratio = letters / real tokens; put it in `CHARS_PER_TOKEN`. Repeat for output, voice input (`CHARS_PER_TOKEN_TTS`) and words per second.
Estimates are not Google's exact counts: expect 10 to 20 percent error. Not counted: the guardrail's own model, text added by the save-transcript hook, calls that end by hang-up (no transcript is saved).
