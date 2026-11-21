# Setup guide: Salesforce, Google Cloud and CX Agent Studio (production-style OAuth, verified end to end)

This is the sequence that worked for a Salesforce-connected voice agent. Do the parts in order and test after each one (the test is the last line of each part).
Placeholders: `<domain>` = the Salesforce My Domain host, `<project>` = the Google Cloud project id, `<PROJECT-NUMBER>` = its project number.

## Part 1. Salesforce

### 1.1 Data the agent needs
- Run `sf_discover.py` first (read-only) to see the real objects, fields, picklists and row counts. Use only fields it confirms.
- Order facts: `OrderNumber` is an auto-number with 8 digits (`00000102`); statuses are only Draft and Activated unless the org adds more; `EndDate` is the order end date, not a delivery date; an Activated order needs order items.
- No test data? Ask before creating any. Prefix everything `DEMO - `, create it in one transaction, test the cleanup script inside a rolled-back transaction first, and tell the user exactly what exists.

### 1.2 The user the agent runs as ("Run As" user)
- Prefer a dedicated integration user with a permission set: **API Enabled**, read access to only the needed objects and fields (for example Order: number, status, dates, total, AccountId; Account: Phone).
- For a quick demo your own admin user works, but it can read everything. Replace it before production.

### 1.3 External Client App (Setup -> External Client App Manager -> New)
1. Name, contact email. Turn on **Enable OAuth**. The callback URL is required by the form but unused by this flow: any https placeholder works.
2. **Settings tab -> OAuth Settings -> OAuth scopes:** select **Manage user data via APIs (api)**. Do **not** choose "Full access (full)": it does not satisfy this flow (`invalid_grant: no valid scopes defined`).
3. Under flow enablement tick **Enable Client Credentials Flow**. Save.
4. **Policies tab -> Edit:** tick **Enable Client Credentials Flow**, choose the **Run As user**, set **IP Relaxation** to *Relax IP restrictions* (Google's servers have no fixed addresses; tighten later if you can). Leave Permitted Users, start page and refresh-token settings alone. Save.
5. **Settings tab -> OAuth Settings -> Consumer Key and Secret.** Salesforce emails a verification code. Copy the key and the secret yourself. Never paste them into a chat.
6. Wait a minute or two: a new app or a changed scope can take a moment to apply.

**Test it before touching Google** (run in your own terminal; it hides what you type and never prints the token):
```
printf 'Consumer key: '; read -rs SF_KEY; echo; printf 'Consumer secret: '; read -rs SF_SECRET; echo; export SF_KEY SF_SECRET
python3 ~/.claude/skills/ces-agent-builder/scripts/sf_oauth_check.py --org <alias> --soql "SELECT Id,OrderNumber,Account.Phone FROM Order LIMIT 1"
```
Expected: `token issued: True`, scope `api`, then `QUERY: HTTP 200`. On an error the script prints the likely cause and fix. Only continue when it passes.

## Part 2. Google Cloud (the project that owns the CX Agent Studio app)

1. **Enable the Secret Manager API** (APIs and Services -> Library -> Secret Manager API -> Enable, or the link in the console message). It can take a few minutes to take effect.
2. **Create the secret** (Security -> Secret Manager -> Create secret): name `salesforce-client-secret`, value = the Salesforce consumer secret with no trailing newline or space. Standard global secret (regional secrets are not supported here).
3. **Find the project number** (Dashboard -> Project info). The CX Agent Studio service agent is `service-<PROJECT-NUMBER>@gcp-sa-ces.iam.gserviceaccount.com`.
4. **Grant it the role** on that secret: secret -> Permissions -> Grant access -> principal = the service agent, role = **Secret Manager Secret Accessor** (on the secret, not the whole project).
5. Note the secret version path `projects/<project>/secrets/salesforce-client-secret/versions/1`. Adding a new secret value later creates a new version: select it in the connector dialog.

Equivalent gcloud commands (the secret value comes from the environment, never typed inline):
```
gcloud services enable secretmanager.googleapis.com --project=<project>
printf '%s' "$SF_SECRET" | gcloud secrets create salesforce-client-secret --data-file=- --replication-policy=automatic --project=<project>
gcloud secrets add-iam-policy-binding salesforce-client-secret --member="serviceAccount:service-<PROJECT-NUMBER>@gcp-sa-ces.iam.gserviceaccount.com" --role="roles/secretmanager.secretAccessor" --project=<project>
```

## Part 3. CX Agent Studio

1. **Declare the variables** before pasting the tool (Variables in the app): `caller_verified` Yes/No false, `verified_record_id` Text, `verified_scope_id` Text, `verification_attempts` Number 0.
2. **Create the Salesforce tool** (Tools -> + -> Salesforce):

| Field | Value |
|---|---|
| Name | `query_salesforce` |
| Description | Connector used only by the Python tool; the agent never calls it directly |
| Mock tool response | off |
| Server | `https://<domain>.my.salesforce.com/services/data/v68.0` |
| Authentication type | OAuth |
| OAuth client ID | the consumer key |
| Secret | `salesforce-client-secret` and its version |
| OAuth endpoint URL | `https://<domain>.my.salesforce.com/services/oauth2/token` |
| OAuth scopes | **leave empty** (Salesforce answers `scope parameter not supported` to a client credentials request that carries a scope) |
| Schema (JSON tab) | the generated `open_api_schema` (one fixed `GET /query` operation, `q` locked with a `pattern`, only the response fields the tool reads) |
| Advanced | defaults. Keep "Ignore unknown fields" off |

3. **You do not need to attach the connector to the agent.** The Python tool calls it as `tools.query_salesforce_find_order({"q": soql})` (name = `<connector name>_<operationId>`) and that works while the agent's own tool list holds only the Python tool and `end_session`. The model therefore cannot call the connector itself.
4. **Create or paste the Python tool** (generated by the skill, `transport: connector`). Same tool name as the instructions reference (`authenticate_user`, lowercase snake_case).
5. **Instructions:** structured XML, `{@TOOL: authenticate_user}` matching the attached tool, explicit handling of `verified`, `not_verified`, `locked_out`, `system_error`; `end_session` listed in the agent's tools.
6. **Callbacks (recommended):** `static_greeting` (fixed first line, no model call) and `escalate_on_system_error` (speaks a fixed apology, then ends the session as escalated). Without it the agent can hang up silently on a system error.
7. **Guardrails:** keep the two defaults and check each toggle is enabled (an export with no `enabled` key means disabled). Add an LLM policy for domain rules (for example no medical advice) only if you accept the added latency.
8. **Model and voice:** `gemini-composite-v2` is the voice-optimized model (no thinking level to set); pick a Chirp 3 HD voice; a short speaking style or none.
9. **Test:** Tools -> `authenticate_user` -> Test Tool with `{"order_number": "102", "phone_number": "4165550142"}` (expect `verified: true`), then the Preview agent for the full call, then the failure paths (wrong detail twice, three failures, empty variable or revoked secret to prove escalation).

## Part 4. Before production
- Replace the Run As user with a dedicated least-privilege user; set IP Relaxation as tightly as possible.
- Rotate any secret that was ever pasted into a chat, ticket or email: new secret in Salesforce, new Secret Manager version, select it in the connector.
- Export the agent and run `validate_package.py` before sharing it (variable defaults are exported in plain text).
- Take a version snapshot; set recording and redaction policy; deploy to the channel in the console.
