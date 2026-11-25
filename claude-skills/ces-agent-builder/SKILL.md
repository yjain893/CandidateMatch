---
name: ces-agent-builder
description: Designs and generates an import-ready Google CX Agent Studio (Customer Engagement Suite, ces.cloud.google.com) agent package connected to a Salesforce org, so nothing has to be configured by hand in the console. Interviews the user (purpose, org, tasks, tone, guardrails), inspects the Salesforce org read-only with the sf CLI, proposes the complete design (tools, variables, guardrails, instructions, tests) for approval, then builds, validates, self-tests and zips the agent. Use when the user wants to create, scaffold, extend, review or fix a Google CX / CES / Gemini Enterprise for CX voice or chat agent, a Salesforce-connected voice agent, or an agent export/import zip.
---

# CES agent builder (Google CX Agent Studio + Salesforce)

You turn "I need an agent that does X in my Salesforce org" into a **zip the user imports into Google CX Agent Studio**, after the user has approved a design.
Everything deterministic lives in scripts; your job is the interview, the design, the instructions, and honest reporting.

`SKILL_DIR` = the folder holding this file (normally `~/.claude/skills/ces-agent-builder`). Run scripts with `python3 $SKILL_DIR/scripts/<name>.py`.

## Hard rules
1. **No secrets in any file or message**: no access tokens, client secrets, API keys. The token variable ships empty. If an existing export contains a secret, warn the user (name the file and key, never repeat the value). **Never ask the user to paste a key or secret into the chat**: have them run `sf_oauth_check.py` (hidden prompts, token never printed). If one is pasted anyway, tell them it is exposed and must be rotated, and do not repeat it.
2. **Salesforce is read-only unless the user says otherwise per action.** Discovery makes only GET requests and reads no record data. Creating test data, running Apex or deploying needs the user's explicit yes for that specific thing; prefix test records `DEMO - `, test the cleanup in a rolled-back transaction, and report exactly what was created. Provide Apex as files; never deploy it.
3. **Design first, build after approval.** Show the design proposal and stop until the user approves it.
4. **Only use objects and fields that discovery confirmed.** If something is missing, say so; never guess an API name.
5. **Be exact about what is verified.** The package layout is verified against two real console exports (app, agent, Python tools, the default guardrails, and the OAuth Salesforce toolset with `environment.json`), and the Python-tool-plus-connector design ran end to end in the console. The callback layout (after-model) and sequential execution were confirmed by a third export, and the transcript saver ran in the Preview simulator; the before-model, agent and tool callback folders follow the same naming but were not seen, and the non-default guardrail types come from Google's docs and were never imported. Never say "it will import" before the user has tried it. See `references/export-format.md`.
6. Prefer **Python wrapper tools** for Salesforce calls (Google's best practice, and it keeps security in code). For production OAuth use the **hybrid**, which is verified end to end: the Python tool keeps the checks and calls the Salesforce connector (`salesforce.transport: "connector"`, see `example-pharma-hybrid`); the connector is not attached to the agent. For Salesforce leave the connector's OAuth scopes empty. Use the connector alone only for simple pass-through. Never expose free-form SOQL unless the user explicitly accepts the risk, and then lock it with `q_pattern`.

## Workflow

Work in `./ces-agents/<slug>/` (tell the user the path): `discovery/`, `design.md`, `spec.json`, `instructions/`, `tools_src/` (custom tools), `out/`.

### Phase 0: preflight (quick)
- `python3 --version` (3.8+) and `python3 $SKILL_DIR/scripts/sf_discover.py --check` (lists signed-in orgs; no tokens).
- If `sf` is missing or the org is not listed: tell the user how to sign in (`sf org login web --alias <name>`, they run it) and wait.
- If the user gave an existing export folder/zip: `python3 $SKILL_DIR/scripts/validate_package.py <path> --inspect` first; treat it as the baseline and report any secret it holds.

### Phase 1: interview (`references/interview-questions.md`)
Ask only what is missing, in at most three rounds: purpose and tasks (chat), then structured choices with `AskUserQuestion` (org, channel, tone, data access, identity check, escalation, languages, sensitive domain), then a single confirmation of names and technical defaults (agent and company name, verification fields, auth mode, model, voice, recording policy). Offer defaults; unanswered items become written assumptions.

### Phase 2: org discovery (read-only)
`python3 $SKILL_DIR/scripts/sf_discover.py --org <alias> --keywords <words from the tasks> --out ./ces-agents/<slug>/discovery`
Read only `discovery/org-summary.md` (compact). Confirm ambiguous choices with the user (which phone field, which identifier, which status values). Note: empty objects (no test data), auto-number formats, picklists, sensitive fields. Use `--objects X,Y` to deepen on a specific object.

### Phase 3: design proposal and approval gate (`references/design-proposal-template.md`, `design-principles.md`, `guardrails-guide.md`, `tools-guide.md`)
Write `design.md` and summarize it in chat. It must cover: purpose, experience (channel, tone, model, voice, greeting), architecture, Salesforce connection (auth mode, integration user, objects/fields, read or write), **every tool with its purpose, inputs, outputs and what it enforces**, variables (config vs state), **guardrails with hints and latency cost**, callbacks, conversation flow, test plan, assumptions and risks, and what you will produce. If transcripts are saved, add the Salesforce object, who can read it, retention, the hang-up gap and the privacy points from `references/transcripts.md`. Then ask for approval with `AskUserQuestion` (Approve / Change / Cancel). Iterate until approved. Do not build before that.

### Phase 4: build (`references/instructions-guide.md`, `spec-reference.md`, `tools-guide.md`)
1. Write the instruction files (`instructions/root.txt`, `instructions/global.txt`) in the structured XML format: crisp, numbered constraints, `{{static}}` config variables, `{dynamic}` state, `{@TOOL: ...}` references that match attached tools, explicit handling of every tool result (`verified`, `not_verified`, `locked_out`, `system_error`), `end_session` for finish and escalation, voice rules in the global instruction.
2. Write `spec.json` (see `assets/example-pharma/spec.json` as the pattern; `example-pharma-hybrid` for Python plus connector; `example-pharma-transcript` for saving call transcripts to Salesforce, with Salesforce files in `assets/salesforce-transcript-metadata/`; `example-caller-id-service` for caller-ID greeting, email verification and an order address change (run `assets/spike-callback-tool` in the console first); `example-all-features` shows every option). Use the template tools; write a custom tool file only when the templates do not fit.
3. `python3 $SKILL_DIR/scripts/build_agent.py ./ces-agents/<slug>/spec.json --selftest`
   It writes the package, validates it, runs offline scenarios for every template tool, and zips only when everything passes. Fix errors and rebuild until clean.
4. If the org has matching records, prove the tools read-only with real data and no token: `python3 $SKILL_DIR/scripts/live_read_check.py <package> --tool <name> --org <alias> --args '{...}'`.
   If there are no records, say so and offer (do not create) a small `DEMO - ` test data script.

### Phase 4b: production OAuth setup (only when the user chose OAuth; `references/setup-gcp-and-salesforce.md`, `references/lessons-learned.md`)
Walk the user through the Salesforce External Client App (scope `api`, client credentials flow, Run As user), then the Google side (Secret Manager API, secret, Accessor role for the CES service agent), then the connector dialog values. Have them prove Salesforce first with `sf_oauth_check.py --org <alias> --soql "<the agent's lookup>"` before anything in Google. Use the error table when something fails.

### Phase 5: handover (`references/import-and-test.md`)
Give: the zip path; what was checked (validator, N offline scenarios, live checks and on which records); what was **not** checked (the console import, anything DOCUMENTED or UNVERIFIED); the post-import steps (set the token variable, for transcripts: deploy the Salesforce files yourself, assign the permission set to the Run As user, add the `save_transcript` connector operation, hide the tool and use sequential execution;  enable Secret Manager for OAuth, confirm guardrails are enabled, choose channel and modality, simulator test list, take a version snapshot). Recommend importing `assets/example-smoke` first if this is their first import.

## Scripts (all under `$SKILL_DIR/scripts`)
| Script | Purpose |
|---|---|
| `sf_discover.py` | Read-only org discovery through the `sf` CLI (objects, fields, picklists, counts); no token handling |
| `build_agent.py` | spec.json -> package folder + zip + offline test scenarios; validates and self-tests |
| `validate_package.py` | Validate or `--inspect` any package (built or exported); secret scan; reference, instruction, tool, guardrail checks |
| `selftest_tools.py` | Offline scenario runner for generated Python tools (success, wrong input, lockout, 401, 500, injection, leaks) |
| `selftest_callbacks.py` | Behaviour tests for the callback templates in a built package or a real export (templates are recognised by their code), against a faked CES runtime |
| `export_console_files.py` | Writes paste-ready tool, callback, instruction and connector-schema files from a built package, for adding to an existing agent without importing a zip |
| `compare_to_export.py` | Compares a built package with a real console export (files, JSON keys, connector schema); use it whenever the user sends a new export |
| `live_read_check.py` | Run one generated tool against a real org, GET-only through the `sf` CLI |
| `sf_oauth_check.py` | Test the External Client App's client credentials login (and an optional lookup) with hidden prompts; names the likely cause of each known error |
| `run_examples.py` | Regression: builds every example with validation and self-tests; run after changing the skill |

## References (read when needed, one level deep)
| File | Read it for |
|---|---|
| `references/interview-questions.md` | What to ask and the defaults |
| `references/design-proposal-template.md` | The review document |
| `references/design-principles.md` | Where each job belongs (instruction, variable, tool, callback, guardrail) and the security model |
| `references/instructions-guide.md` | XML structure, reference syntax, voice rules, result-handling block |
| `references/tools-guide.md` | Tool choice, the five templates, custom tool rules, auth modes, connector operations |
| `references/guardrails-guide.md` | Guardrail types, outcomes, latency, domain hints and presets |
| `references/salesforce-patterns.md` | REST and SOQL, tokens, OAuth setup, least privilege, data-model gotchas, test data |
| `references/app-config-reference.md` | Models, voices, ambient sounds, languages, logging, error handling |
| `references/spec-reference.md` | Every spec.json key and template parameter |
| `references/export-format.md` | Package layout and which parts are verified |
| `references/import-and-test.md` | Import steps, post-import setup, test scenarios, troubleshooting |
| `references/setup-gcp-and-salesforce.md` | Verified step-by-step setup: Salesforce app and Run As user, Google Cloud secret and permissions, connector dialog values |
| `references/transcripts.md` | Saving the call transcript to a Salesforce record: design, spec, Salesforce object, privacy, known gap, tests |
| `references/caller-id-verification.md` | Greeting the caller by name from their phone number, verifying by email, and looking up or changing an order: design, tools, spike, risks |
| `references/lessons-learned.md` | The errors seen in practice with cause and fix (instructions, Salesforce OAuth, Google Cloud) and working practices |

## Extending an existing agent
Inspect it (`validate_package.py <path> --inspect`), copy its instructions and tool code into a new spec (`instructionFile`, custom tool `file`), or edit the exported files directly and re-run the validator. Keep the user's variable names and tool names so existing instructions keep working.

## Style of your messages to the user
Plain words, short. Lead with what you need or what happened. Tables for tools, variables and guardrails. Say plainly what is untested.

- Token counts per call: offer the `token_count_input` / `token_count_output` callbacks (estimates, `references/token-estimates.md`); exact numbers only come from Cloud Logging.
