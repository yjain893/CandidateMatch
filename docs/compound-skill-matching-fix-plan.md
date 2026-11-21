# Plan: stop compound skills from silently hiding good candidates

Status: draft for discussion on 2026-11-20. Nothing in this plan has been built.
Demo workaround already in the org (2026-11-19): a manual alias on the CFO job's `Skill_Map__c`.

## 1. What went wrong in the demo

| Side | What it holds |
|---|---|
| Job description | "M&A and due diligence" |
| Job extraction (AI) | two required skills: `M&A` and `Due diligence` |
| Resume (Kevin Campbell, Grace Gagnon, and two others in other cities) | "M&A and due diligence" |
| Resume parsing (AI) | one stored skill: `Mergers and Acquisitions Due Diligence` |

The matcher (`CandidateMatchOrchestrator.readPool`) accepts a stored skill for a job skill when the names are equal, the job's alias list has it, or one name sits inside the other as whole words **and** the shorter name is at least 60% of the longer one's words (`MIN_OVERLAP_PERCENT`).

- `mergers and acquisitions` is 3 of 5 words = 60%, so `M&A` matched (through the alias `Mergers and acquisitions`).
- `due diligence` is 2 of 5 words = 40%, so `Due diligence` did not match.

Result: Kevin Campbell (22 years, CPA, CFA, ICD.D) and Grace Gagnon were left out of the CFO shortlist, and the recruiter was never told. The skill filter on the screen does show a count per skill, so a careful user can see "Due diligence" is the blocker, but nothing flags it.

The demo fix added `M&A due diligence` and `Mergers and acquisitions due diligence` as aliases of `Due diligence` on that one job. It is lost when the job is re-extracted and covers no other job or skill.

## 2. Why it will happen in real use

It is a granularity mismatch between two AI steps that run separately, so it will recur whenever a phrase joins several skills ("X and Y", "X / Y", "X & Y", a bullet listing several).

- **Direction A (this case):** the resume has one compound skill, the job has the parts.
- **Direction B (not seen in the demo, but the same rule fails):** the resume has the parts ("Stakeholder management", "Vendor management") and the job has the compound ("Stakeholder and vendor management"). `vendor management` is 2 of 4 words = 50%, so it does not match.
- The AI's wording varies between runs, so which resumes and jobs hit this is not predictable.

Risk to the client: false negatives are invisible. A recruiter sees a clean shortlist and never learns who was missed.

## 3. Options

| # | Option | Fixes A | Fixes B | Extra AI cost | Main drawback |
|---|---|---|---|---|---|
| 1 | Prompt rules: split "X and Y" into separate skills in both `Parse_Resume` and `Extract_Job_Requirements` | Mostly | Mostly | none per call, but existing resumes must be re-parsed and jobs re-extracted | Not deterministic; the model can still join or split differently |
| 2 | Parser also returns the parts of any compound skill (new field, for example `Skill__c.Component_Keys__c`); the matcher credits the parts | Yes | Partly | a few output tokens per resume; re-parse needed | Depends on the AI listing the parts correctly |
| 3 | Matcher splits names on connector words ("and", "/", "&") | Yes | Yes | none | Language-specific ("et" in French); conflicts with the earlier rule of no vocabulary lists in matching code |
| 4 | Lower the 60% overlap rule (for example to 40%) | Yes | Partly | none | False positives: "Platform Developer" would match "Salesforce Platform Developer Certification" again |
| 5 | Skills service with broader/narrower relations (ESCO, or Lightcast by quote): every skill becomes a canonical id, and a narrower skill satisfies a broader one | Yes | Yes | none (also removes AI synonyms, see deck slide 3) | Needs coverage testing on executive skills; a service dependency |

## 4. Recommendation

Do it in two steps, so the client is protected before the larger change lands.

**Step 1 – see the misses (small).**
Build a recall check that runs after parsing and job extraction. For each job it lists candidates whose resume text contains every required skill (or alias) but who the matcher excluded, with the skill that blocked them. This is the same independent check used on 2026-11-19 (resume text versus the matcher's selection). It turns silent misses into a report, and it becomes the regression test for everything below.

**Step 2 – fix the cause (medium).**
Option 5 as the target, because it fixes both directions without more AI use and is already the direction of the cost plan. Until a skills service is chosen, option 2 is the interim that stays inside the current design. Keep option 4 off the table unless the recall check shows it does not add false positives.

## 5. Work items

1. Recall check: an Apex batch or script in `scripts/apex/` that produces the near-miss list per job. Acceptance: on the demo org it reports the CFO case when the manual alias is removed, and nothing else.
2. Golden test set from the demo org: the six jobs with these expected selections: CTO 5, CFO 5, CISO 5, CRO 5, VP Operations 5, CDO 5 candidates (names recorded on 2026-11-19).
3. New tests in `SkillAliasMatchingTest` for both directions (compound resume with split job, split resume with compound job), plus the existing false-positive cases that must stay unmatched.
4. Prototype the chosen option on a copy of the data; compare against the golden set and the recall check.
5. Coverage test for the skills service on the demo executive skills (M&A, Due diligence, Board reporting, Quebec Law 25, and so on) before any commitment.
6. Roll-out: remove the manual CFO alias and confirm the CFO job still returns 5; re-parse or re-extract only if the chosen option needs it, and say how many AI calls that costs first.

## 6. Decisions needed from you

- Is a connector-word rule acceptable in matching code (option 3), or must it stay vocabulary-free?
- Which skills service to trial (ESCO free, O\*NET free, Lightcast paid by quote)?
- Budget for re-parsing existing resumes if option 2 is chosen (one block per resume at list price, about $0.02 each on the cost slide's assumptions).

## 7. Related facts to keep in mind

- Re-extracting a job rewrites its skill map, so any hand-added alias is lost.
- Any edit to a job makes its saved scores stale (`Scored_On__c >= job.LastModifiedDate` check), so the next Apply filters re-scores live.
- The CPA skill is stored as "Certified Public Accountant" (US meaning); in Canada it is "Chartered Professional Accountant". The CFO job's skill map lists both, but the candidate's skill list shows the US wording. Worth fixing in the same pass.
