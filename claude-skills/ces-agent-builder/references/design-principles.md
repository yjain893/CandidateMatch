# Design principles for CES agents (what "optimized and best" means here)

Distilled from Google's best-practices page, the variable, callback and guardrail docs, and the lessons of building a real Salesforce voice agent.
Apply them when you write the design proposal and again when you build.

## 1. Put each job in the right place

| Need | Put it in | Why |
|---|---|---|
| Wording, tone, flow | Instructions | Cheap to change, readable |
| Facts that rarely change (company name, hours, thresholds) | Static variables `{{name}}` | One source of truth, compiled into the prompt |
| Facts that change during the call (verified, attempts, record ids) | Dynamic variables `{name}` written by tools | Appended as state updates |
| Anything that must happen exactly | A Python tool or callback | The model can skip, reorder or invent steps; code cannot |
| Calling an API | A **Python wrapper tool** (best practice) | Hides the 97 irrelevant fields, controls inputs and outputs, saves tokens, can normalize and validate |
| Simple pass-through call with clean inputs | Salesforce connector (OpenAPI toolset) | Platform handles auth (OAuth, Secret Manager) |
| Rules about what may be said | Guardrails (+ instructions as the first layer) | Independent second check |
| Fixed phrases (greeting, notices, error text) | Callbacks | No model call, zero variation |

## 2. Tools
- One tool per business task; the tool does the whole job. Never instruct the agent to chain tools A -> B -> C in one turn (every hop is a model call and a chance to hallucinate); make one tool call the others.
- Names: verb first, snake_case, clearly different from each other (`authenticate_user`, `find_my_orders`). Parameters: descriptive snake_case, flat, typed. Avoid `arg1`, `pnum`.
- Return only what the agent needs, never a raw API payload. Use a stable result contract: `ok`, `error`, `message`, `system_error`.
- Fewer tools beat more tools (aim for 5 or fewer per agent; the validator warns above 10). Remove unused tools.
- Write the docstring like prompt text. It is the tool description the model reads.
- Treat tool arguments as hostile input: normalize (digits, upper-case), validate against allowed values, escape before building SOQL.

## 3. Deterministic security (do not rely on the prompt)
- Verification lives in a tool that sets `caller_verified`; every data tool checks it and refuses otherwise.
- Row-level scope: after verification store the owning Account/Contact id in `verified_scope_id`; every query adds `AND <field> = '<scope>'`. A verified caller can never read another customer's records, even if the model asks.
- Uniform failure messages: wrong detail, unknown record and blank stored value all produce the same answer. Never confirm that a record exists.
- Attempt limit enforced in code (`locked_out`), not in prose.
- Writes: default to read-only. Write tools require `caller_confirmed: true`, a whitelist of fields, validated picklists, and scope assignment from variables.
- Integration user with least privilege (read-only object and field access) is the real security boundary. See salesforce-patterns.md.
- Secrets never appear in the package, the instructions or a variable default.
- **Dynamic variables are visible to the model.** Google appends every update as a `state_update` event the model can read. Never store a value in a variable that the model must not see or repeat (an email or other detail used for verification): keep it in code, or store only a hash.

## 4. Instructions (see instructions-guide.md)
- Structured XML (role, persona, constraints, taskflow, optional examples). Crisp: one or two sentences per step.
- Constraints are numbered, positive and testable. Put the hard "never" rules in constraints, and back them with a tool check or a guardrail.
- Reference tools with `{@TOOL: name}`, agents with `{@AGENT: name}`, config with `{{var}}`, state with `{var}`. Every reference must resolve.
- Do not describe what a tool already enforces; tell the agent what to do with each result (`verified true`, `error not_verified`, `system_error`).
- Voice: short sentences, one question at a time, read digits one by one, confirm numbers before using them, normalize spoken output in the global instruction and pass original values to tools.
- Keep instruction text static where possible: changing rendered text mid-session defeats prompt caching and adds latency.

## 5. Deterministic behaviour through callbacks
- Static greeting at session start (saves the first model call).
- Escalate immediately when a tool reports `system_error` or `locked_out` (do not let the model improvise).
- Mandatory notices verified in `after_model_callback`.
- Redact sensitive patterns before they are spoken.
- Silence handling with a fixed prompt.

## 6. Errors and escalation
- Three outcomes only: retryable (`not_verified`, `invalid_input`), terminal-with-apology (`system_error`, `locked_out`), out of scope (offer a person).
- Escalate with `end_session(reason="...", session_escalated=True)`; finish normally with `end_session(reason="success")`.
- App-level `errorHandlingSettings` covers model/system failures; keep `endSessionConfig.escalateSession: true` for voice.

## 7. Multi-agent only when it earns its place
Start with one agent. Split into sub-agents only for clearly different domains, tool sets or personas. Parent -> child transfers only, one parent each, root is never a child.
Prefer deterministic handoff rules (variable checks) for high-stakes routing over instruction-only routing.

## 8. Testing mindset
- Every Python tool ships with offline scenarios (`selftest_tools.py`): success, wrong input, no data, blank value, lockout, missing token, 401, 500, injection.
- Prove queries against real data read-only with `live_read_check.py` (no token handled).
- Test the conversation in the simulator with the scripted scenarios in the design proposal. Create a version snapshot before changes.

## 9. Operational lessons (from a real build)
- Test one hop at a time: Salesforce OAuth alone, then the connector, then the Python tool in Test Tool, then Preview. Most "agent" bugs were a lower hop.
- Never ask the user to paste a key, secret or token. Give them a command with hidden prompts (`sf_oauth_check.py`). If one is pasted anyway, say so, and have it rotated.
- Do not attach the connector to the agent when only a Python tool should use it (verified to work), so the model cannot call raw Salesforce operations.
- A tool failure must end the call audibly: pair `system_error` results with the escalate callback.
- Check each guardrail's toggle after import and validate every export before sharing it.

## 10. Honesty
State what is verified, documented-only and unverified (export-format.md). Never claim an import works until the user has imported it.
