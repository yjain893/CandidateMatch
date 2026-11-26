# Token counts per voice call: decisions, mistakes, ideas and open items

Written 2026-11-25 from the long Claude Code session of 18 to 25 Nov 2026 (transcript: `~/.claude/projects/<this-project>/570ea90f-a49c-4507-a6a6-2f35c579aeed.jsonl`; this workstream is the user messages from 2026-11-25 05:15 to 10:34). Purpose: a new session should not have to guess. Facts marked **(unverified)** were not confirmed. Related: `docs/voice-agent-serviceorg-decisions.md` (the agent) and `docs/cases-from-transcripts-decisions.md`.
Left out on purpose so it is safe to publish: keys and secrets, the Google project id, the sandbox host name, personal names.
The full flow (easy version) and the technical setup record (certificate, External Credential, Named Credential, service account, logging, errors, decisions) are in `docs/token-counts-end-to-end-flow.md`.
**Read section 11 first: on 26 Nov the estimate approach (sections 4 to 7, 9, 10) was replaced by exact counts read from Google's logs inside Salesforce. Section 11 also holds the decision on the optional 15-minute schedule.**

## 1. The question
Can the voice agent (Google CX Agent Studio) measure its token use per call and save it on the `Chat_Conversation__c` transcript record in Salesforce (serviceOrg)? The user wants this for cost visibility (earlier in the session they had a related manager question about where Salesforce stores prompt template tokens; that is a different, Salesforce-side topic).

## 2. How the user works (rules to follow)
- Plan first, then build, then ask before deploying. "Tell me the plan. What files will you change or create, and the flow of the architecture, and only if I approve, start building and deploying" (25 Nov). They approved the plan, then "Yes, deploy" for the Salesforce fields.
- **Do not change the existing voice agent until the manager approves.** Console steps must be done on a **copy** of the agent, never the live one. The user pastes console files themselves.
- **Do not push to git unless asked**; the repo is public. The token work was committed and pushed to `feature/voice-agent-transcript` on the user's request (commits `7cd67aa`, `153b3de`, `b3751a8`, 2026-11-25).
- **Explain in very simple language, like to a child.** The user said several explanations "are still not clear"; use small concrete examples, real conversations and tables, say where each number comes from, and say what is made up. Do not use jargon without explaining it.
- No secrets in files or chat.

## 3. Findings (what is verified)
1. **Callbacks cannot read real token counts.** Probe 1 (an after-model callback printing everything exposed) showed `llm_response` has only `content`, `partial`, `turn_complete` (plus pydantic helper methods); `callback_context` has no usage field (it has `events`, `state`, `actions`, `session_id`, `variables`). Probe 2 looked inside `callback_context.events` (a list of `Event` objects with `actions, author, branch, content, error_code, error_message, grounding_metadata, id, interrupted, invocation_id, partial, timestamp, turn_complete`): **no usage field**. `state` holds only our variables; `actions` holds only flags such as `end_invocation`.
2. **The real counts exist only in the platform trace:** Preview's "Raw response in JSON" and, once **Enable Cloud Logging** is on in the app's logging settings (it was off, the user turned it on; **Export logs to BigQuery** stayed off), Cloud Logging entries in the log `ces.googleapis.com/responses` (`jsonPayload.diagnosticInfo.rootSpan.childSpans`, labels `session_id`). Find them in Google Cloud Console > Logging > Logs Explorer (the item is not in the left menu: open `https://console.cloud.google.com/logs/query?project=<project>`), query by session id, time range last hour. Entries are per turn (`turnIndex`).
3. **Span contents:** `LLM` spans have `input token count`, `output token count`, `thought token count`, `model` (`gemini-composite-v2`); `TTS` spans have `input token count`, `output token count`, `tts input token count`, `tts output token count`, `audio duration (ms)`, `speculative`. A `Guardrail` span runs a separate small model (`gemini-3.5-flash-lite`); its tokens are **not** in the LLM span.
4. **Real data points (one call, turn 4):** three model calls with input 4,254 / 4,332 / 4,419, output 20 / 24 / 67, thought 0 (total 13,005 in, 111 out); TTS 63 in and 378 out for 15.12 s of audio. Another turn: TTS 12 in, 61 out for 2.44 s. Both give **25 TTS output tokens per second** (exact). Input per model call is about 4,200 to 4,400 tokens even for a tiny conversation, because instructions and tools are re-sent each time and the conversation adds only about 80 to 90 per exchange.
5. Redaction is on, which hides sensitive text in logs but not numbers.

## 4. Options considered
| Option | What | Status |
|---|---|---|
| **A. Estimate in the callbacks** | A before-model callback counts the letters sent to the model, an after-model callback counts the reply and the voice, divides by calibrated rates, and keeps running totals in variables that the save-transcript tool sends to Salesforce | **Chosen by the user** ("I like this idea of estimating") |
| **B. Exact numbers from Google's logs** | A scheduled job (Cloud Run job + Cloud Scheduler) reads each finished session's spans from Cloud Logging, adds the LLM and TTS counts, and writes them to the transcript. Also possible: a log sink to Pub/Sub and a function | **Not built**; fully planned. Needs: Cloud Logging stay on, a log-reader service account, Salesforce client-credentials login (secret in Secret Manager), the five fields. Totals arrive minutes after the call. Works only for calls after logging was switched on, and only for calls with a saved transcript |
| **C. Manual** | Read the trace in Preview | Only for testing |
Per-client deployment discussion (for the exact-number option B): (1) install the helper in **each client's own Google project** (about 20 to 30 minutes each with a script; the client owns it), (2) one central helper in the user's own project reading each client's logs after the client grants one read permission (less work, but the user holds access to transcripts), (3) no Google setup at all, which is option A. Recommendation given: A or B-in-client-project for a pilot; central helper only after a security review. **The user has not chosen between these for real clients.**

## 5. The estimate design (option A) and its formulas
Starting rates (generic guesses, to be calibrated): `chars_per_token_in` 3.5, `chars_per_token_out` 3.5, `chars_per_token_tts` 3, `words_per_second` 2.2, `tts_tokens_per_second` 25.
- Model input (per model call) = letters in the request / 3.5 (everything the model reads: instructions, tool declarations, the whole conversation so far, tool results; added for **every** model call).
- Model output = letters of the reply (text plus tool-call name and arguments) / 3.5.
- Voice input = spoken letters / 3; voice output = (spoken words / 2.2) x 25.
- Total = the four added up.
- **What the model sees (the "rulebook"):** the agent instructions (`root_instruction.txt` is 7,666 letters, about 2,200 tokens) and the tool declarations (name, description, parameters). **Not** the Python code of tools or callbacks. In the real call, about 14,900 letters per model call, so roughly 7,000 letters beyond the instructions came from tool declarations, Google's own added text, variables and the conversation (inferred by subtraction, not measured). **Unverified: whether `llm_request` carries the system instruction and tool definitions to the callback.** The debug log prints `instr=` and `tools=`; if they are 0, set `fixed_overhead_chars` (about 14,000 for this agent) during calibration.
- Letters-per-token is an exchange rate because the callback cannot see Google's token counts. The rates are calibrated by comparing the callback's letter counts with the real counts in Logs Explorer.

## 6. What was built
| Item | Where | State |
|---|---|---|
| Callbacks | `ces-agents/abbott-customer-service-serviceorg-baseline/console/callbacks/before_model_4_token_count_input.py` (LAST before-model callback), `after_model_1_token_count_output.py` (FIRST after-model callback, above save-transcript) | Written, tested offline; **NOT pasted into the console** |
| Variables (Number, default 0) | `tokens_in_est`, `tokens_out_est`, `tts_in_est`, `tts_out_est`, `tokens_total_est`, plus Text `token_calibration` (debug log) | The user said they added the variables; callbacks not added |
| Save tool | `console/tools/save_transcript.py` sends the five variables as `Est_*` fields; connector schema `console/salesforce_schema.json` has the five fields | Written; **not pasted into the console** (until it is, the new fields are not sent) |
| Salesforce fields | `Chat_Conversation__c.Est_Model_Input_Tokens__c`, `Est_Model_Output_Tokens__c`, `Est_Voice_Input_Tokens__c`, `Est_Voice_Output_Tokens__c`, `Est_Total_Tokens__c` (Number 18,0) + field access in `Voice_Agent_Chat_Conversation_Writer` | **Deployed to serviceOrg** (user approved) |
| Spec | `spec.json` has the two callbacks with `debug: true` and `variable_fields` on the transcript tool | Done |
| Skill | `token_count_input` / `token_count_output` templates (`scripts/ces_lib/callbacks.py`), `variable_fields` support (`tools.py`, `save_transcript.py.tmpl`), ordering checks in `build_agent.py` (output counter before the save hook; counters used as a pair; input counter last), tests (`selftest_callbacks.py`, `run_examples.py`), `references/token-estimates.md`, a line in `SKILL.md` | Done and synced to the repo copy |
| Old probe | `ces-agents/token-usage-spike/` (two probe versions, now superseded) | Local note says superseded. **The old `usage_probe` after-model callback and variable are still on the user's agent: delete them** (they write "[Input too large]" every turn) |
Offline checks that passed: validator 0 errors and 0 warnings, 75 of 75 tool scenarios, callback tests including both counters, `run_examples.py` 7 of 7, three wrong setups refused.

## 7. Console steps still to do (user, on a COPY of the agent)
1. Variables as in section 6.
2. Add `before_model_4_token_count_input.py` as a NEW before-model callback, last in the list (below greeting, escalation, inactivity).
3. Add `after_model_1_token_count_output.py` as a NEW after-model callback, **first** (above the save-transcript callback). Delete the old usage probe callback and its variable.
4. Replace the code of the `save_transcript` Python tool with `console/tools/save_transcript.py` and replace the Salesforce connector schema with `console/salesforce_schema.json`.
5. Run 2 or 3 Preview calls; copy `token_calibration` from the Variables row of the last turn (Preview left panel > the turn > Variables) and the session ids; compare with Logs Explorer; then set the real rates in the two files and turn `DEBUG` off.
Order matters: the counter must run before the save-transcript callback because that callback can end the call.

## 8. Mistakes and misunderstandings (so they are not repeated)
1. **The first probe only looked at the reply side** and the second at events; neither checked `llm_request`. Whether the request carries the instructions is still unknown.
2. **Explanations were repeatedly unclear to the user.** What worked: a pretend office with a forgetful assistant who re-reads a folder each time; tables with every letter count; naming where each number comes from. What confused them: the pretend "1,000-letter rulebook" and "14,600 letters" (sounded like numbers they had to supply), the caller's lines (40 and 12 letters) being missing from the first table, and a words column (6, 3, 3, total 12) next to a "12 letters" caller line, which looked like the same thing. Be explicit about which numbers are made up.
3. **Tool-argument type error found in the logs (not fixed):** the model passed the order number as a number (112) and `get_order_status` rejected it (expects text). The model retried with "112", costing one extra model call. Offered fix: make the tools accept both. Belongs to the voice agent session.
4. An early assumption that exact counts might be reachable from a callback was wrong (section 3).
5. The assistant said it could not give exact console button names for the logging screen and asked for a screenshot; the screenshot showed Cloud Logging and BigQuery export toggles under "Logging" in the app settings.

## 9. Known limits of the estimate
About 10 to 20 percent off after calibration. Not counted: the guardrail model's tokens; text the end-of-call hook adds (closing words); calls that end by hang-up (no transcript is saved at all, so no totals either); a call's last model turn only partly if ordering is wrong. Text returned directly by a callback is not voiced and is not counted. Whether before-model callbacks that answer early also skip the after-model counter is **unverified**.

## 10. Open items
1. Do the console steps (section 7) on a copy of the agent; calibrate; set rates; DEBUG off.
2. Decide whether to build exact-number option B (and which deployment model for real clients).
3. Delete the old probe callback and `usage_probe` variable.
4. Fix the `order_number` type error in the voice agent tools (voice agent session).
5. Ask whether the guardrail tokens must be included in the totals.
6. Optional: a Salesforce report or dashboard on the five fields; a validation that Total = sum of parts.
7. The older Salesforce-side question (where Agentforce stores prompt-template token usage, "digital wallet" and the usage data model) is in the Candidate Matcher decisions file and was not part of this workstream.

## 11. Update 26 Nov 2026: the estimate was dropped, exact numbers from Google's logs are built
**Decision (user, 26 Nov):** do not use the estimation callbacks. Read the real counts from Cloud Logging inside Salesforce instead. Sections 5 to 7 (estimate design, console steps for the callbacks) are therefore **superseded**. The two callback files, the five `Est_*` fields and the skill templates stay in the repo, unused. Reasons the user gave: the estimate had no measured error (the "10 to 20 percent" figure in section 9 was a guess, never measured), it cannot see the model's hidden thinking tokens, and the exact way turned out to need little setup.

**How it works (built, deployed to the sandbox, tested on real calls):**
- A read-only Google service account (role Logs Viewer only). Its key is made inside Salesforce (self-signed certificate); only the public half is uploaded to Google, so no key file is ever downloaded.
- Salesforce: an External Credential (OAuth 2.0, JWT Bearer flow) plus a Named Credential `Google_Logging_API`. The JWT needs an extra claim named `scope` (value: the logging read scope); without it Google answers `invalid_scope`.
- The Google project id is not in the repo: it is a record of the custom metadata type `Token_Log_Config__mdt` (record name `Default`), created in the org.
- Classes: `TokenActualsService` (asks Google for all log entries of one session, adds up `LLM` spans: input, output, thought; and `TTS` spans: only the `tts input token count` and `tts output token count`, because the plain pair repeats the same numbers), `TokenActualsQueueable` (picks transcripts, writes the totals), `TokenActualsScheduler` (optional, see below), `TokenActualsTrigger` (starts the lookup 2 minutes after a transcript becomes Closed), `TokenActualsServiceTest` (13 tests). Permission set `Token_Actuals_Access`.
- New fields on `Chat_Conversation__c`: `Actual_Model_Input_Tokens__c`, `Actual_Model_Output_Tokens__c`, `Actual_Model_Thought_Tokens__c`, `Actual_Voice_Input_Tokens__c`, `Actual_Voice_Output_Tokens__c`, `Actual_Total_Tokens__c` (total = all five), `Actual_Tokens_Status__c` (empty = not looked up; Done; No log entries; No token counts found; Partial; Error: ...), `Actual_Tokens_Checked_At__c`.
- The user who saves the transcript runs the lookup, so that user needs the permission set `Voice_Agent_Access` (on 26 Nov the five earlier sets, including `Google Logging Access` and `Token Actuals Access`, were merged into it).

**Verified:** a lookup of a test call matched Google's own entries exactly (5 entries, 8 model calls, 5 voice runs; all five sums equal). End to end on a real call: transcript saved, real numbers on the record about 2 minutes later with no manual step. Google's log entry arrives 1 to 2.3 seconds after the transcript is saved (measured on 3 calls), so the 2 minute wait has a large margin.

**Things learned (mistakes not to repeat):**
- A log search without a time window is very slow (about 36 s per call; Google returns empty pages with a next-page token). With a window of 3 hours either side of the save it takes about 1 s. The first batch run hit Salesforce's 120 s limit for waiting on callouts because of this. The job now also stops starting new lookups after 60 s.
- New fields cannot be tested in a check-only deploy (they do not exist yet at test time); deploy the fields first, then check-only the classes. Tests that touch the new fields run as a test user holding the permission set.
- Google's log search allows 60 reads per minute per project and says it is not meant for high volume; for big volume a log sink is the way (not built).
- Guardrail tokens are NOT available: the `Guardrail` span has no token counts in Google's log, so the totals never include the guardrail model. State this when presenting numbers.
- Thought tokens are not always 0 (seen: 14, 47, 84, 87 on short calls), so they are stored separately and included in the total.
- `TTS` spans carry `speculative: true` on most turns. We count all of them. **Unverified:** whether speculative voice tokens are billed. Ask Google or check a billing report; if the manager wants it split, add a separate field.
- Logs exist only from the day Cloud Logging was switched on; older transcripts get "No log entries".

**Decision on the optional 15-minute schedule (user, 26 Nov: demo uses the trigger only; the schedule stays off for now).**
It is NOT required. It is a safety net, started with `TokenActualsScheduler.scheduleEvery15Minutes();` and stopped with `TokenActualsScheduler.unschedule();` (Developer Console, Execute Anonymous).
- *What the trigger does not cover:* (1) A failed first lookup. If Google hiccups or has no logs yet, the record shows "Error: ..." or "No log entries" and the trigger never tries again; only the schedule retries (for 3 hours). (2) Transcripts saved by a user who lacks the two permission sets: that lookup fails, and the schedule (running as a user who has them) fixes it. (3) Calls saved while the job was broken or off: the schedule catches up on the last 7 days.
- *What it costs:* almost nothing. Every 15 minutes it looks at the records; if nothing is pending it asks Google nothing. It uses 4 of Salesforce's 100 scheduled-job slots.
- *If it stays off:* normal calls still work. A failed lookup stays as "Error: ..." on the record and can be rerun by hand with `System.enqueueJob(new TokenActualsQueueable());` (picks transcripts at least 1 minute old and at most 7 days old, up to 25 per run).
- *Recommendation:* skip it for a demo or pilot (fewer moving parts to explain); turn it on before real clients or real call volume, because a silent gap in the numbers is the worst thing in a cost report. Review this when moving past the demo.

**Still open:**
1. Not committed or pushed (user rule: only on request).
2. Remove the old `usage_probe` callback and variable from the agent copy (console, after manager approval). It also bloats every log entry.
3. Decide what to do with the now-unused estimate files and `Est_*` fields (left alone for now).
4. Optional report or dashboard on the `Actual_*` fields; the planned before/after comparison of long vs short instructions (the rulebook is about 4,000 of the roughly 4,200 input tokens per model call, so shortening it should show clearly).
5. Ask Google about speculative voice tokens.
6. The `order_number` type error in the voice agent tools (voice agent session).
7. For real clients: the same setup (service account, certificate, External Credential, Named Credential, `Token_Log_Config__mdt` record) has to be repeated per client Google project; consider a script. Google setup per client is small (one read-only account) but not zero.


## Folder cleanup, 26 Nov 2026
The folders `ces-agents/abbott-customer-service` (the older demoOrg agent), `ces-agents/exported-from-google-console` and `ces-agents/token-usage-spike` were deleted by the user's decision (superseded; they remain in git history). `ces-agents` now holds the baseline agent `abbott-customer-service-serviceorg-baseline`, the optimized copy `abbott-customer-service-serviceorg-optimized` and nothing else; the learnings document moved to `docs/Voice-Agent-Setup-and-Lessons-Learned.pdf` (updated 26 Nov with the token chapter). The baseline's estimate callbacks and `Est_*` fields were removed from its spec; it is labelled `Voice_Agent_Name__c = Baseline`. Mentions of the deleted folders in this file are historical.
