/**
 * Backs the candidateMatcherV2 Lightning Web Component.
 * It only ADDS what the redesigned screen needs; the existing CandidateMatcherController is untouched and is still used for
 * the filter options, the job defaults and for starting the scoring.
 *   - getJobSkills: the required and good-to-have skills of a job (read from the fields the requirements batch fills)
 *   - countMatches: the live "N candidates match" number while the user changes filters (before scoring starts), and for every
 *                   skill and date window how many candidates there would be if it were added
 *   - getResults:   result rows with experience years, the matched / missing skills as lists and the resume file id
 */
public with sharing class CandidateMatcherV2Controller {
    @TestVisible private static final Integer MAX_REQUIRED = 12;   // skills shown as "Required by the job"
    @TestVisible private static final Integer MAX_NICE = 8;        // skills shown as "Good to have"
    /** The date windows of the screen, in days from today: Immediately, within 2 weeks, 1 month, 2 months. */
    @TestVisible private static final List<Integer> DATE_WINDOWS = new List<Integer>{ 0, 14, 31, 62 };

    public class SkillCount {
        @AuraEnabled public String name;
        @AuraEnabled public Boolean selected = false;
        @AuraEnabled public Integer count = 0;          // not selected: candidates left if it were added. Selected: left if it were removed
    }

    public class DateCount {
        @AuraEnabled public Integer days;
        @AuraEnabled public Integer count = 0;          // candidates with the selected skills who are available within that many days
    }

    public class MatchCount {
        @AuraEnabled public Integer matched = 0;        // match every filter, skills and date included. null: cannot be counted (see tooBroad)
        @AuraEnabled public Integer pool = 0;           // fit the work mode, city, salary and role filters, before skills and date
        @AuraEnabled public Integer skillMatched;       // have every selected skill, before the date filter (only when facets is true)
        @AuraEnabled public Integer notParsed = 0;      // match the filters but their resume is not parsed yet (or needs review)
        @AuraEnabled public Boolean capped = false;     // more than MAX_CANDIDATES match: only the first ones would be scored
        @AuraEnabled public Integer cap = CandidateMatchOrchestrator.MAX_CANDIDATES;
        @AuraEnabled public Boolean facets = false;     // skills and dates below are filled in
        @AuraEnabled public Boolean tooBroad = false;   // more candidates fit the other filters than their skills can be checked for
        @AuraEnabled public List<SkillCount> skills = new List<SkillCount>();
        @AuraEnabled public List<DateCount> dates = new List<DateCount>();
    }

    public class JobSkills {
        @AuraEnabled public List<String> required = new List<String>();
        @AuraEnabled public List<String> niceToHave = new List<String>();
    }

    public class Row {
        @AuraEnabled public Id contactId;
        @AuraEnabled public String name;
        @AuraEnabled public String nameUrl;
        @AuraEnabled public String city;
        @AuraEnabled public Decimal salary;
        @AuraEnabled public Decimal experienceYears;
        @AuraEnabled public Decimal score;
        @AuraEnabled public Decimal skillsScore;
        @AuraEnabled public Decimal experienceScore;
        @AuraEnabled public Decimal educationScore;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean needsReview = false;
        @AuraEnabled public List<String> matched = new List<String>();
        @AuraEnabled public List<String> missing = new List<String>();
        @AuraEnabled public String reasoning;
        @AuraEnabled public Id resumeDocId;             // latest PDF of the contact, opened with the file preview
    }

    public class Results {
        @AuraEnabled public List<Row> rows = new List<Row>();
        @AuraEnabled public Integer total = 0;
        @AuraEnabled public Integer scored = 0;
        @AuraEnabled public Integer failed = 0;
        @AuraEnabled public Integer inProgress = 0;
        @AuraEnabled public Boolean done = true;
    }

    private static final Set<String> IN_PROGRESS = new Set<String>{ 'Queued for scoring', 'Scoring' };

    /**
     * The skills of a job for the "Skills" filter. Required first, then good to have. A skill is listed once even if the AI wrote
     * it in both lists, and the lists are cut to what fits the panel.
     */
    @AuraEnabled
    public static JobSkills getJobSkills(Id jobId) {
        try {
            Job__c job = [SELECT Required_Skills__c, Nice_To_Have_Skills__c FROM Job__c WHERE Id = :jobId WITH USER_MODE];
            JobSkills r = new JobSkills();
            Set<String> used = new Set<String>();
            r.required = distinctSkills(job.Required_Skills__c, MAX_REQUIRED, used);
            r.niceToHave = distinctSkills(job.Nice_To_Have_Skills__c, MAX_NICE, used);
            return r;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /** "Apex, apex , Flow" -> ['Apex', 'Flow'] (at most max, skipping keys already in used). */
    @TestVisible
    private static List<String> distinctSkills(String csv, Integer max, Set<String> used) {
        List<String> out = new List<String>();
        for (String s : splitSkills(csv)) {
            String key = ResumeParserService.normalizeKey(s).left(80);
            if (String.isBlank(key) || !used.add(key)) { continue; }
            out.add(s);
            if (out.size() >= max) { break; }
        }
        return out;
    }

    /**
     * How many candidates match the filters right now. Same filters and same search as "Apply filters".
     * When the screen sends its skill list (skillOptions) and the work mode, city, salary and role filters leave a manageable
     * number of candidates, the answer also says, for every skill and date window, how many would be left if it were added.
     */
    @AuraEnabled
    public static MatchCount countMatches(String filtersJson) {
        try {
            CandidateMatchOrchestrator.Filters f = String.isBlank(filtersJson)
                ? new CandidateMatchOrchestrator.Filters()
                : (CandidateMatchOrchestrator.Filters) JSON.deserialize(filtersJson, CandidateMatchOrchestrator.Filters.class);
            MatchCount r = new MatchCount();
            r.notParsed = CandidateMatchOrchestrator.countNotParsed(f);
            r.pool = CandidateMatchOrchestrator.countPool(f);

            List<String> selected = CandidateMatchOrchestrator.skillKeys(f.skills);
            List<String> options = CandidateMatchOrchestrator.skillKeys(f.skillOptions);
            List<String> keys = new List<String>(selected);
            for (String k : options) { if (!keys.contains(k)) { keys.add(k); } }

            if (keys.isEmpty()) {
                r.matched = CandidateMatchOrchestrator.countMatchingWithoutSkills(f);
            } else if (r.pool <= CandidateMatchOrchestrator.skillPoolLimit(keys.size())) {
                countWithFacets(f, selected, options, keys, r);
            } else {
                r.tooBroad = true;
                r.matched = selected.isEmpty() ? CandidateMatchOrchestrator.countMatchingWithoutSkills(f) : null;
            }
            r.capped = r.matched != null && r.matched > r.cap;
            return r;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /** Looks at every candidate of the pool once and fills in the counts of the whole screen. */
    private static void countWithFacets(CandidateMatchOrchestrator.Filters f, List<String> selected, List<String> options,
                                        List<String> keys, MatchCount r) {
        Set<String> chosen = new Set<String>(selected);
        Date today = Date.today();
        Date deadline = CandidateMatchOrchestrator.availableBy(f);
        Map<String, Integer> ifAdded = new Map<String, Integer>();     // option key -> candidates left if it were added
        Map<String, Integer> ifRemoved = new Map<String, Integer>();   // option key -> extra candidates let in if it were removed
        for (String k : options) { ifAdded.put(k, 0); ifRemoved.put(k, 0); }
        List<Integer> inWindow = new List<Integer>();
        for (Integer w : DATE_WINDOWS) { inWindow.add(0); }
        Integer matched = 0;
        Integer skillMatched = 0;

        for (CandidateMatchOrchestrator.PoolEntry e : CandidateMatchOrchestrator.readPool(f, keys)) {
            Integer missing = 0;
            String missingKey = null;
            for (String k : selected) {
                if (!e.skills.contains(k)) { missing++; missingKey = k; }
            }
            Boolean dateOk = CandidateMatchOrchestrator.availableOk(e.available, deadline);
            if (missing == 0) {
                skillMatched++;
                if (dateOk) {
                    matched++;
                    for (String k : options) {
                        if (!chosen.contains(k) && e.skills.contains(k)) { ifAdded.put(k, ifAdded.get(k) + 1); }
                    }
                }
                if (e.available != null) {
                    for (Integer i = 0; i < DATE_WINDOWS.size(); i++) {
                        if (e.available <= today.addDays(DATE_WINDOWS[i])) { inWindow[i] = inWindow[i] + 1; }
                    }
                }
            } else if (missing == 1 && dateOk && ifRemoved.containsKey(missingKey)) {
                // this candidate lacks exactly one selected skill: removing that skill would let the candidate in
                ifRemoved.put(missingKey, ifRemoved.get(missingKey) + 1);
            }
        }

        r.facets = true;
        r.matched = matched;
        r.skillMatched = skillMatched;
        Map<String, String> nameByKey = new Map<String, String>();
        if (f.skillOptions != null) {
            for (String n : f.skillOptions) {
                String k = ResumeParserService.normalizeKey(n).left(80);
                if (!nameByKey.containsKey(k)) { nameByKey.put(k, n); }
            }
        }
        for (String k : options) {
            SkillCount sc = new SkillCount();
            sc.name = nameByKey.get(k);
            sc.selected = chosen.contains(k);
            sc.count = sc.selected ? matched + ifRemoved.get(k) : ifAdded.get(k);
            r.skills.add(sc);
        }
        for (Integer i = 0; i < DATE_WINDOWS.size(); i++) {
            DateCount dc = new DateCount();
            dc.days = DATE_WINDOWS[i];
            dc.count = inWindow[i];
            r.dates.add(dc);
        }
    }

    /** Polled by the screen every few seconds. Best score first. */
    @AuraEnabled
    public static Results getResults(String runKey) {
        Results res = new Results();
        if (String.isBlank(runKey)) { return res; }
        try {
            List<Candidate_Match__c> matches = [
                SELECT Contact__c, Contact__r.Name, Contact__r.City__c, Contact__r.Expected_Salary__c,
                       Contact__r.Total_Experience_Years__c, Score__c, Skills_Score__c, Experience_Score__c,
                       Education_Score__c, Status__c, Needs_Review__c, Matched_Skills__c, Missing_Skills__c, Reasoning__c
                FROM Candidate_Match__c
                WHERE Run_Key__c = :runKey
                WITH USER_MODE
                ORDER BY Score__c DESC NULLS LAST, Skills_Score__c DESC NULLS LAST, Experience_Score__c DESC NULLS LAST, Contact__r.Name
                LIMIT 500
            ];
            List<Id> contactIds = new List<Id>();
            for (Candidate_Match__c m : matches) { contactIds.add(m.Contact__c); }
            Map<Id, Id> resumeByContact = ResumeParserService.findResumeFiles(contactIds);

            for (Candidate_Match__c m : matches) {
                Row r = new Row();
                r.contactId = m.Contact__c;
                r.name = m.Contact__r.Name;
                r.nameUrl = '/lightning/r/Contact/' + m.Contact__c + '/view';
                r.city = m.Contact__r.City__c;
                r.salary = m.Contact__r.Expected_Salary__c;
                r.experienceYears = m.Contact__r.Total_Experience_Years__c;
                r.score = m.Score__c;
                r.skillsScore = m.Skills_Score__c;
                r.experienceScore = m.Experience_Score__c;
                r.educationScore = m.Education_Score__c;
                r.status = m.Status__c;
                r.needsReview = m.Needs_Review__c == true;
                r.matched = splitSkills(m.Matched_Skills__c);
                r.missing = splitSkills(m.Missing_Skills__c);
                r.reasoning = m.Reasoning__c;
                r.resumeDocId = resumeByContact.get(m.Contact__c);
                res.rows.add(r);
                res.total++;
                if (m.Status__c == 'Scored') { res.scored++; }
                if (m.Status__c != null && m.Status__c.startsWith('Failed')) { res.failed++; }
                if (IN_PROGRESS.contains(m.Status__c)) { res.inProgress++; }
            }
            res.done = res.inProgress == 0;
            return res;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /** "Apex, SOQL ,Flow" -> ['Apex', 'SOQL', 'Flow'] */
    @TestVisible
    private static List<String> splitSkills(String csv) {
        List<String> out = new List<String>();
        if (String.isBlank(csv)) { return out; }
        for (String s : csv.split(',')) {
            if (String.isNotBlank(s)) { out.add(s.trim()); }
        }
        return out;
    }
}
