/**
 * Scores the candidates chosen by the UI filters against a job. One AiJobRun, one AiJobRunItem per candidate.
 * The AI returns four component scores; Apex combines them with fixed weights and verifies the AI's skill claims.
 */
public with sharing class CandidateMatchService {
    public static final String TEMPLATE = 'Score_Candidate_For_Job';

    /**
     * Processing mode.
     *  false (default): Salesforce background jobs (DirectParseBatch / DirectScoreBatch) call the prompts directly, a few candidates at a time.
     *  true: resumes and scores are sent as AiJobRun batch jobs (needs a model/org where AiJobRun items work).
     */
    @TestVisible private static Boolean useAiJobRun = false;
    public static Boolean usesAiJobRun() { return useAiJobRun; }

    // Final score weights (percent). Edit here to change what "good match" means.
    public static final Decimal W_SKILLS = 45;
    public static final Decimal W_EXPERIENCE = 25;
    public static final Decimal W_FIT = 20;        // city, work mode, role type, salary
    public static final Decimal W_EDUCATION = 10;

    public static final String CONTACT_FIELDS =
        'Id, Candidate_Profile__c, City__c, Work_Modes__c, Role_Types__c, Expected_Salary__c, Total_Experience_Years__c';
    public static final String JOB_FIELDS =
        'Id, Job_Description__c, Required_Skills__c, Nice_To_Have_Skills__c, City__c, Work_Modes__c, Role_Types__c, '
        + 'Expected_Salary__c, Min_Experience_Years__c, LastModifiedDate';

    public class ScoreResult {
        public Decimal skillsScore;
        public Decimal experienceScore;
        public Decimal fitScore;
        public Decimal educationScore;
        public List<String> matchedSkills;
        public List<String> missingSkills;
        public String fitNote;
        public String reasoning;
    }

    /** The fit part only applies when the job specifies at least one of city, work mode, role type or salary. */
    public static Boolean useFit(Job__c job) {
        return String.isNotBlank(job.City__c) || String.isNotBlank(job.Work_Modes__c)
            || String.isNotBlank(job.Role_Types__c) || job.Expected_Salary__c != null;
    }

    public static String jobText(Job__c job) {
        List<String> parts = new List<String>{ JobRequirementsService.plain(job.Job_Description__c) };
        if (String.isNotBlank(job.City__c)) { parts.add('CITY: ' + job.City__c); }
        if (String.isNotBlank(job.Work_Modes__c)) { parts.add('WORK MODES: ' + job.Work_Modes__c.replace(';', ', ')); }
        if (String.isNotBlank(job.Role_Types__c)) { parts.add('ROLE TYPES: ' + job.Role_Types__c.replace(';', ', ')); }
        if (job.Expected_Salary__c != null) { parts.add('SALARY OFFERED: ' + job.Expected_Salary__c); }
        if (job.Min_Experience_Years__c != null) { parts.add('MINIMUM EXPERIENCE (years): ' + job.Min_Experience_Years__c); }
        if (String.isNotBlank(job.Required_Skills__c)) { parts.add('REQUIRED SKILLS: ' + job.Required_Skills__c); }
        if (String.isNotBlank(job.Nice_To_Have_Skills__c)) { parts.add('NICE TO HAVE: ' + job.Nice_To_Have_Skills__c); }
        return String.join(parts, '\n').left(8000);
    }

    /** Resume profile plus live contact facts (read at scoring time, so never stale). */
    public static String candidateText(Contact c) {
        return (nz(c.Candidate_Profile__c)
            + '\nCity: ' + (String.isBlank(c.City__c) ? 'unknown' : c.City__c)
            + '\nWork modes: ' + (String.isBlank(c.Work_Modes__c) ? 'unknown' : c.Work_Modes__c.replace(';', ', '))
            + '\nRole types: ' + (String.isBlank(c.Role_Types__c) ? 'unknown' : c.Role_Types__c.replace(';', ', '))
            + '\nExpected salary: ' + (c.Expected_Salary__c == null ? 'unknown' : String.valueOf(c.Expected_Salary__c))
            + '\nTotal experience (years, approximate): ' + (c.Total_Experience_Years__c == null ? 'unknown' : String.valueOf(c.Total_Experience_Years__c))
        ).left(8000);
    }

    /** Submits ONE AiJobRun for these contacts (all must have a parsed profile). No callouts. Returns how many were submitted. */
    public static Integer submitScoring(Id jobId, List<Id> contactIds) {
        if (contactIds.isEmpty()) { return 0; }
        Set<Id> inFlight = new Set<Id>();
        for (AI_Item_Map__c m : [
            SELECT Contact__c FROM AI_Item_Map__c
            WHERE Kind__c = 'MATCH' AND Job__c = :jobId AND Processed__c = false AND Contact__c IN :contactIds
        ]) { inFlight.add(m.Contact__c); }

        Job__c job = Database.query('SELECT ' + JOB_FIELDS + ' FROM Job__c WHERE Id = :jobId');
        String jd = jobText(job);
        List<Map<String, Object>> payloads = new List<Map<String, Object>>();
        List<Id> submitted = new List<Id>();
        for (Contact c : Database.query('SELECT ' + CONTACT_FIELDS + ' FROM Contact WHERE Id IN :contactIds')) {
            if (inFlight.contains(c.Id) || String.isBlank(c.Candidate_Profile__c)) { continue; }
            payloads.add(new Map<String, Object>{ 'Input:Job_Description' => jd, 'Input:Candidate_Profile' => candidateText(c) });
            submitted.add(c.Id);
        }
        if (payloads.isEmpty()) { return 0; }

        AiJobGateway.RunInfo info = AiJobGateway.start(TEMPLATE, payloads);
        List<AI_Item_Map__c> maps = new List<AI_Item_Map__c>();
        for (Integer i = 0; i < submitted.size(); i++) {
            maps.add(new AI_Item_Map__c(Item_Id__c = info.itemIds[i], Run_Id__c = info.runId,
                Kind__c = 'MATCH', Contact__c = submitted[i], Job__c = jobId, Processed__c = false));
        }
        insert maps;

        List<Candidate_Match__c> rows = [SELECT Id FROM Candidate_Match__c WHERE Job__c = :jobId AND Contact__c IN :submitted];
        for (Candidate_Match__c r : rows) { r.Status__c = 'Scoring'; }
        update rows;
        return submitted.size();
    }

    /** AiJobRun mode: called after resume results are saved. */
    public static void onResumesParsed(List<Id> contactIds) {
        afterParse(contactIds, true);
    }

    /**
     * Candidates that were waiting for their resume move on: parsed ones go to scoring
     * (submitted as an AiJobRun, or just queued for the direct score batch), others get a clear status.
     */
    public static void afterParse(List<Id> contactIds, Boolean submitJobRun) {
        List<Candidate_Match__c> waiting = [
            SELECT Id, Job__c, Contact__c FROM Candidate_Match__c
            WHERE Contact__c IN :contactIds AND Status__c = 'Reading resume'
        ];
        if (waiting.isEmpty()) { return; }
        Map<Id, Contact> contacts = new Map<Id, Contact>(
            [SELECT Id, Resume_Parse_Status__c FROM Contact WHERE Id IN :contactIds]);

        Map<Id, List<Id>> toScore = new Map<Id, List<Id>>();
        List<Candidate_Match__c> updates = new List<Candidate_Match__c>();
        for (Candidate_Match__c m : waiting) {
            Contact c = contacts.get(m.Contact__c);
            String st = c == null ? null : c.Resume_Parse_Status__c;
            if (st == 'Parsed') {
                if (submitJobRun == true) {
                    if (!toScore.containsKey(m.Job__c)) { toScore.put(m.Job__c, new List<Id>()); }
                    toScore.get(m.Job__c).add(m.Contact__c);
                } else {
                    m.Status__c = 'Queued for scoring'; updates.add(m);
                }
            } else if (st == 'Review') {
                m.Status__c = 'Needs review (resume)'; updates.add(m);
            } else {
                m.Status__c = 'Failed: resume could not be read'; updates.add(m);
            }
        }
        if (!updates.isEmpty()) { update updates; }
        for (Id jobId : toScore.keySet()) {
            try {
                submitScoring(jobId, toScore.get(jobId));
            } catch (Exception e) {
                List<Id> cids = toScore.get(jobId);
                List<Candidate_Match__c> failed = [SELECT Id FROM Candidate_Match__c
                    WHERE Job__c = :jobId AND Contact__c IN :cids AND Status__c = 'Reading resume'];
                for (Candidate_Match__c f : failed) { f.Status__c = 'Failed: could not start scoring'; }
                update failed;
            }
        }
    }

    /** Direct mode: score candidates with one prompt call each (callouts first, DML last). */
    public static void scoreDirect(Id jobId, List<Id> contactIds) {
        Job__c job = Database.query('SELECT ' + JOB_FIELDS + ' FROM Job__c WHERE Id = :jobId');
        String jd = jobText(job);
        Boolean fit = useFit(job);
        Map<Id, Candidate_Match__c> rows = new Map<Id, Candidate_Match__c>();
        for (Candidate_Match__c m : [
            SELECT Id, Contact__c FROM Candidate_Match__c WHERE Job__c = :jobId AND Contact__c IN :contactIds
        ]) { rows.put(m.Contact__c, m); }

        List<Candidate_Match__c> toSave = new List<Candidate_Match__c>();
        for (Contact c : Database.query('SELECT ' + CONTACT_FIELDS + ' FROM Contact WHERE Id IN :contactIds')) {
            Candidate_Match__c row = rows.get(c.Id);
            try {
                if (String.isBlank(c.Candidate_Profile__c)) { throw new PromptRunner.PromptException('No profile text'); }
                String raw = PromptRunner.run(TEMPLATE, new Map<String, Object>{
                    'Job_Description' => jd, 'Candidate_Profile' => candidateText(c) });
                ScoreResult r = (ScoreResult) JSON.deserialize(PromptRunner.clean(raw), ScoreResult.class);
                toSave.add(buildMatch(jobId, c.Id, r, c.Candidate_Profile__c, row, fit));
            } catch (Exception e) {
                if (row != null) { row.Status__c = 'Failed: AI scoring'; toSave.add(row); }
            }
        }
        if (!toSave.isEmpty()) { upsert toSave; }
    }

    /**
     * Final score = weighted average of the AI's component scores (fit left out when the job specifies none).
     * Accuracy guard: a matched skill must literally appear in the candidate profile, otherwise it is removed and the row is
     * flagged. A final score of 70+ with no verifiable matched skill is capped at 50 and flagged.
     */
    public static Candidate_Match__c buildMatch(Id jobId, Id contactId, ScoreResult r, String profile,
                                                Candidate_Match__c existing, Boolean useFit) {
        Candidate_Match__c m = existing != null ? existing : new Candidate_Match__c(Job__c = jobId, Contact__c = contactId);
        String hay = ' ' + ResumeParserService.normalizeKey(profile) + ' ';
        List<String> verified = new List<String>();
        List<String> dropped = new List<String>();
        if (r.matchedSkills != null) {
            for (String s : r.matchedSkills) {
                String k = ResumeParserService.normalizeKey(s);
                if (String.isBlank(k)) { continue; }
                if (hay.contains(' ' + k + ' ')) { verified.add(s); } else { dropped.add(s); }
            }
        }
        Decimal sk = clamp(r.skillsScore);
        Decimal ex = clamp(r.experienceScore);
        Decimal fi = clamp(r.fitScore);
        Decimal ed = clamp(r.educationScore);
        Decimal total = useFit == true
            ? (sk * W_SKILLS + ex * W_EXPERIENCE + fi * W_FIT + ed * W_EDUCATION) / (W_SKILLS + W_EXPERIENCE + W_FIT + W_EDUCATION)
            : (sk * W_SKILLS + ex * W_EXPERIENCE + ed * W_EDUCATION) / (W_SKILLS + W_EXPERIENCE + W_EDUCATION);

        Boolean review = String.isBlank(r.reasoning);
        String reasoning = r.reasoning == null ? '' : r.reasoning;
        if (useFit == true && String.isNotBlank(r.fitNote)) { reasoning += ' Fit: ' + r.fitNote; }
        if (!dropped.isEmpty()) {
            review = true;
            reasoning += ' [Unverified skills removed: ' + String.join(dropped, ', ') + ']';
        }
        if (total >= 70 && verified.isEmpty()) {
            review = true;
            total = 50;
            reasoning += ' [Score capped: no matched skill could be verified]';
        }
        m.Score__c = total.round();
        m.Skills_Score__c = sk.round();
        m.Experience_Score__c = ex.round();
        m.Fit_Score__c = useFit == true ? fi.round() : null;
        m.Education_Score__c = ed.round();
        m.Reasoning__c = reasoning.left(5000);
        m.Matched_Skills__c = String.join(verified, ', ').left(2000);
        m.Missing_Skills__c = r.missingSkills == null ? null : String.join(r.missingSkills, ', ').left(2000);
        m.Needs_Review__c = review;
        m.Status__c = 'Scored';
        m.Scored_On__c = System.now();
        return m;
    }

    /** Best scored matches for a job (used by the agent action). */
    public static List<Candidate_Match__c> getRanked(Id jobId, Integer topN) {
        Integer lim = (topN == null || topN < 1) ? 10 : Math.min(topN, 50);
        return [
            SELECT Contact__c, Contact__r.Name, Score__c, Skills_Score__c, Experience_Score__c, Fit_Score__c,
                   Education_Score__c, Reasoning__c, Matched_Skills__c, Missing_Skills__c, Needs_Review__c
            FROM Candidate_Match__c
            WHERE Job__c = :jobId AND Status__c = 'Scored'
            ORDER BY Score__c DESC
            LIMIT :lim
        ];
    }

    private static Decimal clamp(Decimal v) {
        Decimal hi = 100; Decimal lo = 0;
        if (v == null) { return lo; }
        return Math.max(lo, Math.min(hi, v));
    }
    private static String nz(String s) { return s == null ? '' : s; }
}