# Abbott Customer Service voice agent: design proposal (v3, follows your script as written)

Status: PROPOSAL, no open decisions. Nothing is built, deployed or created in Salesforce.
Decisions taken from you: follow the script exactly; **not** implemented: the hashed email (D1), the postal-code check (D2), account scoping (D3), unknown-caller verification (D4), status rules for address changes (D5), any Abbott or medical-topic rules (D6) and the extra guardrail policy (D7).

## Build notes: what changed while building (21 November)
Status is now: built and tested offline, see [README.md](README.md). The plan below is unchanged except for these points.
1. **One connector lookup operation, not two.** An OpenAPI schema holds one operation per path and method, and both lookups use `GET /query`. The first draft silently lost one of them; the generator now refuses that. `find_order` serves both the order and the contact lookup (its pattern allows exactly those two query shapes).
2. **One callback for greeting and lookup** (`greet_known_caller`) instead of two, so the greeting does not depend on a variable written by a tool being visible straight away. It stores `caller_status` (`known` or `unknown`) instead of a true/false value, because the AI is only shown a variable when it changes.
3. **Unknown callers and the 3-try lockout are handled by the instructions, not by a callback**, so the call ends through `end_session` and the transcript is saved. Callback-made endings are not saved.
4. `update_shipping_address` accepts any of street, city, state, postal code and country, and sends only what the caller gave.
5. **The permission set cannot limit editing to the shipping fields:** Salesforce has no field-level security for address fields. It grants object-level edit on Order; the limit comes from the tool and the connector schema.
6. After reading the current address the agent asks "Would you like to change it?" (your script's "Yes." answers something).
7. The greeting uses your wording, "Customer Service Number".
8. **Tried in Preview on 21 November:** the full call worked (see README). The greeting callback was then hardened after one silent start: it always returns a greeting, logs the lookup time, and the instruction makes the model greet if the system did not.

## 1. Purpose
A phone agent for Abbott customers that recognises the caller by the number they call from, greets them by first name, verifies them by email (3 tries), tells them the status of an order, changes the shipping address of an order, ends politely, and saves the whole call to Salesforce (already built and verified).

## 2. Your conversation, line by line, and what runs behind it
| Your script | What happens | Runs as |
|---|---|---|
| Call arrives | The caller's number is read from the phone line | Variable `telephony-caller-id` |
| "Hello John, you have reached Abbott Customer Service..." | Contact looked up by that number; first name and email stored in variables; greeting spoken | Callback `identify_caller_on_start` runs tool `identify_caller`, then `static_greeting` |
| John explains his request | Agent understands the request | AI, from the instructions |
| "Can you please tell me your email address?" | Agent asks for the email | AI |
| John says his email | Compared in code with the stored email; "email not verified, please give another" on a mismatch; at most 3 tries | Tool `verify_caller_email` |
| 3 failed tries | Polite goodbye, call ends, saved as "Verification failed" | `end_session` plus callback |
| "Tell me your order number" / "102" | Order looked up in Salesforce | Tool `get_order_status` |
| "Your order status is Activated, placed on ..., total ..., end date ..." | Read out from the tool's result only | AI |
| "Change the shipping address of another order" / "103" | Order looked up, current address returned | Tool `get_shipping_address` |
| "This is the current shipping address..." | Read out from the tool's result | AI |
| "Change it to 103, London Street" / "I will update it to that one" | Address saved on the order | Tool `update_shipping_address` |
| "The shipping address is updated. Anything else?" | Said after the tool reports success | AI |
| "Nothing else, thanks" / "Thanks for reaching out to us." | Polite closing, call ends, transcript saved | `end_session` plus `save_transcript_on_end` |

## 3. What the org looks like today (read-only discovery, counts only)
| Finding | Consequence |
|---|---|
| 136 Contacts, all with an email, **none with a phone or mobile number** | The caller lookup finds nothing until test contacts exist |
| Those 136 are the Candidate Match candidates, not customers | They are never changed. The lookup only accepts a Contact that belongs to an Account |
| 0 Contacts on the 5 `DEMO - ` accounts; no shipping address on any of the 6 orders | Demo contacts and addresses must be created (needs your explicit yes, section 11) |
| Order shipping fields are editable; State and Country picklists are switched on | A free-text state or country may be rejected by Salesforce |
| Order statuses: Draft, Activated (codes also Canceled, Expired, Superseded) | No status rule is applied (D5 not implemented) |
| Unknown: can an Activated order's address be edited? | If Salesforce refuses, the tool reports a system problem and the agent apologises and escalates. A rolled-back test (section 11) can tell us beforehand |

## 4. Architecture (the verified hybrid, extended)
Python tools hold the logic and call the Salesforce connector (`query_salesforce`, OAuth, secret in Secret Manager, not attached to the agent). Callbacks do what must happen exactly. One agent, no sub-agents.

New or changed connector operations (the schema is replaced in the console, as for the transcript):
| Operation | Kind | Used by |
|---|---|---|
| `find_contact` (new) | SOQL, pattern-locked: Contact by last digits of a phone, with an Account, `LIMIT 20`; returns Id, FirstName, Email, AccountId, Phone, MobilePhone | `identify_caller` |
| `find_order` (extended) | SOQL, pattern-locked: Order by number; adds the shipping address fields | `get_order_status`, `get_shipping_address`, `update_shipping_address` |
| `update_order_address` (new) | PATCH `/sobjects/Order/{id}`, body limited to the 5 shipping fields | `update_shipping_address` |
| `save_transcript` | existing | `save_transcript` |

Phone matching: the query fetches contacts whose phone ends with the last 4 digits (at most 20); the tool compares the last 10 digits in code. Works without any Salesforce change at this size.

## 5. Tools
| Tool | Called by | Inputs | Returns | What it does |
|---|---|---|---|---|
| `identify_caller` | The start-of-call callback | none (reads the caller's number) | `caller_known`, first name | One matching Contact with an Account means known, otherwise unknown. Stores first name, email, contact id and account id in variables |
| `verify_caller_email` | The AI | `email` as heard | `verified`, `attempts_remaining` | Cleans spoken forms ("john at gmail dot com", spelled letters), compares with the stored email in code, counts tries, locks out after 3. Tool errors do not count as tries |
| `get_order_status` | The AI | `order_number` | status, order date, end date, total | Needs `caller_verified`. Same answer for "not found" |
| `get_shipping_address` | The AI | `order_number` | the current shipping address | Needs `caller_verified` |
| `update_shipping_address` | The AI | `order_number`, `street`, optional `city`, `state`, `postal_code`, `country` | `updated` and the saved address | Needs `caller_verified`. Updates only the fields the caller gave, only the five shipping fields, valid lengths |
| `save_transcript` | The end-of-call callback | `outcome` | ok | Already verified |
| `end_session` | The AI | reason | none | `success`, `verification_failed`, `escalate_to_human` |

Four working tools plus `end_session` for the AI; the two callback tools also sit on the agent's list with a description that says "runs automatically, do not call it yourself". Seven in total.

## 6. Variables
**Static** (set once in the console; your "store the client name in a variable in CX Studio"): `company_name` = Abbott, `agent_name`.
**Dynamic** (written by tools): `telephony-caller-id` (Text, exact name, filled by the phone platform), `caller_known`, `caller_name` (first name), `caller_email` (the Contact's email, stored as you asked), `caller_contact_id`, `caller_account_id`, `caller_verified`, `verification_attempts`, `last_order_id`.
Note: Google appends every variable update to the conversation, so the AI can read `caller_email`. The instructions forbid saying it, and the tool does the comparison, but this is a rule in text, not a lock.

## 7. Instructions (rewritten around your script)
Structured XML. Draft constraints:
1. Help only with order status and shipping address changes.
2. Say nothing about an order before `verify_caller_email` returns verified.
3. The greeting is spoken by the system; never repeat it.
4. One question at a time, short sentences, read numbers digit by digit and confirm before using them.
5. Never read out the email or phone on file, and never say which detail was wrong.
6. After 3 failed email tries, say politely that you cannot verify the caller today and end the call.
7. A tool result with an `error` is a system problem, not a failed try: apologise once and escalate.
8. Share only what a tool returned. Never guess a date or an address.
9. Always finish politely.
10. Never mention `identify_caller` or `save_transcript`.
Task flow follows the table in section 2. There are no Abbott-specific or medical-topic rules (D6): the agent does only what the script describes.

## 8. Callbacks
| Callback | What it does | Status |
|---|---|---|
| `identify_caller_on_start` (new, before model) | At session start calls `identify_caller` so the greeting can use the name | New. Needs the 10-minute spike (section 14) |
| `static_greeting` (extended) | "Hello {caller_name}, you have reached {company_name} Customer Service. How can I help you today?", and a version without the name when the number is unknown | Exists; gains the unknown version |
| `escalate_on_system_error` | Spoken apology and escalation on a tool system error | Exists |
| `inactivity_prompt` | Fixed prompt after silence | Exists |
| `save_transcript_on_end` | Saves the call; "verification failed" becomes its own outcome | Exists; small change |
Transcript links become: Order = last order discussed, Account = the caller's account. No new Salesforce field.

If the number is not found (your script does not cover this): greeting without a name, a short apology that the number could not be matched, and a transfer to a team member. I will use this unless you tell me otherwise.

## 9. Guardrails
Keep the two defaults and switch them on (your current Default Prompt Guardrail is off). No extra policy (D7 not implemented).

## 10. Security model: what is enforced and what is not
Enforced in code: the 3-try email check and lockout; no order data before verification; a field whitelist and length limits on the address update; uniform failure messages; no tokens in results.
Not enforced, because the script is followed as written: orders are not limited to the caller's account, so any caller who passes the email check can look up or change any order number; there is no second check or status rule on an address change; the email on file is readable by the AI; the caller number only identifies and can be spoofed. These are consequences of the script, not bugs; I can add any of them later in one step each.

## 11. Salesforce work (files for you; nothing deployed or created without your yes)
1. Permission set `Voice_Agent_Customer_Service` (file): read Contact (five fields), read Order and Account, edit only the 5 shipping fields on Order. You deploy; I give the check-only command first.
2. **Demo data (needs your explicit yes):** 3 Contacts on `DEMO - ` accounts with phone and email, and shipping addresses on the 6 demo orders, all prefixed `DEMO - `, tested first in a rolled-back transaction, with a cleanup script. The 136 candidate contacts are never touched.
3. **Rolled-back write test (needs your yes):** shows whether an Activated order's address can be updated and which state and country values are accepted.

## 12. Test plan
Offline (all must pass before anything is built into a package): known caller; unknown number; two contacts on one number; contact without email; spoken email forms; wrong email 1, 2, 3 then lockout; tool error not counted; order not found; status read; address read; update with only a street; update with an injection string; over-long street; bad country; 401 and 500; no token leaks.
Callbacks: greeting with and without a name; start-of-call lookup; outcome mapping for verification failed.
Console (Preview, with a test number as the default of `telephony-caller-id`): your full script; wrong email twice then right; three wrong; unknown number; address change; a broken secret (spoken apology). A read-only query of the transcript row after each call.

## 13. Decisions
All closed. The script is followed as written; D1 to D7 are not implemented. The medical-topic rules of the current Pharma agent are **not** carried over, and no Abbott rules are added.

## 14. Phases and risks
| Phase | What | Gate |
|---|---|---|
| 1 | Spike: a 10-line callback that calls a tool at session start and prints `telephony-caller-id` (you run it in the console) | Proves the greeting design |
| 2 | Salesforce files; your yes for demo data and the rolled-back test | explicit yes |
| 3 | Build with the skill: new templates, instructions, spec, offline tests, validator | all tests green |
| 4 | Paste or import into the console, run the test list, send me the export, compare | export diff clean |
| 5 | Phone number, a real call, compliance check, docs and PDF update | go-live checklist |

| Risk | Handling |
|---|---|
| A callback calling a tool at session start is documented but unverified | Spike. Fallback: the callback inserts the tool call, as the verified transcript hook does |
| No caller number in Preview | Set a test number as the default of `telephony-caller-id`; clear before go-live. Per-session setting is unverified |
| Speech recognition garbles emails | Cleaning of spoken forms, spelling accepted, three tries |
| Salesforce may refuse an address update (Activated order, picklists) | Rolled-back test; otherwise a spoken apology and escalation |
| This org's Contact table mixes customers and candidates | Lookup needs an Account and an exact phone match; no writes to Contact |
| Abbott is a regulated healthcare company | Confirm recording, consent and data rules before real customers; demo with fictional data |
| Hang-ups leave no transcript | Known gap |
