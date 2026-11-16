/**
 * "Apply filters" logic. Resumes are parsed BEFORE this screen is used (ResumeParseBatch / ResumeParseScheduler).
 *  1. AI reads the job description (once, hash-cached).
 *  2. Candidates = contacts that have a resume, whose resume is already PARSED (Skill / Education / Employment records exist),
 *     and whose fields match the filters chosen on the screen (not the job record).
 *  3. Only scoring happens here: one Candidate_Match__c row per candidate, scored in the background.
 *  4. Progress and results live in Candidate_Match__c rows tagged with a run key; the screen polls them.
 */
public with sharing class CandidateMatchOrchestrator {
    public static final Integer MAX_CANDIDATES = 200;

    public class Filters {
        public List<String> workModes;   // matches candidates having ANY of these
        public String cities;            // comma separated, exact (case-insensitive) match on City__c
        public Decimal maxSalary;        // candidate expected salary must be <= this (blank salaries are excluded)
        public List<String> roleTypes;   // matches candidates having ANY of these
    }
    public class StartResult {
        public String runKey;
        public Integer matched = 0;      // candidates shown (parsed resume + filters)
        public Integer toScore = 0;      // of those, how many are being scored now
        public Integer cached = 0;       // of those, how many reused an up-to-date score
        public Integer notParsed = 0;    // match the filters but their resume is not parsed yet / needs review
        public Boolean capped = false;
    }

    public static Filters fromJob(Job__c job) {
        Filters f = new Filters();
        f.workModes = splitMulti(job.Work_Modes__c);
        f.roleTypes = splitMulti(job.Role_Types__c);
        f.cities = job.City__c;
        f.maxSalary = job.Expected_Salary__c;
        return f;
    }

    public static List<String> splitMulti(String s) {
        List<String> out = new List<String>();
        if (String.isBlank(s)) { return out; }
        for (String p : s.split(';')) { if (String.isNotBlank(p)) { out.add(p.trim()); } }
        return out;
    }

    public static List<String> picklistValues(String fieldApi) {
        List<String> out = new List<String>();
        Schema.DescribeFieldResult d = Contact.SObjectType.getDescribe().fields.getMap().get(fieldApi).getDescribe();
        for (Schema.PicklistEntry e : d.getPicklistValues()) { if (e.isActive()) { out.add(e.getValue()); } }
        return out;
    }

    /** Only values that really exist in the picklist are used in the query. */
    private static List<String> allowed(List<String> wanted, String fieldApi) {
        List<String> out = new List<String>();
        if (wanted == null) { return out; }
        Set<String> valid = new Set<String>(picklistValues(fieldApi));
        for (String v : wanted) { if (v != null && valid.contains(v)) { out.add(v); } }
        return out;
    }

    private static String quoted(List<String> values) {
        List<String> q = new List<String>();
        for (String v : values) { q.add('\'' + String.escapeSingleQuotes(v) + '\''); }
        return String.join(q, ',');
    }

    /** The filters the user actually chose, as SOQL conditions (empty filters add nothing). */
    private static List<String> filterClauses(Filters f, Map<String, Object> binds) {
        List<String> clauses = new List<String>{ 'Has_Resume__c = true' };
        List<String> modes = allowed(f.workModes, 'Work_Modes__c');
        if (!modes.isEmpty()) { clauses.add('Work_Modes__c INCLUDES (' + quoted(modes) + ')'); }
        List<String> roles = allowed(f.roleTypes, 'Role_Types__c');
        if (!roles.isEmpty()) { clauses.add('Role_Types__c INCLUDES (' + quoted(roles) + ')'); }
        List<String> cities = new List<String>();
        if (String.isNotBlank(f.cities)) {
            for (String c : f.cities.split(',')) { if (String.isNotBlank(c)) { cities.add(c.trim()); } }
        }
        if (!cities.isEmpty()) { clauses.add('City__c IN :cities'); binds.put('cities', cities); }
        if (f.maxSalary != null) {
            clauses.add('Expected_Salary__c != null AND Expected_Salary__c <= :maxSalary');
            binds.put('maxSalary', f.maxSalary);
        }
        return clauses;
    }

    /** Contacts with a PARSED resume that match every chosen filter. Returns at most cap + 1 rows. */
    public static List<Contact> findCandidates(Filters f, Integer cap) {
        Map<String, Object> binds = new Map<String, Object>();
        List<String> clauses = filterClauses(f, binds);
        clauses.add('Resume_Parse_Status__c = \'Parsed\'');
        String q = 'SELECT Id, Name, Resume_Parsed_On__c FROM Contact WHERE '
            + String.join(clauses, ' AND ') + ' ORDER BY Name LIMIT ' + (cap + 1);
        return Database.queryWithBinds(q, binds, AccessLevel.USER_MODE);
    }

    /** Contacts that match the filters and have a resume, but are not (yet) parsed. Only used for the on-screen hint. */
    public static Integer countNotParsed(Filters f) {
        Map<String, Object> binds = new Map<String, Object>();
        List<String> clauses = filterClauses(f, binds);
        clauses.add('(Resume_Parse_Status__c = null OR Resume_Parse_Status__c != \'Parsed\')');
        return Database.countQueryWithBinds('SELECT COUNT() FROM Contact WHERE ' + String.join(clauses, ' AND '),
                                            binds, AccessLevel.USER_MODE);
    }

    public static StartResult start(Id jobId, Filters f) {
        // 1) The only callout comes first; everything after it is queries and DML.
        try { JobRequirementsService.ensureFresh(jobId); }
        catch (Exception e) { System.debug(LoggingLevel.WARN, 'Job requirement extraction skipped: ' + e.getMessage()); }
        Job__c job = Database.query('SELECT ' + CandidateMatchService.JOB_FIELDS + ' FROM Job__c WHERE Id = :jobId');

        // 2) Filter (parsed resumes only)
        Filters filters = f == null ? new Filters() : f;
        List<Contact> found = findCandidates(filters, MAX_CANDIDATES);
        StartResult res = new StartResult();
        res.notParsed = countNotParsed(filters);
        if (found.size() > MAX_CANDIDATES) { res.capped = true; found.remove(found.size() - 1); }
        res.matched = found.size();
        res.runKey = String.valueOf(Math.abs(Crypto.getRandomLong()));
        if (found.isEmpty()) { return res; }

        Set<Id> ids = new Map<Id, Contact>(found).keySet();
        Map<Id, Candidate_Match__c> existing = new Map<Id, Candidate_Match__c>();
        for (Candidate_Match__c m : [
            SELECT Id, Contact__c, Status__c, Scored_On__c FROM Candidate_Match__c
            WHERE Job__c = :jobId AND Contact__c IN :ids
        ]) { existing.put(m.Contact__c, m); }

        // 3) Reuse fresh scores, queue the rest for scoring
        List<Candidate_Match__c> rows = new List<Candidate_Match__c>();
        List<Id> toScore = new List<Id>();
        for (Contact c : found) {
            Candidate_Match__c m = existing.containsKey(c.Id) ? existing.get(c.Id)
                : new Candidate_Match__c(Job__c = jobId, Contact__c = c.Id);
            m.Run_Key__c = res.runKey;
            Boolean fresh = m.Id != null && m.Status__c == 'Scored' && m.Scored_On__c != null
                && m.Scored_On__c >= job.LastModifiedDate
                && (c.Resume_Parsed_On__c == null || m.Scored_On__c >= c.Resume_Parsed_On__c);
            if (fresh) {
                res.cached++;
            } else {
                m.Status__c = 'Queued for scoring';
                toScore.add(c.Id);
            }
            rows.add(m);
        }
        upsert rows;
        res.toScore = toScore.size();
        if (toScore.isEmpty()) { return res; }

        // 4) Score in the background
        Database.executeBatch(new DirectScoreBatch(res.runKey), 2);
        return res;
    }
}
