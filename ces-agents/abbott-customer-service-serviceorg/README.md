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
Test numbers: Peter (existing contact, peter@gmail.com) is **+14155550101**; the demo contacts are John **+14155550201** (john.demo@example.com), Maria +14155550202 and Ahmed +14155550203.
Two contacts must never share a phone number: the agent treats a number that matches several contacts as unknown.
