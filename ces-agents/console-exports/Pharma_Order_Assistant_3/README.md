# Console export of the Abbott customer service agent (21 November 2026)

A copy of what was in the Google CX Agent Studio console after the changes were pasted in: seven Python tools, three before-model callbacks and one after-model callback, the Salesforce connector with its three operations, and sequential tool execution. This export came from a full Preview test call that worked.

Two values were replaced because this repository is public: the Salesforce consumer key (`REPLACE_WITH_CONSUMER_KEY`) and the Google Cloud project id in `environment.json` (`PROJECT_ID`). Put your own values back before importing this anywhere.

Left in as exported:
- `tools/authenticate_user` is the old order-and-phone tool. The agent no longer uses it and no instruction mentions it.
- The variables `verified_record_id` and `verified_scope_id` are not used by any tool any more.
- The default of `telephony-caller-id` is a fictional demo number used for Preview testing. Clear it before real use.
