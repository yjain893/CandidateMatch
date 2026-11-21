# Guardrails: types, hints to offer the user, presets

Guardrails check **model input** (what the caller says) and **model output** (what the agent says). Each has an *outcome* when it fires:
say an exact phrase (`respond`), generate a reply from a prompt (`generative`), or hand off to an agent (`transfer`).
Layer them: instructions are the first defence, tools and callbacks are the deterministic second, guardrails are the independent third.

## Types (spec `guardrails[].type`)

| type | What it does | Cost / caveat |
|---|---|---|
| `default_safety` (`level`: strict, balanced, relaxed) | Hate speech, dangerous content, sexually explicit, harassment filters. strict = block low and above; balanced = medium and above; relaxed = only high (mapping from the console's three levels; the console export shows strict as BLOCK_LOW_AND_ABOVE) | Always include |
| `default_prompt_security` | Blocks prompt-injection style input ("ignore your instructions"). Optional `fail_open` | Always include. The real console export had no `enabled` key on it, which means disabled; this skill writes `enabled: true` |
| `llm_policy` (`prompt`, `policy_scope`, `fail_open`, `max_messages`) | A natural-language rule checked by an LLM on the user input, the agent reply, or both. `{var}` placeholders and `{agent_system_instruction}` are allowed in the prompt | `AGENT_RESPONSE` and `USER_QUERY_AND_AGENT_RESPONSE` add latency before every reply. Use for the few rules that must never break. Short utterances are skipped unless allowed |
| `blocklist` (`user_input`, `agent_response`, `both`, `match`: WORD_BOUNDARY_STRING_MATCH, SIMPLE_STRING_MATCH, REGEXP_MATCH) | Banned words and phrases | Cheap, exact, no LLM |
| `sensitive_words` | Google's managed sensitive-words list (replaces the default filter for the agents it covers) | Cheap |
| `supervisor` (`supervisor_type`: MISSING_TOOL_CALL, AUDIO_MISMATCH, SPEAKER_SHIFT, CHOPPY_AUDIO, INVALID_TEXT, LANGUAGE_SHIFT, PROFANITY, CUSTOM; `detection`: NON_BLOCKING, BLOCKING) | A monitor on the active agent. MISSING_TOOL_CALL catches an agent that talks instead of calling a tool | BLOCKING delays the reply until the check finishes |
| `code_callback` (`phase`, `code`) | Your Python returns `{"decision": "OK" \| "TRIGGER", "reason": "..."}` | Deterministic, free of LLM cost |

Action examples: `{"respond": "I can't help with that."}`, `{"generative": "Politely decline and offer a team member."}`, `{"transfer": "escalation_agent"}`.
Placement: `"scope": "app"` (default) or `"scope": "agent", "agents": ["name"]`.

## Deterministic guardrail-like callbacks (templates)
`escalate_on_system_error` (stop and escalate when a tool says system_error or locked_out), `mandatory_text` (force a required notice),
`redact_output` (strip card and ID patterns before they are spoken), `inactivity_prompt`, `static_greeting`.

## Hints to show the user before they choose (adapt to the domain)

Always: default safety (strict for regulated domains), default prompt security, escalate on system error, identity gate in a tool, row-level scope, read-only integration user.

| Domain | Suggested extra guardrails |
|---|---|
| Pharma / healthcare | `llm_policy` "no medical, dosage or drug advice" on agent responses; blocklist or policy on self-harm and emergency words with an immediate "call emergency services / a specialist will contact you" outcome; side-effect or adverse-event mention -> escalate (instruction + policy); never read health data aloud; recording notice; redact card and ID numbers |
| Finance / insurance | no investment, tax or legal advice policy; PCI: collect card numbers only by keypad (`customize_response(enable_dtmf=True)`) and never repeat them; redact_output on card patterns; stricter verification (two factors); fraud words -> escalate |
| Retail / orders | order data only after verification; refunds and cancellations only through a confirmed write tool or a person; no discount promises (policy); competitor blocklist |
| Recruiting / HR | no discrimination or protected-attribute questions (policy on user input and responses); no salary or offer promises; no sharing one candidate's data with another; consent for recording |
| Public sector / education | accessibility (slower speaking rate), language support, no eligibility decisions (escalate), privacy notice |
| Internal helpdesk | authenticate employees; no privileged actions without confirmation; log session ids |

Ask the user which of these apply; propose a small set (three to five total) rather than everything, because each LLM-based guardrail costs latency.

## Telling the user what the defaults do
`default_safety` strict is a safe start; `balanced` reduces false blocks on emotional callers; `relaxed` only for internal tools. Always state the latency cost
of any `AGENT_RESPONSE` policy.
