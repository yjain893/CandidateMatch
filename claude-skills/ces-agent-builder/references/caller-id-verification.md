# Greeting by name from the caller's number, email verification, order lookup and change

Built and tested offline (Nov 2026); **not yet run in the console**. Example: `assets/example-caller-id-service`. A real build: the Abbott customer service agent in the user's repo.

## The pattern
```
call arrives, platform fills telephony-caller-id
  -> before-model callback greet_known_caller runs tool identify_caller (one Contact on the number, with an Account)
  -> greeting by first name (or without a name); caller_status = known | unknown
caller says what they need -> verify_contact_email (spoken email compared in code, 3 tries)
  -> get_order_status / get_shipping_address (lookup_record) -> update_shipping_address (update_record through a connector operation)
end_session -> save_transcript_on_end (transcript row)
```

## Tools and operations
| Tool | Template | Connector operation |
|---|---|---|
| `identify_caller` | `identify_caller` | the shared `find_order` operation (contact query shape) |
| `verify_caller_email` | `verify_contact_email` | none (compares variables) |
| `get_order_status`, `get_shipping_address` | `lookup_record` with `remember_id_as` | `find_order` (order query shape) |
| `update_shipping_address` | `update_record` with `write_connector_tool` | `update_order_address` (PATCH `/sobjects/Order/{id}`) |
| `save_transcript` | `save_transcript` with `links` set to the variables of this agent | `save_transcript` (upsert) |

One `GET /query` operation serves the contact and order lookups; its `q_pattern` is an alternation of the two shapes.

## Phone matching
The query fetches contacts whose phone or mobile ends with the last four digits (`LIKE '%1234'`, at most 20, with an Account); the tool compares the trailing digits (up to 10, at least 7) in code. Zero or several matches mean unknown. Fine for thousands of contacts; at large scale use SOSL or an indexed normalised phone field.

## Decisions to take with the user (each was a choice in the Abbott build)
- Whether the stored email may sit in a variable the AI can read (dynamic variables reach the AI as `state_update` events), or only a hash, or nothing stored.
- Whether orders are limited to the caller's account, whether an address change needs a second check or a status rule, and what happens to an unknown number.
- Which domain rules the instructions carry. None unless the user asks.

## Verified in the Preview simulator (one call, 21 Nov 2026)
- A before-model callback can run a Python tool at session start (`mode: direct`) and speak the greeting by first name. A test number set as the default of `telephony-caller-id` reaches the tool.
- The stored name, email, account and last order reached later tools and the transcript row (links to the account and the order were saved).
- Email check (a wrong then a right email), order status, reading the address, and an address change on a Draft order saved in Salesforce through the connector's PATCH operation.

## Still unverified
- Why one Preview start was silent (the cause was not found: see lessons-learned 33). The callback and the instructions now cover the likely causes.
- Which of the three request body shapes the connector accepted (the tool logs it).
- An address change on an Activated order, and which state and country values Salesforce accepts (a rolled-back Apex test is provided as a file for the user to run).
- Real caller ID on a phone call; `mode: tool_call`; transcripts for calls ended by a callback (probably not saved).
