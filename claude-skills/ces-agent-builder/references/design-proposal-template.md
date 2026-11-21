# Design proposal template (write to `<project>/design.md`, summarize in chat, wait for approval)

The user reviews this BEFORE anything is built. Keep it scannable: tables, no code. Mark every assumption. End with an approval question
(AskUserQuestion: Approve / Change something). Do not build until they approve.

```markdown
# <Agent display name>: design proposal

## 1. Purpose
One paragraph: who uses it, what outcome, what it will not do.

## 2. Experience
| | |
|---|---|
| Channel | voice / chat / both |
| Persona and tone | name, style (concise or chatty), formality |
| Languages | |
| Model and thinking level | and why (voice-optimized composite vs text model) |
| Voice | name, speaking rate, ambient sound (voice only) |
| Greeting | the exact fixed greeting (callback, no model call) |

## 3. Architecture
Single agent or a tree (diagram as an indented list). Why.

## 4. Salesforce connection
| | |
|---|---|
| Org / instance | alias and URL |
| Auth | POC token variable, or OAuth client credentials (what must exist first) |
| Integration user | recommended least-privilege permission set (objects and fields) |
| Objects used | object, rows today, read/write |
| Test data | exists? what is missing? (never created without approval) |
| Transcripts | none, or saved to `<object>` at call end (who can read, retention, redaction, hang-up gap: see `transcripts.md`) |

## 5. Tools
| Tool | Type | Purpose | Inputs | Returns (only) | Salesforce objects/fields | Read/write | Needs verified caller |
|---|---|---|---|---|---|---|---|
Explain for each: why a tool and not instructions, and what it enforces in code (normalization, scope, confirmation, lockout).
System tools used: end_session (finish or escalate), customize_response if needed.
Connector (OpenAPI toolset) operations, if any, and why a connector instead of a Python tool.

## 6. Variables
| Variable | Type | Default | Static or dynamic | Purpose |
|---|---|---|---|---|
Configuration (company_name, agent_name, hours...), state written by tools (caller_verified, verified_scope_id, verification_attempts), the token variable (shipped empty).

## 7. Guardrails and safety layers
| Layer | What | Outcome |
|---|---|---|
Show the recommended set (three to five), plus the optional ones with hints and their latency cost, from guardrails-guide.md.
Callbacks: greeting, escalate on system error, mandatory notice, redaction, silence prompt (which and why).

## 8. Conversation flow
Subtasks and steps in plain language (this becomes the taskflow). Escalation rules. What the agent says on each failure.

## 9. Test plan
Scripted scenarios for the simulator: happy path, wrong detail, lockout, unknown record, system error (empty token), out-of-scope request, sensitive topic, silence, interruption.
Offline tool scenarios that will run automatically. Live read-only checks planned against which records.

## 10. Assumptions, risks, open questions
- Assumptions made because the user did not say (list every default).
- Risks: unverified import parts (toolsets, callbacks paths), token expiry, IP restrictions, empty test data.
- Questions that change the design.

## 11. What I will produce
Folder path, zip name, files, and the post-import steps the user must do (set the token variable, enable Secret Manager, deploy).
```

Approval block to show the user: "Approve this design?" with options Approve (Recommended) / Change something / Cancel.
