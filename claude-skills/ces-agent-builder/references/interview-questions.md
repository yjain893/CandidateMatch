# Interview: what to ask (keep it short, propose defaults)

Goal: gather enough to write the design proposal in at most three rounds. Skip anything the user already said. Never ask for secrets.
Use `AskUserQuestion` for choices (max 4 questions per call, 2 to 4 options each, put your recommended option first) and plain chat for open answers.
Everything not asked becomes a stated **assumption** in the proposal, so the user can correct it at review.

## Round 1: purpose and scope (open questions, ask in chat)
1. **What is the agent for?** One or two sentences: who calls or chats, and what outcome they want.
2. **What should it be able to do?** The list of tasks, for example "check order status", "book a callback", "update my address". One line each.
3. **Which Salesforce data does that touch?** Object names if the user knows them; otherwise infer from the tasks and the org discovery.

## Round 2: structured choices (AskUserQuestion)
| Question | Options (recommended first) | Default if skipped |
|---|---|---|
| Which Salesforce org? | the aliases from `sf_discover.py --check`, plus Other | the only authenticated org |
| Channel | Voice (phone) / Chat / Both | voice |
| Tone | Calm and professional / Warm and friendly / Brisk and efficient / Formal | calm and professional (persona CONCISE) |
| Data access | Read only / Read and create records / Read, create and update | read only |
| Caller identity | Two-factor check (an identifier plus a second detail) / One identifier / No check (public information only) | two-factor |
| Escalation to a person | On request, after failed checks, or on sensitive topics / Only on request / Not available | on request and after failed checks, plus sensitive topics |
| Languages | English only / English and French (Canada) / Other | English only |
| Sensitive domain | Healthcare or pharma / Finance / HR or recruiting / None | none (ask if the data looks sensitive in discovery) |

## Round 3: identity, names and technical defaults (confirm in one message, change only what differs)
- Agent name and company name (become the variables `agent_name`, `company_name`). Business hours and time zone if callers ask for them.
- Verification details: which field identifies the record (order number, case number, email) and which second detail proves identity (registered phone, email, postal code, last 4 digits). How many tries (default 3).
- Auth for Salesforce: **POC** (access token variable set after import) or **production** (OAuth client credentials with Secret Manager). Default POC; tell the user what production needs.
- Model (default gemini-composite-v2 for voice, gemini-3.5-flash for chat), voice (default a Chirp 3 HD voice), recording and redaction policy (default off, retention 365 days).
- Anything the agent must never say or do. Phrases to block. Competitor names.

## After the answers
1. Run org discovery with the keywords from the tasks (`sf_discover.py --org <alias> --keywords ...`).
2. Read `org-summary.md`; confirm ambiguous objects and fields with the user (for example "Order.Account.Phone or Contact.Phone?").
3. Note empty objects (no test data), sensitive fields, picklist values, auto-number formats.
4. Write the design proposal (design-proposal-template.md) and stop for approval.

## Questions to ask only when relevant
- Write operations: which fields may the caller change, what must be confirmed first, what must never change.
- Multi-agent: are there clearly separate domains (billing vs orders)? If not, stay single agent.
- Callbacks: fixed greeting wording, mandatory recording notice text, fixed silence prompt.
- Transcripts: save each call's transcript to Salesforce? (default no). If yes: which record it links to, who may read it, retention, whether callers are told, what to redact. See `transcripts.md`; it adds a custom object the user deploys.
- Existing agent export supplied: inspect it first with `validate_package.py <path> --inspect` and treat it as the baseline.
