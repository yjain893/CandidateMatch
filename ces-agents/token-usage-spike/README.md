> Superseded: the real build is the `token_count_*` callbacks (see `ces-agents/abbott-customer-service-serviceorg/README.md`, section on estimated token counts). Both probes below are done: callbacks cannot read real token counts.

# Spike 2: do the session events carry token usage?

Spike 1 showed the model response has no usage fields. This version looks inside `callback_context.events` (and `state`, `actions`).
Replace the code of the existing probe callback with the new file, and clear the `usage_probe` variable (or start a new Preview session).

# Spike 1 (done): can a callback see token usage?

Answers one question before anything is built: does the model response (or the callback context) expose token counts?
Do it in a **copy of the agent or a test app**, not the live one. Nothing here touches Salesforce.

## Steps
1. Variables: add a Text variable named exactly `usage_probe` (empty default).
2. Root agent, Callbacks, **After model**: add a new callback and paste `after_model_usage_probe.py`. It always returns nothing, so the replies are not changed. Put it last in the list.
3. Open Preview, run a short call (greeting, one question, goodbye).
4. Open the variables panel and copy the value of `usage_probe`. If the panel is empty, look in the trace for `state_update` entries for it, and send me the text.

## How to read the result
| `usage_probe` shows | Meaning |
|---|---|
| `usage_metadata.prompt_token_count = 123` (numbers) | Real counts exist. I can add them up per call and send them to Salesforce |
| `usage_metadata.* = MISSING` and no `usage`/`token` attributes listed | Not exposed. We estimate from the transcript, or use Google Cloud reports |
| `PROBE FAILED ...` | Tell me the message; I adjust the probe |
| variable stays empty | A callback after the model cannot set variables; I switch the probe to a different place |
