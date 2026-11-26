# Cases from voice-agent transcripts (serviceOrg): decisions, mistakes, ideas and open items

Written 2026-11-25 from the long Claude Code session of 18 to 25 Nov 2026 (transcript: `~/.claude/projects/<this-project>/570ea90f-a49c-4507-a6a6-2f35c579aeed.jsonl`; this workstream is the user messages from 2026-11-24 09:46 to 2026-11-25 05:13). Purpose: a new session should not have to guess. Facts marked **(unverified)** were not confirmed. Related files: `docs/voice-agent-serviceorg-decisions.md` (the voice agent that creates the transcripts) and `docs/token-estimates-decisions.md`.
Left out on purpose so this file is safe to publish: keys and secrets, the Google project id, the sandbox host name, personal usernames and names.

## 1. What this is
In **serviceOrg** (a sandbox, alias `serviceOrg`) the voice agent saves each call to `Chat_Conversation__c` (transcript in `Transcript__c`). The user also owns the Case process: when a finished transcript exists, a **Case** should be created automatically, linked to the transcript, with a subject, description and **category** written by an AI prompt template from the transcript text.

## 2. How the user works (rules to follow)
- **Plan first, show the files, then do it only after approval** ("Do not do anything. First show me the plan and the file that you're going to change or create"). The user's answers to the five plan questions (section 3) were the approval to build and check-only validate; they then approved each real deploy ("Yes, fields first", "Yes, do it", "Yes, deploy"; later "trigger ... deploy those", "Yes, deploy" for the template version).
- Check-only deploys first (`sf project deploy start -o serviceOrg --dry-run --test-level RunSpecifiedTests --tests <Test> ...`); the assistant cannot compile Apex locally.
- **Never delete an existing prompt template version**; create a new version instead.
- **Do not push to git unless asked.** The work was committed and pushed on the user's request to `feature/voice-agent-transcript` (commit `b3751a8`, 2026-11-25); `main` was not touched. The repo is public: no secrets or personal data.
- Very simple language, short answers.
- Do not touch `Case.Is_Classified__c` (the user said no).
- The user said the **manager has not yet approved changes to the voice agent**; the Case trigger is live in the serviceOrg sandbox and changes the end of every call (a Case appears). Check with the user before saying it is "done".

## 3. The five questions and the user's answers (24 Nov)
| # | Question | Answer |
|---|---|---|
| 1 | How is the Case created today (Flow, Apex, agent action)? A Flow cannot split JSON easily. Suggest a small Apex action | **"create the class"** |
| 2 | Lookup direction: on the transcript (file 1), on the Case (file 5), or both | **Lookup on the Case object only** ("I only want file 5 and not 1") |
| 3 | Category values | Basic list, **not restricted** so the user can edit later |
| 4 | Set `Is_Classified__c` when a category is assigned? | **No** |
| 5 | Who needs access to the new fields? | "consider any permission set that you created" |

## 4. What was built (all in `force-app/main/default/`; deployed to serviceOrg and committed on `feature/voice-agent-transcript`)
| Item | File(s) | Notes |
|---|---|---|
| Lookup | `objects/Case/fields/Chat_Conversation__c.field-meta.xml` | Case to `Chat_Conversation__c`, delete constraint SetNull, relationship name `Cases` (so the transcript has a child list "Cases") |
| Category picklist | `objects/Case/fields/Category__c.field-meta.xml` | Unrestricted. Values: Order Status, Shipping Address Change, Billing or Invoice, Product Question, Complaint, Technical Issue, Verification Failed, Other (default) |
| Prompt template | `genAiPromptTemplates/Create_Case_From_Transcript.genAiPromptTemplate-meta.xml` | Type `einstein_gpt__flex`. Inputs `Conversation` (`SOBJECT://Chat_Conversation__c`, reads `Transcript__c`) and `Categories` (`primitive://String`, the live picklist values joined). Returns JSON `{subject, description, category, confidence}`. Rules: subject at most 120 characters; description 2 to 6 sentences with outcome; never include card numbers, passwords, email addresses or full street addresses; empty or unclear transcript gives category Other, confidence low. **The user activated it in Prompt Builder** (deployed as Draft) |
| Case creator | `classes/CaseFromTranscript.cls` + `CaseFromTranscriptTest.cls` | `@InvocableMethod` and `createCase(Id)`. Reads the live picklist (describe), calls the template through `ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate` with input keys `Input:Conversation` and `Input:Categories`, validates the category (case-insensitive, fallback Other), subject limited to 255, `Origin = 'Phone'`, **idempotent**: returns the existing Case for that conversation. Test seams `mockResponse` / `mockError`. `PromptRunner` is **not** in serviceOrg, so the call is inlined here |
| Trigger | `triggers/ChatConversationCaseTrigger.trigger` | After insert/update on `Chat_Conversation__c`; picks rows where **`Conversation_Status__c = 'Closed'` and the transcript is not blank**; on update only when the row just became qualifying; skips in queueable/future/batch context; enqueues the job |
| Job | `classes/CaseFromTranscriptQueueable.cls` (+ test) | `Queueable, Database.AllowsCallouts`; calls `createCase` per id inside try/catch (errors only `System.debug`, the transcript itself is already saved) |
| Layout | `layouts/Chat_Conversation__c-Chat Conversation Layout.layout-meta.xml` | Added a **Cases related list** (case number, subject, status, category) on the transcript page. No custom Lightning record page for Chat Conversation was found |
| Permission set | `permissionsets/Voice_Agent_Chat_Conversation_Writer.permissionset-meta.xml` | Field permissions on `Case.Category__c`, `Case.Chat_Conversation__c` and the transcript fields; class access to `CaseFromTranscript` and `CaseFromTranscriptQueueable`. **No Case object permission**, see mistake 1. Assigned to the integration user and to the admin user |
| Case summary template | new Draft **version** of `Summarise_Case_All_Components` + `classes/CaseTranscriptsForPrompt.cls` (+ test) | See section 6 |
| Dashboard fix | `lwc/chatAnalyticsDashboard/` | Percent rounding, see section 7 |

## 5. Decisions with reasons
1. **Apex class, not a Flow** (user chose "create the class"): the template returns JSON, a Flow cannot easily split it, and Apex can also check the category against the picklist.
2. **Trigger, not a Flow**, for firing it (user chose "trigger"): the assistant recommended it because it runs as the user who saved the transcript (the admin Run As user has prompt access), it is covered by tests in the repo, and it needs no activation step. A record-triggered Flow with an asynchronous path would also work since the class is invocable, but which user it runs as was uncertain.
3. **When to create the Case:** "Status = Closed with a non-blank transcript", which happens once at the end of the call (not on every insert).
4. **Queueable**, because the prompt-template call cannot run inside the trigger transaction.
5. **Category read live from the picklist** every time, so edits to the picklist are picked up with no code change.
6. **Unknown category falls back to "Other"**; the class never writes a value outside the picklist.
7. **Lookup on the Case only** (the user's choice): each Case points at one transcript.

## 6. The "Summarise Case All Components" template (25 Nov)
- Found by retrieving `GenAiPromptTemplate` into a scratch project (SOQL on that type fails: "sObject type 'GenAiPromptTemplate' is not supported"). Other Case templates in the org: `Generate_RCA_from_Case`, `Status_Aware_Case_Summary`, `Email_Draft_Response`, `Similar_Case_Search`, `Find_Similar_Cases`, `Summarize_Bot_Session`, `Summarizing_chats_for_case`, `Create_Case_From_Transcript` (ours).
- "Summarise Case All Components" (version 6 active, Published, model GPT-4o Mini) reads the Case through the built-in **Record Snapshot** (Case description, comments, messaging sessions, feeds; which objects the snapshot includes is not visible in the template) plus the Apex provider `CaseActivitiesForPrompt` (Tasks, Events, EmailMessages, newest first, 20 each, 500 characters each).
- The user asked to include the transcript. **Decision: do not delete any version; add a new Draft version** with a "Call Transcript" section fed by a new Apex provider `CaseTranscriptsForPrompt` (finds the Case's `Chat_Conversation__c`, returns start time, message count and the transcript, 3,000-character cut, "NO TRANSCRIPT RECORDS" when none), copying how the Activities provider works. Deployed (3 of 3 tests). **The user must preview the new version on a Case (for example one with a linked transcript) and publish it in Prompt Builder; version 6 stays active until then.** Not published as of writing.

## 7. Dashboard fix (25 Nov)
`chatAnalyticsDashboard` (an LWC that already existed in serviceOrg and was copied into the repo) printed percentages like 33.3333333333% and overflowed its boxes. First fix rounded only values typed as numbers and did nothing (the values arrive as text). Final fix: convert every percentage with `Number()` and round to one decimal in `get summary()` and in `bar()`. Deployed twice. The user said "just fix it" for the second one, so it was deployed without a separate approval. Not visually re-checked by the assistant. **Open question to the user: the first four Chat Analytics rows (CONV-000000 to CONV-000003, 24 Nov 09:15 to 09:31) are failed test calls from the license-limit period** (the agent could not read Contacts/Orders and said "connecting you with a team member"); the AI analysis ("Not Resolved, escalated") is correct for them, but they pull the dashboard numbers down. Deleting them was offered; the user has not answered.

## 8. Mistakes made (so they are not repeated)
1. **Case object permission on an Integration-license permission set:** "The user license doesn't allow the permission: Read Case". Removed the Case object permission; field permissions only (and the admin Run As user does not need it).
2. **Check-only run failed on every test** with "No such column 'Category__c' on entity 'Case'": new custom fields were not visible to the deploying user because **no field-level access existed** (describe respects FLS). Fix, in this order: deploy the two Case fields, then deploy the permission set (without the class access line, because the class did not exist yet), assign it to the admin user, then re-validate the class.
3. **Coverage 73.7%** (needs 75): added a test that calls the class with no mock (the real ConnectApi call cannot succeed in a test, the error must be reported not thrown).
4. **Test setup:** `Chat_Conversation__c` requires `Conversation_Identifier__c`; and only one `Test.startTest()` is allowed per test ("Testing already started"), so tests restructured.
5. **Deploying a folder swept in an unrelated trigger** (`ContentDocumentLinkTrigger` failed with "Variable does not exist: ResumeQueueHandler"). Deploy named files, never the whole `triggers` folder.
6. **A retrieve pulled 27 unrelated flexipages into the repo**; removed. Retrieve into a scratch project outside the repo instead.
7. **The auto-mode safety check blocked a real permission-set deploy** until the user said yes ("Yes, do it"). Real deploys need the user's explicit yes per action.
8. **Wrong first explanation of the Case page:** the user wanted a right-hand "Chat Conversations" section like "Messaging Sessions (0)" on the Case page. The assistant had added the related list on the **transcript** page, which is the other direction. See open item 1.

## 9. Verified in the org
- Manual run: Case **00002953** was created from CONV-000004 (subject "Caller requested order status and a shipping address change", category Shipping Address Change, Origin Phone, lookup set, `Is_Classified__c` false). The generated description mentioned order numbers but no email or address.
- **Automatic run:** Case **00002954** was created from CONV-000005 by the trigger after a real Preview call (screenshot from the user).
- Tests: 9 of 9 (Case creator), 14 of 14 (with the job and trigger), 3 of 3 (transcript provider).
**Not verified:** the trigger when the transcript is saved by the integration user (Run As is the admin today); behaviour when the prompt call fails (no retry, only a debug log); the new template version with a real preview; the Case's content for calls that are escalated or fail verification.

## 10. Open items
1. **Case page section (user's request, undecided).** The lookup is on the Case, so a normal related list (child list) is impossible on the Case page. Options given: (a) a **Related Record** component on the Case record page showing the linked transcript (assistant's recommendation, no new field; add in Lightning App Builder or have the assistant retrieve and edit the Case page); (b) a second lookup on `Chat_Conversation__c` to Case (the user rejected "file 1" earlier) so a real child list exists, and the trigger would fill it.
2. Publish the new "Summarise Case All Components" version after previewing.
3. Case 00002953 was a manual test and still exists (delete if not wanted).
4. Delete the four failed test conversations and their analytics rows, or leave them (section 7).
5. **Manager approval** for the voice agent changes, including the live trigger.
6. Ideas not built: Case owner/queue assignment, Case status rules, linking the Case to the Contact/Account from the call (the transcript object has no links), retry on prompt failure, copying the category list into a custom metadata/picklist governance, Flow version of the trigger.

## 11. Verified commands and facts that save time
- Retrieve templates: `sf project retrieve start -o serviceOrg -m GenAiPromptTemplate` (inside a scratch project folder outside the repo).
- Run the creator by hand: `CaseFromTranscript.createCase('<Chat_Conversation__c Id>');` in `sf apex run` (idempotent).
- The org has `Chat_Conversation__c.Transcript__c` as long text (131,072): it cannot be used in a SOQL WHERE; select it, do not filter on it.
