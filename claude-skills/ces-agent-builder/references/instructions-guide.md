# Writing agent instructions (CES)

Sources: official "Instructions", "Variables", "Modular components", "System tools", "Best practices" pages.

## Structure (recommended XML)
```
<role>one line: the agent's job</role>
<persona>
    <primary_goal>the single objective</primary_goal>
    Your name is {{agent_name}}.
    <prohibited_topics>what to do when these come up</prohibited_topics>
    <general_guidelines>Follow the constraints and the task flow exactly.</general_guidelines>
</persona>
<constraints>
    1.  numbered, specific, testable rules
</constraints>
<taskflow>
    These define the conversational subtasks that you can take. Each subtask has a sequence of steps that should be taken in order.
    <subtask name="...">
        <step name="...">
            <trigger>when this step starts</trigger>
            <action>what to do, including tool calls and what to do with each result</action>
        </step>
    </subtask>
</taskflow>
<examples></examples>      (only if instructions alone fail; format below)
```
The official tag list is role, persona, primary_goal, constraints, taskflow, subtask, step, trigger, action, examples. `prohibited_topics` and
`general_guidelines` inside `<persona>` are what the console's "Restructure instructions" produces, so they are safe. Omit an empty `<examples>`.

## References and syntax
| Syntax | Meaning |
|---|---|
| `{@TOOL: tool_name}` | A tool of THIS agent (add it to the agent first, otherwise the red underline appears). Case sensitive, snake_case |
| `{@AGENT: Agent Name}` | Another agent (a child) |
| `{{variable}}` | Static variable: substituted before the model call. Use for config |
| `{variable}` | Dynamic variable: shown through state updates. Use for values tools write |
| `{% if x == 'a' %}...{% elif %}...{% else %}...{% endif %}` | Conditions. Inside `{% %}` write the bare variable name, no braces |
| `{% for i in list %}`, `{% macro %}`, filters `| default | length | upper` | Loops, macros |
| `{@startModality_Voice}...{@endModality_Voice}` (also Text) | Voice or text only wording. Set the matching modality in deployment settings |
| `{@startChannel_GoogleTelephonyPlatform}...{@endChannel_...}` | Channel only wording (API, WEB_UI, TWILIO, FIVE9, WHATSAPP, ...) |
| `end_session(reason="success")` | Finish. Needs `end_session` in the agent's tools |
| `end_session(reason="escalate_to_human", session_escalated=True)` | Escalate to a person |
| `customize_response(content="...", disable_barge_in=True)` | Voice: speak exactly, optionally not interruptible; also DTMF (`enable_dtmf`, `dtmf_finish_digit`) |

Instruction lines that mention `end_session(` or `customize_response(` require those tools in the agent's `tools` list (the validator checks).

## Rules that avoid problems
1. Every `{@TOOL: x}` must be attached to the agent. This is the most common cause of "There is a problem with your instructions".
2. Do not use `&`; write "and". Angle brackets are fine for the documented TTS tags (composite voice models only: `<short pause>`, `<warm>`).
3. Write in English even for multilingual agents (the agent answers in the caller's language). Say so if only some languages are allowed.
4. Keep the instruction under about 12,000 characters; shorter is better. Avoid long examples.
5. Never put secrets or real customer data in instructions.
6. Tell the agent what to do for each tool result; do not explain how the tool works.
7. Static vs dynamic: configuration -> `{{name}}`; values a tool writes -> `{name}`. Changing rendered static text mid-session invalidates prompt caching (latency).
8. Few-shot examples: only to fix a proven failure; 1 or 2 maximum. Format:
```
<examples>
  EXAMPLE 1:
  Begin example
  [user]
  What's the weather in London?
  [model]
  ```tool_code
  get_weather(location="London")
  ```
  ```tool_outputs
  {"temperature": "15 C"}
  ```
  [model]
  It is 15 degrees in London.
  End example
</examples>
```

## Voice conventions
- One or two short sentences per turn, one question at a time.
- Read digits one at a time, confirm numbers back before calling tools, say money in words, dates as weekday + day + month.
- Put those spoken-format rules in the **global instruction** and say they apply only to speech (tools still get the original value).
- Do not read long lists; offer at most three items.
- Use `customize_response(..., disable_barge_in=True)` for legal text, `enable_dtmf=True` for card or keypad input.
- Fixed greeting via the `static_greeting` callback, not a model call.

## Standard result handling block (works with the template tools)
```
Call {@TOOL: authenticate_user} with order_number and phone_number exactly as confirmed.
If verified is true, continue.
If error is not_verified, say the details do not match our records without saying which one, and ask the caller to try again.
If error is locked_out or system_error is true, escalate.
```

## Global instruction
Applies to every agent on every turn: brand tone, spoken-number rules, shared DOs and DON'Ts, shared variables. Keep it short; it is sent every turn.

## Multi-agent
Root agent: understand the goal, route, handle simple things. Sub-agent: one domain. Reference with `{@AGENT: name}`. Parent -> child only. Use handoff rules for deterministic routing.
