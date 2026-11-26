# Optimized voice agent (second agent for the token comparison)

Same assistant as `../abbott-customer-service-serviceorg-baseline` (same tools, callbacks, voice, settings, same Salesforce connection), with **shorter instructions and tool descriptions**. Built and tested offline only; **not imported, nothing deployed**.

## What is different
| | Baseline (existing) | Optimized |
|---|---|---|
| Instruction (`instructions/root.txt`) | 7,666 letters | 4,219 letters (-45%) |
| Tool descriptions the model reads (6 Python tools) | 3,075 letters | 1,968 letters (-36%) |
| Callbacks | greeting, escalate on error, inactivity, save transcript (+ caller lookup) | exactly the same |
| Label saved on every transcript (`Voice_Agent_Name__c`) | `Baseline` | `Optimized` (fixed value in the save tool) |
| App name | Abbott Customer Service ServiceOrg | Abbott Customer Service ServiceOrg Optimized |

Everything the agent says (greeting, verification question, order status sentence, address sentences, goodbye, escalation) and every rule (verify before sharing, never say the email, never guess, always speak before `end_session`, never mention internal tools) is kept word for word. The shortening removes repetition and merges the task flow into one list. **Check it in Preview before the demo.**

## Files
- `spec.json`, `instructions/root.txt`: the definition and the optimized instruction.
- `optimize_descriptions.py`, `build.sh`: build the package (build, shorten tool descriptions, validate, zip). Run `./build.sh`.
- `out/Abbott_Customer_Service_ServiceOrg_Optimized.zip`: package with placeholders (safe to share).
- `import-ready/Abbott_Customer_Service_ServiceOrg_Optimized.zip`: **the one to import.** The consumer key and the secret version path are filled in from your current import-ready package. This folder is excluded from git. It holds no secret (only the key and the secret's version path).

## Import the optimized agent
1. Salesforce first (so transcripts can be labelled): deploy the field `Voice_Agent_Name__c` and the permission set `Voice_Agent_Access`.
2. CX Agent Studio: import `import-ready/Abbott_Customer_Service_ServiceOrg_Optimized.zip` as a new app (same project, same secret in Secret Manager).
3. In the new app turn on **Cloud Logging** (App settings, Logging) so the real token counts exist. Set the Preview default of `telephony-caller-id` to the same test number as the baseline.
4. Try one Preview call. A new transcript appears; about 2 minutes later its token fields fill in, and `Voice_Agent_Name__c` says `Optimized`.

## The baseline
The existing agent is `../abbott-customer-service-serviceorg-baseline`. It is already labelled `Baseline` by its own `save_transcript` tool (`Voice_Agent_Name__c = Baseline`), so nothing else needs patching.

## Fair demo
- Use the **same script** on both agents (same caller, same order number, same address change, same goodbye), 3 or 4 times each.
- The dashboard shows the average tokens per call by agent and the percent difference.
- Thinking tokens vary a little between runs: use averages, not one call.
