# Salesforce patterns and pitfalls for CES agents

## Read-only discovery (no data read)
`python3 scripts/sf_discover.py --check` lists orgs signed in through the `sf` CLI. `--org <alias> --keywords a,b,c` writes `org-summary.md`
and `org-profile.json`: objects, row counts, key fields, picklist values, lookups, record types, sensitive-looking fields. The script uses
`sf api request rest`, so it never sees an access token. It makes only GET requests. Zero rows means a live test needs test data: ask first, never create silently.

## REST essentials
- Query: `GET {instance}/services/data/v68.0/query?q=<SOQL>` -> `{totalSize, done, records[]}`. Related fields come nested (`Account.Phone` -> `record["Account"]["Phone"]`).
- Record: `GET/PATCH /sobjects/<Object>/<Id>` (PATCH returns 204 with no body), create: `POST /sobjects/<Object>` -> `{id, success}`.
- SOQL values: escape `\` and `'`; normalize digits-only identifiers; never build queries from raw speech.
- Phone fields are free text. Compare digits only and the last 10 digits ("+1 (416) 555-0142" equals "4165550142"). A blank stored value never matches.

## Tokens (the part that bit us)
- `sf org display` no longer returns a usable token (the field is a redacted placeholder). Use `sf org auth show-access-token --target-org <alias>`; it asks for confirmation and the token expires in about two hours. Treat it like a password and never paste it in chat or commit it.
- A package exported from the console contains variable defaults in clear text. Always run `validate_package.py` before sharing an export.
- The package this skill builds ships the token variable **empty**. After import set it (POC), have the backend inject it per session, or use OAuth through a toolset.

## OAuth client credentials (production, toolsets): verified setup
Full step-by-step with the screens, the Google side and the connector dialog values: `setup-gcp-and-salesforce.md`. The essentials:
1. External Client App (Setup -> External Client App Manager): enable OAuth, scope **Manage user data via APIs (api)** (not Full access), enable the **Client Credentials Flow** on the Settings tab and on the Policies tab, set the **Run As** user, set IP Relaxation to relaxed (tighten later).
2. Prove it from a terminal before touching Google: `sf_oauth_check.py --org <alias> --soql "..."` (hidden prompts for key and secret; prints the token never). It names the likely cause for each known error.
3. Google: enable Secret Manager, store the consumer secret, give `service-<PROJECT-NUMBER>@gcp-sa-ces.iam.gserviceaccount.com` the Secret Manager Secret Accessor role on that secret.
4. Connector dialog: **leave OAuth scopes empty**; token endpoint `<instanceUrl>/services/oauth2/token`; secret = the secret version.
5. Rotate any secret that was ever pasted into a chat.

## Least privilege (this is the real security boundary)
The agent can do whatever the integration user can. Create a user and permission set for the agent: read-only on the needed objects, field-level security on only the fields the tools return, no "View All Data". Keep sensitive fields (birth date, financial, health) out of `return_fields`.

## Data model gotchas
- Order: `OrderNumber` is an auto-number with 8 zero-padded digits (`00000100`); callers say "100", so normalize with `pad: 8`. Only the statuses Draft and Activated exist unless the org adds more. `EndDate` is the order end date, not a delivery date; there is no standard delivery-date field. Activated orders need order items; an activated order must go back to Draft before it can be deleted. Order has no phone: use `Account.Phone` (or a Contact phone).
- Case: required fields vary by org; set `Origin` as a fixed value; assign `AccountId` and `ContactId` from verified variables.
- Contact vs Account: choose the object the caller actually identifies with; person accounts store phones on the account.
- Picklists: pass the exact API value; use `allowed` lists in the spec to validate.
- Record types, validation rules, required custom fields and triggers can reject writes: test writes in a sandbox first.
- Limits: daily API request allowance per org (Developer Edition shows 450,000 per 30 days in `TenantUsageEntitlement`); each tool call is one or two requests.
- Sandboxes and production have different instance URLs; one package per environment (use environment variables or rebuild with the other URL).

## Test data
Mark everything the skill creates with a clear prefix (for example `DEMO - `) so it can be removed in one query, test the cleanup script inside a rolled-back
transaction, and tell the user exactly what was created. Do not create data without their approval, and do not touch other apps' data in the same org.
