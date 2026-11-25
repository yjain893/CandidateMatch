# Candidate Matcher V2: decisions, history and open items

Written 2026-11-25 from the long Claude Code session of 18 to 25 Nov 2026 (transcript: `~/.claude/projects/<this-project>/570ea90f-a49c-4507-a6a6-2f35c579aeed.jsonl`, the first ~70 user messages, 2026-11-18 to 2026-11-19, are this workstream). Purpose: a new session on this topic should not have to guess. Facts marked **(unverified)** were not confirmed against the org or repo when this was written.

## 1. The project in one paragraph
A Salesforce app ("Candidate Matcher V2") for a large Canadian recruiting firm that handles thousands of candidates a day with several recruiters at once. Resumes are parsed by an AI prompt template, job descriptions are read by another prompt template, and a third prompt template scores each candidate against a job. AI scoring is slow and costs credits per candidate and per job, so the main goal is to **send fewer candidates to AI scoring** by adding trustworthy filters on the left of the `candidateMatcherV2` screen, and to keep AI use (tokens/credits) low.

## 2. How the user works (rules to follow)
- The **user deploys manually** unless they say "deploy". Default: show the list of changed files; do not deploy. (They did say "deploy" for the four DemoDataLoader files on 18 Nov and the assistant deployed them.)
- When the user says "do not change anything / show me the plan first", do exactly that.
- Very simple, non-technical language. Short answers.
- Do not push to GitHub unless asked. The repo `yjain893/CandidateMatch` is **public**: no secrets, keys, customer data.
- No hardcoded vocabulary or word lists in matching code (rejected 18 Nov, see 6.3). No extra AI call on "Apply filters".
- Salesforce org alias for this work: **`demoOrg`** (a Developer Edition org, alias confirmed in `sf org list`). The other alias, `serviceOrg`, belongs to the voice agent work, not this one. Ask the user before running any `sf` command that changes an org.
- The assistant cannot compile Apex locally; tests run in the org (check-only deploys are fine: `sf project deploy start -o demoOrg --dry-run --test-level RunSpecifiedTests --tests <Test>`).
- Branch: all work sits on `feature/voice-agent-transcript` (the user does not want separate branches). Candidate Matcher work is already committed: `7d9916a`, `cc442d6`, `ba7df90`, `9565dac`, `9bf598c` ("updated chnges for demo", includes the compound-skill plan and the verify scripts).

## 3. What was built (all in `force-app/main/default/` unless noted)
| Area | Files | What it does |
|---|---|---|
| Screen | `lwc/candidateMatcherV2/` (html, js, css) | Left filters: work mode, city (placeholder "Toronto, Ottawa"), max salary (CAD), role types, **Skills** section and **Date available** tiles, live count box, sticky Apply/Clear bar. Right side: ranked candidate cards. Top-match tile names the best candidate and "+N tied". |
| Filtering and counts | `classes/CandidateMatcherV2Controller.cls`, `classes/CandidateMatchOrchestrator.cls` | `getJobSkills`, `countMatches` (matched, pool, per-skill counts, per-date-window counts), `findCandidates`, `readPool`, `start` (scoring run). |
| Scoring | `classes/CandidateMatchService.cls` | Weighted score, see 5.3. |
| Job requirement extraction | `classes/JobRequirementsService.cls`, `JobRequirementsBatch.cls`, `JobRequirementsScheduler.cls` + tests | Batch pre-extracts required and nice-to-have skills so "Apply filters" never runs extraction. |
| Resume parsing | `classes/ResumeParserService.cls`, `ResumeParseBatch.cls`, `ResumeParseScheduler.cls`, `PromptRunner.cls` | Parses PDF resumes with the prompt template into `Skill__c`, `Employment_History__c`, `Education_History__c`. |
| Prompt templates | `genAiPromptTemplates/Parse_Resume`, `Extract_Job_Requirements`, `Score_Candidate_For_Job` | The three AI steps. |
| New fields | `Contact.Date_Available__c` (Date), `Job__c.Skill_Map__c` (long text JSON: skill to aliases), `Skill__c.Canonical_Key__c` (text 80); permission set `Resume_Matching` has access | See 6. |
| Demo data | `classes/DemoDataLoader.cls`, `DemoDataBulkBatch.cls`, tests | Canadian, executive-level demo data. |
| Scripts | `scripts/apex/demo_verify_1..5_*.apex`, `demo_fix_dates_and_salaries.apex`, `refresh_scores_half_up.apex` | Read-only checks and one-off fixes used before the client demo. |
| Plan doc | `docs/compound-skill-matching-fix-plan.md` | Open work item, see 8. |

## 4. Decisions taken, in order, with the reason
### 4.1 Filters (18 Nov)
- The user asked for filters that make "very good sense" for a Canadian client. Two Claude sessions' advice was compared. Adopted ideas: province and metro area, English/French as separate fields with levels, "legally entitled to work in Canada" (never citizenship or PR), work-permit expiry for contracts, **date available** instead of notice period, salary labelled CAD, security clearance, employment type, professional designations, candidate status/owner/pool, excluded companies (client no-poach), audit trail of filters used.
- **Not to filter on:** "Canadian experience" (banned in Ontario job postings from 2026-01-01 per law-firm summaries) and named Canadian employers as a proxy for it. The assistant withdrew its own earlier "Big 5 banks, Rogers, Bell, Telus" idea for this reason. Legal points came from web searches of law-firm summaries: **counsel must confirm** (Haseeb v. Imperial Oil 2023 ONCA 364; Quebec Charter s.46/46.1; Law 25 s.12.1; Ontario Working for Workers Acts). Education minimum was deferred (free-text degree field). Skill-depth filter was flagged risky because `Years_Experience__c` is often null.
- **User then narrowed it to two additions only:** (1) **Skills** (required + good-to-have), (2) **Date available**. Everything else stayed out of scope.

### 4.2 Skills and date UI (18 Nov, after several mockups)
- Required skills are **pre-selected from the job**; good-to-have are listed separately and not selected. All skills in one place (no "must have / good to have" dropdowns).
- Each skill shows "how many candidates have it". The meaning of the count was clarified: unselected = candidates left if you add it; selected = candidates left if you remove it.
- Date available is **tiles**, not a dropdown: Immediately, within 2 weeks, within 1 month, within 2 months (windows 0/14/31/62 days). No "available by" field, no "include candidates with no date" checkbox, no helper sentences, no right-hand panel. **Strict date rule: a candidate with no date is excluded once a window is chosen.**
- **Zero-result display (approved after two rejected mockups):** when nothing matches, no numbers or bars on the skill rows, no hint line, no section header; show a headline plus one reason line (pool is 0: other filters; skills empty the list; date); **Apply is disabled**; date tiles blank when skills empty the list or the pool is 0. The user's logic: a message saying "no candidates match" must not sit next to numbers that say otherwise.

### 4.3 Job requirements are pre-extracted, not extracted on Apply (18 Nov)
Required/good-to-have skills must exist before the user clicks Apply, so a batch (`JobRequirementsBatch`, scope 1 because a callout cannot follow DML) fills them. The scheduler was **not** switched on: the user asked to run it once ("just now") with `JobRequirementsScheduler.runNow()`. Re-extraction: `Database.executeBatch(new JobRequirementsBatch(3650), 1);`. `EXTRACTION_VERSION` (now `skill-aliases-2`) is folded into `Requirements_Hash__c`, so a prompt change forces re-extraction.

### 4.4 Matching skills by meaning: the skill-alias problem (18 Nov, the biggest design thread)
Problem: "LWC" vs "Lightning Web Components", "REST API" vs "REST API Integration" were not matching, so good candidates (for example Aarav Sharma on Senior Developer) were hidden.
Options discussed and the outcome:
1. **Exact key match only** (the original): rejected, misses synonyms.
2. **Job-side alias map saved on the job record** (`Job__c.Skill_Map__c`, written by the extraction prompt): **chosen**. The user explicitly did not want a separate batch for it, just a mapping saved on the job record.
3. **Candidate-side standard name** (`Skill__c.Canonical_Key__c`, written by the resume-parse prompt): **chosen**, done "for the contact side as well". Now always stored (the AI's standard name, or the skill's own key if none); only rows saved before the field existed are empty, and a re-parse fills them.
4. **Hardcoded short-form rules** (`skillVariants()` with word lists `GENERIC_ENDINGS`, `TOO_BROAD`, plural folding): built, then **rejected by the user** ("it will never be true for all the skills in the world"). Fully removed with its tests. **Lesson: no vocabulary lists, no language-specific rules in matching code.**
5. **Word overlap, no AI** (user's words): **chosen as the final rule.** A stored skill (`Name_Key__c` or `Canonical_Key__c`) satisfies a job skill if it equals the job skill key, or any alias key, or (a) is a run of consecutive words of the job skill/alias that covers at least 60% of its words (only for names of 3+ words; `partialNames`), or (b) is a longer stored name that contains a multi-word job skill/alias as whole words and where that phrase is at least 60% of the stored name's words. Single-word skills match only by exact name or alias, never cut out of longer names. Constants in `CandidateMatchOrchestrator.cls`: `MIN_OVERLAP_PERCENT = 60`, `MAX_WORDS_SPLIT = 8`, `MAX_CONTAINED_NAMES = 40` (the first 40 multi-word names get the longer-name LIKE matching; job skills first, then aliases alphabetically).
6. **Prompt fixes ("make all three", 18 Nov):** extraction prompt must not list a bare vendor/company/platform name as a skill; always include the shorter form when resumes also write it that way (REST API Integration to REST API); resume prompt must give a standard name for every skill.
- The design accepts **recall over precision** in matching (a few more candidates go to scoring); the AI scoring step catches real mismatches. Normalisation key: `ResumeParserService.normalizeKey`.

### 4.5 Re-scoring rule (answered 18 Nov)
An existing `Candidate_Match__c` is reused only if `Status__c = 'Scored'`, `Scored_On__c` is not older than the job's `LastModifiedDate`, and not older than the contact's `Resume_Parsed_On__c`. **Any edit to a job (including re-extraction) makes its saved scores stale**, and the next Apply re-scores live. This is why the user was told not to edit the CTO job before the demo (only the CTO job has saved scores; others score live, about 16 seconds for 5 candidates).

### 4.6 Demo data (18 and 19 Nov)
- All Canadian (names, cities, CAD, Canadian employers and universities). No accents, because the loader's PDF writer prints plain ASCII ("Montreal" not "Montréal").
- **Then changed to executive level only** (CTO, CFO, CISO, CRO, VP Operations, CDO; 12+ years, CAD salaries). The assistant first added `Executive`, `Vice President`, `Director` to the restricted `Role_Types__c` picklists; **the user rejected the two role-type field changes** ("can we do it without them?"). Final design: `Role_Types__c` is left empty, executive level is shown by title and salary band. (Hence the old test failure: `CandidateMatcherTest` inserted `Role_Types__c = 'Developer'` into a restricted picklist; fixed by reading the org's active values, and the user deployed it.)
- **More than 100 candidates:** `addBulk(n)` is capped by CPU (each executive PDF resume costs about 120 to 150 ms). Final: `CHUNK_SIZE = 25` per transaction; `addBulk` for more than 25 and `addBulkAsync(n)` (up to 5,000) run `DemoDataBulkBatch`. Deployed and 17 tests passed in `demoOrg` on 18 Nov.
- `DemoDataLoader.addMatchingCandidates(4)` adds up to 4 candidates per job made to fit that job (city, work mode, salary, experience, skills, spread availability) so every job has matches. Result on 19 Nov: CTO 5, CFO 3, CISO 5, CRO 5, VP Ops 5, CDO 5 candidates selected with defaults; 136 candidates, 135 with a resume (Nathan Roy has none on purpose). `DemoDataLoader.run()` deletes the earlier demo set first.

### 4.7 Scoring display fix (19 Nov)
Question: why do three candidates show 98 although Liam looks better than Elena? Cause: the overall score has four parts, one hidden on the card. **Weights: Skills 45%, Experience 25%, Fit (city, mode, role, salary) 20%, Education 10%.** Apex default rounding hid a 1-point difference. Fix: all scores round **half up** (`HALF_UP` in `CandidateMatchService.cls`); ties sort by skills score, then experience score, then name (LWC and controller); top tile adds "+N tied". `scripts/apex/refresh_scores_half_up.apex` refreshes stored scores. A check-only deploy passed; the user deployed the test class themselves **(whether the rest was deployed: unverified, but on 19 Nov the assistant confirmed all 26 Apex classes and both LWCs in the org matched the repo)**.

### 4.8 Score template deactivation (18 Nov)
The "Score Candidate" prompt template became inactive after a deploy. Likely cause (**not confirmed**): the repo copies of templates are `Draft` while the org copy was `Published`, so deploying the repo copy can deactivate the active version. Rule going forward: **deploy only the changed files, never the whole `genAiPromptTemplates` folder, and re-activate versions manually in Prompt Builder.** The deploy command given to the user listed 8 files explicitly.

### 4.9 Why Aarav did not match Senior Developer
The required skill "REST API Integration" failed because the AI's alias list on re-extraction omitted "REST API" (aliases are non-deterministic). Solved generally by the word-overlap rule. "Experience Cloud" is a genuine miss (good-to-have).

## 5. Facts about the system worth knowing
1. **Why skills are evaluated in memory:** SOQL limits (about 2 semi-joins, 50,000 rows, 4,000-character WHERE so at most about 40 LIKE patterns, long text fields not filterable, aggregates at most 2,000 rows). `SKILL_ROW_BUDGET = 30000`, `MAX_SKILL_POOL = 4000`, pool limit = min(4000, 30000 / number of keys), at least 200; too many gives `FilterException` and a `tooBroad` state in the UI. Scoring is capped at 200 candidates per search.
2. **Three prompt templates** run in the background: Parse Resume (once per resume, PDF sent as an attached file, not text), Extract Job Requirements (once per job, re-run when the description changes), Score Candidate For Job (per candidate per job per new search, about 5 s per candidate).
3. Parsing status field `Resume_Parse_Status__c` (set to `Pending` and run `ResumeParseScheduler.runNow()` to re-parse; demo contacts have emails ending `@demo-candidates.example`). `ResumeParseBatch` scope 2.
4. Resume-parse run on 19 Nov: all 135 resumes `Parsed`, about 9 skills each; all skill rows had a standard name.
5. Costs and tokens (explained to the user 19 Nov; there is a doc): Salesforce meters per LLM call, rounds tokens up to 2,000-token blocks, multiplies by a model-tier rate (Flex Credits card: Starter/Basic 2, Standard 4, Advanced 16; Einstein Requests: 4, 4, 10, 38). The org's model is `sfdc_ai__DefaultGPT6Luna`, **tier unconfirmed**. Salesforce does not return tokens per call in the response. A real parse call cost about 8 credits. All per-call numbers are estimates.

## 6. Cost-reduction analysis (19 Nov, no code built)
The user's goal is fewer tokens in Salesforce. Evaluated: **taxonomy**, **OCR/text-first**, **MuleSoft IDP**, for the three templates.
- **Chosen direction for the manager deck:** OCR/text extraction for resume parsing (send text instead of the PDF; 1 block instead of 2 to 3; also reads scanned resumes; about $50 to $450 a month); a **third-party skills service** (ESCO free, O*NET free with attribution, Lightcast paid by quote) instead of asking the AI for synonyms on job extraction; **Apex rule-based scoring** (Skills 45% and Experience years rules in Apex, AI only to explain the top few) for scoring. MuleSoft IDP is shown once as "considered, not used" (runs on AI models itself, no ready resume template, per-page unpublished price, another platform).
- The biggest saving is in **scoring**, not parsing (parse is once per resume; score repeats per candidate per job). Illustrative volume used: 5,000 resumes and 10,000 scores a day, monthly cost about $12 to 21k down to about $3.5k (estimates at list price).
- **Deliverables:** the manager PPT (5 slides, simplified on request) is a Claude artifact at `https://claude.ai/artifact/MTK8swHZeGY3pcrrTcEU19`; the credits explainer doc at `https://claude.ai/artifact/NpiXtsc2LQmoEPKhiWbxpf` (both private unless shared).
- **Not started:** Apex-only scoring, shorter prompts, the "stale score" fix, OCR integration, skills-service trial. The user has not approved building them. **Open question:** how well ESCO and O*NET cover senior executive skills (M&A, Board reporting, Quebec Law 25). Test before committing.

## 7. Demo script (19 Nov)
A 5 to 6 minute business-audience script was written and then shortened, parsing and scoring combined into one. It covers only what is in the org today (no taxonomy or other ideas). It exists in the transcript (assistant messages 2026-11-19 13:05 to 13:11); it was not saved to a file.

## 8. Open items (nothing below is built)
1. **Compound-skill matching** (`docs/compound-skill-matching-fix-plan.md`, drafted 19 Nov). The user said on 19 Nov: the demo fix is fine, but for real cases it must be fixed properly; remind tomorrow and prepare a plan. The plan exists and a one-time reminder was scheduled for 2026-11-20 09:07 (only runs while the app is open; whether it ran is **unknown**). What happened: job "Due diligence" did not match a resume skill "Mergers and Acquisitions Due Diligence" (2 of 5 words = 40% under the 60% rule), hiding two good CFO candidates (Kevin Campbell, Grace Gagnon). **Demo-only workaround already in the org:** manual aliases on the CFO job's `Skill_Map__c`; it is lost if the CFO job is re-extracted. Plan's recommendation: step 1 a recall report listing candidates the matcher excluded although the resume contains every required skill; step 2 fix the cause (skills service as target, parser listing compound parts as the interim). Five options are compared in the doc.
   **Decisions the user still has to make:** (a) is a connector-word rule ("and", "/", "&") acceptable in matching code, or must it stay vocabulary-free (note: earlier the user rejected word lists); (b) which skills service to trial; (c) budget for re-parsing resumes if the parser-parts option is chosen.
2. **CPA wording:** stored as "Certified Public Accountant" (US) while the Canadian meaning is "Chartered Professional Accountant"; the CFO job map lists both; fix in the same pass as item 1.
3. **French resumes untested:** the parser may store French skill names ("gestion de projet") and the matcher would silently exclude them. Test before making skill filtering strict. Accents are also not supported by the demo PDF writer.
4. Org currency symbol reads as org currency; set org currency to CAD if the symbol should show CAD.
5. Not done at all, from the original filter advice: province/metro mapping, work authorization, language fields, employment type, security clearance, designations, audit trail of filters used, "AI used to screen" checkbox (Ontario/Quebec disclosure rules). Say if any should be built.
6. Cost plan items in section 6.
7. Real-data roll-out (beyond the demo) of everything: re-run extraction (`new JobRequirementsBatch(3650)`) and re-parse resumes so `Canonical_Key__c` and `Skill_Map__c` exist on all rows.

## 9. Things that went wrong before (so they are not repeated)
- Hardcoded variant lists in matching code were rejected (see 4.4).
- Role-type picklist changes were rejected; a restricted picklist also broke older tests.
- Mockups with numbers contradicting a "no candidates match" message were rejected twice (see 4.2).
- `limit` is a reserved word in Apex (first loader deploy failed).
- `addBulk(100)` hit the CPU limit; do not raise `CHUNK_SIZE` above 25 without measuring.
- Multi-chunk batches cannot run inside an Apex test (the loader uses a larger scope in tests only).
- Developer Console "Execute Anonymous" fails with HTTP 431 for long scripts (the URL carries the code); run long scripts with `sf apex run -f`.
- A deploy of the whole templates folder can deactivate active prompt template versions (see 4.8).
- Counting uses `Canonical_Key__c`; do not rely on aliases alone since AI alias lists vary between runs.
