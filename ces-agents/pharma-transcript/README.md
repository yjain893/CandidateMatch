# Save the call transcript to Salesforce (add-on for the Pharma Order Assistant)

Status: ran in the Preview simulator and saved a row (Nov 2026). The Salesforce files are deployed by you; nothing here deploys anything.

**Update (Nov 21):** `save_transcript.py` now strips the platform's `<context>agent speaking was interrupted ...</context>` notes from caller lines. If you pasted the first version, open the `save_transcript` tool, replace its code with this file and save. Nothing else changes.

## 1. Salesforce (you deploy; check first)
```bash
sf project deploy start -o demoOrg --dry-run --source-dir force-app/main/default/objects/Voice_Call_Transcript__c --source-dir force-app/main/default/permissionsets/Voice_Agent_Transcript_Writer.permissionset-meta.xml
```
Run it again without `--dry-run` to deploy. Then assign permission set `Voice_Agent_Transcript_Writer` to the integration user named in the External Client App's Run As.

## 2. Connector: add one operation
Open the Salesforce tool (`query_salesforce`) and replace its schema with `salesforce_schema.json` (it keeps `find_order` and adds `save_transcript`). Leave the other connector settings as they are.

## 3. Python tool
Create a Python tool named `save_transcript` and paste `save_transcript.py`. It calls `query_salesforce_save_transcript`.

## 4. Callbacks on the Root agent
- Optional, after saving works: Before model: add `before_model_hide_tools.py` (keeps `save_transcript` away from the model; not verified together with the end-of-call callback).
- After model: add `after_model_save_transcript_on_end.py` (runs the save just before `end_session`).
- Add `save_transcript` to the Root agent's tools. Do not mention it in the instructions.

## 5. Sequential tool execution
Set the app's tool execution mode to sequential, otherwise `end_session` can end the call before the save runs. (Where that setting sits in the console was not verified.)

## 6. Test
Finish a call, escalate one and lock one out. Each leaves one `Voice_Call_Transcript__c` row. Check the trace for `tool: transcript saved through the connector with argument shape N`. A caller who hangs up without the agent ending the call is not saved.
