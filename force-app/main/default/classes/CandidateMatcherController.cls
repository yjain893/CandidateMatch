/** Backs the candidateMatcher Lightning Web Component. */
public with sharing class CandidateMatcherController {
    public class Option {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        public Option(String l, String v) { label = l; value = v; }
    }
    public class Row {
        @AuraEnabled public Id contactId;
        @AuraEnabled public String name;
        @AuraEnabled public String nameUrl;
        @AuraEnabled public String city;
        @AuraEnabled public Decimal salary;
        @AuraEnabled public Decimal score;
        @AuraEnabled public Decimal skillsScore;
        @AuraEnabled public Decimal experienceScore;
        @AuraEnabled public Decimal fitScore;
        @AuraEnabled public Decimal educationScore;
        @AuraEnabled public String status;
        @AuraEnabled public String matched;
        @AuraEnabled public String missing;
        @AuraEnabled public String reasoning;
    }
    public class Results {
        @AuraEnabled public List<Row> rows = new List<Row>();
        @AuraEnabled public Integer total = 0;
        @AuraEnabled public Integer scored = 0;
        @AuraEnabled public Integer inProgress = 0;
        @AuraEnabled public Boolean done = true;
    }

    private static final Set<String> IN_PROGRESS = new Set<String>{ 'Queued for scoring', 'Scoring' };

    /** Picklist options for the filter controls. */
    @AuraEnabled(cacheable=true)
    public static Map<String, List<Option>> getOptions() {
        Map<String, List<Option>> out = new Map<String, List<Option>>();
        out.put('workModes', options('Work_Modes__c'));
        out.put('roleTypes', options('Role_Types__c'));
        return out;
    }

    private static List<Option> options(String fieldApi) {
        List<Option> out = new List<Option>();
        Schema.DescribeFieldResult d = Contact.SObjectType.getDescribe().fields.getMap().get(fieldApi).getDescribe();
        for (Schema.PicklistEntry e : d.getPicklistValues()) { if (e.isActive()) { out.add(new Option(e.getLabel(), e.getValue())); } }
        return out;
    }

    /** Values on the job record that pre-fill the filters. */
    @AuraEnabled
    public static Map<String, Object> getJobFilters(Id jobId) {
        Job__c job = [SELECT Name, Work_Modes__c, City__c, Expected_Salary__c, Role_Types__c FROM Job__c WHERE Id = :jobId WITH USER_MODE];
        CandidateMatchOrchestrator.Filters f = CandidateMatchOrchestrator.fromJob(job);
        return new Map<String, Object>{
            'jobName' => job.Name, 'workModes' => f.workModes, 'city' => f.cities,
            'maxSalary' => f.maxSalary, 'roleTypes' => f.roleTypes };
    }

    /** "Apply filters": find candidates with a parsed resume that match the filters, then score them in the background. */
    @AuraEnabled
    public static Map<String, Object> startMatching(Id jobId, String filtersJson) {
        try {
            CandidateMatchOrchestrator.Filters f = String.isBlank(filtersJson)
                ? new CandidateMatchOrchestrator.Filters()
                : (CandidateMatchOrchestrator.Filters) JSON.deserialize(filtersJson, CandidateMatchOrchestrator.Filters.class);
            CandidateMatchOrchestrator.StartResult r = CandidateMatchOrchestrator.start(jobId, f);
            return new Map<String, Object>{
                'runKey' => r.runKey, 'matched' => r.matched, 'toScore' => r.toScore,
                'cached' => r.cached, 'notParsed' => r.notParsed, 'capped' => r.capped,
                'cap' => CandidateMatchOrchestrator.MAX_CANDIDATES };
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /** Polled by the screen every few seconds. Sorted best score first. */
    @AuraEnabled
    public static Results getResults(String runKey) {
        Results res = new Results();
        if (String.isBlank(runKey)) { return res; }
        for (Candidate_Match__c m : [
            SELECT Contact__c, Contact__r.Name, Contact__r.City__c, Contact__r.Expected_Salary__c, Score__c, Skills_Score__c,
                   Experience_Score__c, Fit_Score__c, Education_Score__c, Status__c, Needs_Review__c,
                   Matched_Skills__c, Missing_Skills__c, Reasoning__c
            FROM Candidate_Match__c
            WHERE Run_Key__c = :runKey
            WITH USER_MODE
            ORDER BY Score__c DESC NULLS LAST, Contact__r.Name
            LIMIT 500
        ]) {
            Row r = new Row();
            r.contactId = m.Contact__c;
            r.name = m.Contact__r.Name;
            r.nameUrl = '/lightning/r/Contact/' + m.Contact__c + '/view';
            r.city = m.Contact__r.City__c;
            r.salary = m.Contact__r.Expected_Salary__c;
            r.score = m.Score__c;
            r.skillsScore = m.Skills_Score__c;
            r.experienceScore = m.Experience_Score__c;
            r.fitScore = m.Fit_Score__c;
            r.educationScore = m.Education_Score__c;
            r.status = (m.Status__c == 'Scored' && m.Needs_Review__c) ? 'Scored (please check)' : m.Status__c;
            r.matched = m.Matched_Skills__c;
            r.missing = m.Missing_Skills__c;
            r.reasoning = m.Reasoning__c;
            res.rows.add(r);
            res.total++;
            if (m.Status__c == 'Scored') { res.scored++; }
            if (IN_PROGRESS.contains(m.Status__c)) { res.inProgress++; }
        }
        res.done = res.inProgress == 0;
        return res;
    }
}
