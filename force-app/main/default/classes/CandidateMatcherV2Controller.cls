/**
 * Backs the candidateMatcherV2 Lightning Web Component.
 * It only ADDS what the redesigned screen needs; the existing CandidateMatcherController is untouched and is still used for
 * the filter options, the job defaults and for starting the scoring.
 *   - countMatches: the live "N candidates match" number while the user changes filters (before scoring starts)
 *   - getResults:   result rows with experience years, the matched / missing skills as lists and the resume file id
 */
public with sharing class CandidateMatcherV2Controller {
    public class MatchCount {
        @AuraEnabled public Integer matched = 0;        // candidates with a parsed resume that match the filters (at most MAX_CANDIDATES)
        @AuraEnabled public Integer notParsed = 0;      // match the filters but their resume is not parsed yet (or needs review)
        @AuraEnabled public Boolean capped = false;     // more than MAX_CANDIDATES match: only the first ones would be scored
        @AuraEnabled public Integer cap = CandidateMatchOrchestrator.MAX_CANDIDATES;
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

    /** How many candidates match the filters right now. Same filters and same search as "Apply filters". */
    @AuraEnabled
    public static MatchCount countMatches(String filtersJson) {
        try {
            CandidateMatchOrchestrator.Filters f = String.isBlank(filtersJson)
                ? new CandidateMatchOrchestrator.Filters()
                : (CandidateMatchOrchestrator.Filters) JSON.deserialize(filtersJson, CandidateMatchOrchestrator.Filters.class);
            Integer cap = CandidateMatchOrchestrator.MAX_CANDIDATES;
            List<Contact> found = CandidateMatchOrchestrator.findCandidates(f, cap);
            MatchCount r = new MatchCount();
            r.capped = found.size() > cap;
            r.matched = Math.min(found.size(), cap);
            r.notParsed = CandidateMatchOrchestrator.countNotParsed(f);
            return r;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
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
                ORDER BY Score__c DESC NULLS LAST, Contact__r.Name
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
