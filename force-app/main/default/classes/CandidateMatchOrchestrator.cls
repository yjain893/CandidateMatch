/**
 * "Apply filters" logic. Resumes are parsed BEFORE this screen is used (ResumeParseBatch / ResumeParseScheduler).
 *  1. The job requirements were already extracted from the job description by JobRequirementsBatch (not here).
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
        public List<String> skills;      // candidates must have ALL of these (matched on the normalized Skill__c.Name_Key__c)
        public Integer availableWithinDays; // Date_Available__c must be filled and at most this many days from today (0 = now)
        public List<String> skillOptions;   // only for the screen's live counts: every skill it shows, so each can be counted
        public Id jobId;                    // the job whose skill map (Job__c.Skill_Map__c) says which other names satisfy a skill
    }

    /** Thrown when a filter cannot be applied safely, e.g. too many candidates to check their skills. */
    public class FilterException extends Exception {}

    /** One candidate of the pool with the date and the skills (among the asked-for ones) read from the parsed resume. */
    public class PoolEntry {
        public Contact contact;
        public Date available;
        public Set<String> skills = new Set<String>();
    }

    // Skills are checked one candidate at a time, in memory, because SOQL allows only about two semi-joins per query and an
    // aggregate query returns at most 2,000 rows. A query returns at most 50,000 rows, so the pool is limited (see skillPoolLimit).
    // 30,000 of the 50,000, not more: with the job's skill map a candidate can have a few rows per skill (the skill and its aliases).
    private static final Integer SKILL_ROW_BUDGET = 30000;
    private static final Integer MAX_SKILL_POOL = 4000;
    // Names of two or more words (the job skills, then their aliases) that are also matched inside longer stored names. Two LIKE terms each,
    // and a SOQL WHERE clause may be at most 4,000 characters long, so only the first 40 are used; the rest still match as whole names.
    private static final Integer MAX_CONTAINED_NAMES = 40;
    // How much of the longer name a shorter one must be (in words) to count as the same skill: "REST API" is 2 of the 3 words of
    // "REST API Integration" (67%), "Platform Developer" is only 2 of 4 of "Salesforce Platform Developer Certification" (50%).
    private static final Integer MIN_OVERLAP_PERCENT = 60;
    private static final Integer MAX_WORDS_SPLIT = 8;
    @TestVisible private static Integer poolLimitOverride;

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

    /** The date filter as a SOQL condition. A candidate with no date is left out once a window is chosen. */
    private static void addDate(List<String> clauses, Filters f, Map<String, Object> binds) {
        Date deadline = availableBy(f);
        if (deadline != null) {
            clauses.add('Date_Available__c != null AND Date_Available__c <= :availableBy');
            binds.put('availableBy', deadline);
        }
    }

    /** The last day a candidate may become available, or null when the date is not filtered. */
    public static Date availableBy(Filters f) {
        return f == null || f.availableWithinDays == null ? null : Date.today().addDays(f.availableWithinDays);
    }

    public static Boolean availableOk(Date available, Date deadline) {
        return deadline == null || (available != null && available <= deadline);
    }

    /** "Lightning Web Components " -> "lightning web components" (how Skill__c.Name_Key__c is stored). Blanks and repeats are dropped. */
    public static List<String> skillKeys(List<String> names) {
        List<String> out = new List<String>();
        if (names == null) { return out; }
        Set<String> seen = new Set<String>();
        for (String n : names) {
            String k = ResumeParserService.normalizeKey(n).left(80);
            if (String.isNotBlank(k) && seen.add(k)) { out.add(k); }
        }
        return out;
    }

    /** How many candidates may be looked at one by one. Each needs up to one row per skill and a query returns at most 50,000 rows. */
    public static Integer skillPoolLimit(Integer keyCount) {
        if (poolLimitOverride != null) { return poolLimitOverride; }
        return Math.max(200, Math.min(MAX_SKILL_POOL, SKILL_ROW_BUDGET / Math.max(1, keyCount)));
    }

    /** Candidates with a parsed resume that fit the work mode, city, salary and role filters (skills and date left out). */
    public static Integer countPool(Filters f) {
        Map<String, Object> binds = new Map<String, Object>();
        List<String> clauses = filterClauses(f, binds);
        clauses.add('Resume_Parse_Status__c = \'Parsed\'');
        return Database.countQueryWithBinds('SELECT COUNT() FROM Contact WHERE ' + String.join(clauses, ' AND '),
                                            binds, AccessLevel.USER_MODE);
    }

    /** Same as countPool plus the date filter. Skills are not looked at, so this works for any number of candidates. */
    public static Integer countMatchingWithoutSkills(Filters f) {
        Map<String, Object> binds = new Map<String, Object>();
        List<String> clauses = filterClauses(f, binds);
        addDate(clauses, f, binds);
        clauses.add('Resume_Parse_Status__c = \'Parsed\'');
        return Database.countQueryWithBinds('SELECT COUNT() FROM Contact WHERE ' + String.join(clauses, ' AND '),
                                            binds, AccessLevel.USER_MODE);
    }

    /**
     * The job's skill map as keys: job skill (normalized) -> the other names (normalized) that satisfy it, read from Job__c.Skill_Map__c.
     * Empty when the filter has no job, the job has no map, or the map was hand-edited into something that is not valid JSON, in which
     * case skills match by their own name only.
     */
    @TestVisible
    private static Map<String, Set<String>> jobAliasKeys(Filters f) {
        Map<String, Set<String>> out = new Map<String, Set<String>>();
        if (f == null || f.jobId == null) { return out; }
        List<Job__c> jobs = [SELECT Skill_Map__c FROM Job__c WHERE Id = :f.jobId WITH USER_MODE];
        if (jobs.isEmpty() || String.isBlank(jobs[0].Skill_Map__c)) { return out; }
        try {
            Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(jobs[0].Skill_Map__c);
            for (String skill : raw.keySet()) {
                Set<String> names = new Set<String>();
                Object listed = raw.get(skill);
                if (listed instanceof List<Object>) {
                    for (Object a : (List<Object>) listed) {
                        String key = ResumeParserService.normalizeKey(a == null ? null : String.valueOf(a)).left(80);
                        if (String.isNotBlank(key)) { names.add(key); }
                    }
                }
                String own = ResumeParserService.normalizeKey(skill).left(80);
                names.remove(own);
                if (out.containsKey(own)) { out.get(own).addAll(names); } else { out.put(own, names); }
            }
        } catch (Exception e) {
            return new Map<String, Set<String>>();
        }
        return out;
    }

    /**
     * The pool (work mode, city, salary and role filters, parsed resumes) with each candidate's date and which of the given skill
     * keys the candidate satisfies. A stored skill name satisfies a job skill when it is
     *  - the job skill's own name, or any other name saved for it in the job's skill map (Job__c.Skill_Map__c), or
     *  - made of consecutive words of one of those names ("REST API" inside "REST API Integration"), or
     *  - a longer name that contains one of those names as consecutive words ("Salesforce Platform Developer I" contains "Platform Developer I"),
     * the last two only when the shorter name is at least MIN_OVERLAP_PERCENT of the longer one's words and has two or more words.
     * Two queries. The caller must have checked countPool against skillPoolLimit first.
     */
    public static List<PoolEntry> readPool(Filters f, List<String> keys) {
        Map<String, Object> binds = new Map<String, Object>();
        List<String> clauses = filterClauses(f, binds);
        clauses.add('Resume_Parse_Status__c = \'Parsed\'');
        String conditions = String.join(clauses, ' AND ');
        Map<Id, PoolEntry> byId = new Map<Id, PoolEntry>();
        for (Contact c : (List<Contact>) Database.queryWithBinds(
                'SELECT Id, Name, Resume_Parsed_On__c, Date_Available__c FROM Contact WHERE ' + conditions,
                binds, AccessLevel.USER_MODE)) {
            PoolEntry e = new PoolEntry();
            e.contact = c;
            e.available = c.Date_Available__c;
            byId.put(c.Id, e);
        }
        if (byId.isEmpty() || keys == null || keys.isEmpty()) { return byId.values(); }
        // stored skill name -> the job skills it satisfies: the skill's own name, its aliases, and shorter names inside them
        Map<String, Set<String>> aliasKeys = jobAliasKeys(f);
        Map<String, Set<String>> satisfies = new Map<String, Set<String>>();
        Map<String, Set<String>> inside = new Map<String, Set<String>>();       // name of two or more words -> the job skills it stands for
        for (String jobSkill : keys) {
            List<String> names = new List<String>{ jobSkill };
            if (aliasKeys.containsKey(jobSkill)) { names.addAll(aliasKeys.get(jobSkill)); }
            for (String name : names) {
                addTo(satisfies, name, jobSkill);
                for (String part : partialNames(name)) { addTo(satisfies, part, jobSkill); }
                if (name.contains(' ')) { addTo(inside, name, jobSkill); }
            }
        }
        binds.put('skillKeys', new List<String>(satisfies.keySet()));
        // A longer stored name that contains one of those names as whole words also counts, so the query also takes rows LIKE '%name%';
        // whole words and how much of the stored name it covers are then checked in code. The job skills themselves come first.
        List<String> patterns = new List<String>();
        for (String jobSkill : keys) { if (inside.containsKey(jobSkill)) { patterns.add(jobSkill); } }
        Set<String> chosen = new Set<String>(patterns);
        List<String> others = new List<String>(inside.keySet());
        others.sort();
        for (String other : others) { if (chosen.add(other)) { patterns.add(other); } }
        List<String> likes = new List<String>();
        List<Phrase> phrases = new List<Phrase>();
        for (Integer i = 0; i < patterns.size() && i < MAX_CONTAINED_NAMES; i++) {
            binds.put('l' + i, '%' + patterns[i] + '%');
            likes.add('Name_Key__c LIKE :l' + i);
            likes.add('Canonical_Key__c LIKE :l' + i);
            phrases.add(new Phrase(patterns[i], inside.get(patterns[i])));
        }
        // a stored skill counts under the name on the resume (Name_Key__c) and under the standard name the parser's AI gave it (Canonical_Key__c)
        for (Skill__c s : (List<Skill__c>) Database.queryWithBinds(
                'SELECT Contact__c, Name_Key__c, Canonical_Key__c FROM Skill__c'
                + ' WHERE (Name_Key__c IN :skillKeys OR Canonical_Key__c IN :skillKeys'
                + (likes.isEmpty() ? '' : ' OR ' + String.join(likes, ' OR ')) + ')'
                + ' AND Contact__c IN (SELECT Id FROM Contact WHERE ' + conditions + ')',
                binds, AccessLevel.USER_MODE)) {
            PoolEntry e = byId.get(s.Contact__c);
            if (e == null) { continue; }
            credit(e, s.Name_Key__c, satisfies, phrases);
            credit(e, s.Canonical_Key__c, satisfies, phrases);
        }
        return byId.values();
    }

    private static void addTo(Map<String, Set<String>> m, String key, String value) {
        if (!m.containsKey(key)) { m.put(key, new Set<String>()); }
        m.get(key).add(value);
    }

    /** A name of two or more words that is also looked for inside longer stored names. */
    private class Phrase {
        public String padded;          // ' rest api ': so that only whole words are found
        public Integer words;
        public Set<String> skills;
        public Phrase(String key, Set<String> skills) {
            this.padded = ' ' + key + ' ';
            this.words = key.countMatches(' ') + 1;
            this.skills = skills;
        }
    }

    /** True when a name of shorterWords words is enough of a name of longerWords words to stand for it (MIN_OVERLAP_PERCENT). */
    private static Boolean coversEnough(Integer shorterWords, Integer longerWords) {
        return 100 * shorterWords >= MIN_OVERLAP_PERCENT * longerWords;
    }

    /**
     * Shorter names made of consecutive words of a key that cover enough of it: "rest api integration" -> "rest api" and "api integration".
     * Works from the words as they are, with no list of words, so it is the same for every skill and language. Names of fewer than three
     * words have none (a single word is never cut out of a name).
     */
    @TestVisible
    private static Set<String> partialNames(String key) {
        Set<String> out = new Set<String>();
        if (String.isBlank(key)) { return out; }
        List<String> words = key.split(' ');
        Integer n = words.size();
        if (n < 3 || n > MAX_WORDS_SPLIT) { return out; }
        for (Integer len = 2; len < n; len++) {
            if (!coversEnough(len, n)) { continue; }
            for (Integer start = 0; start + len <= n; start++) {
                List<String> part = new List<String>();
                for (Integer i = start; i < start + len; i++) { part.add(words[i]); }
                out.add(String.join(part, ' '));
            }
        }
        return out;
    }

    /** Adds to the candidate the job skills that one stored skill name satisfies: by exactly that name, or by containing one of the phrases. */
    private static void credit(PoolEntry e, String storedKey, Map<String, Set<String>> satisfies, List<Phrase> phrases) {
        if (storedKey == null) { return; }
        Set<String> exact = satisfies.get(storedKey);
        if (exact != null) { e.skills.addAll(exact); }
        if (phrases.isEmpty()) { return; }
        String padded = ' ' + storedKey + ' ';
        Integer storedWords = storedKey.countMatches(' ') + 1;
        for (Phrase p : phrases) {
            if (padded.contains(p.padded) && coversEnough(p.words, storedWords)) { e.skills.addAll(p.skills); }
        }
    }

    /** Sorts contacts by name, like ORDER BY Name. */
    private class ByName implements Comparable {
        public Contact contact;
        public ByName(Contact c) { contact = c; }
        public Integer compareTo(Object other) {
            String a = contact.Name == null ? '' : contact.Name;
            String b = ((ByName) other).contact.Name == null ? '' : ((ByName) other).contact.Name;
            return a.compareTo(b);
        }
    }

    /** Contacts with a PARSED resume that match every chosen filter (skills and date included). Returns at most cap + 1 rows. */
    public static List<Contact> findCandidates(Filters f, Integer cap) {
        List<String> selected = skillKeys(f.skills);
        if (!selected.isEmpty()) { return findWithSkills(f, selected, cap); }
        Map<String, Object> binds = new Map<String, Object>();
        List<String> clauses = filterClauses(f, binds);
        addDate(clauses, f, binds);
        clauses.add('Resume_Parse_Status__c = \'Parsed\'');
        String q = 'SELECT Id, Name, Resume_Parsed_On__c FROM Contact WHERE '
            + String.join(clauses, ' AND ') + ' ORDER BY Name LIMIT ' + (cap + 1);
        return Database.queryWithBinds(q, binds, AccessLevel.USER_MODE);
    }

    private static List<Contact> findWithSkills(Filters f, List<String> selected, Integer cap) {
        if (countPool(f) > skillPoolLimit(selected.size())) {
            throw new FilterException('Too many candidates fit the other filters to check their skills. '
                + 'Narrow the city, work mode, salary or role types first.');
        }
        Date deadline = availableBy(f);
        List<ByName> hits = new List<ByName>();
        for (PoolEntry e : readPool(f, selected)) {
            if (e.skills.containsAll(selected) && availableOk(e.available, deadline)) { hits.add(new ByName(e.contact)); }
        }
        hits.sort();
        List<Contact> out = new List<Contact>();
        for (ByName h : hits) {
            if (out.size() > cap) { break; }
            out.add(h.contact);
        }
        return out;
    }

    /** Contacts that match the filters and have a resume, but are not (yet) parsed. Only used for the on-screen hint. */
    public static Integer countNotParsed(Filters f) {
        Map<String, Object> binds = new Map<String, Object>();
        List<String> clauses = filterClauses(f, binds);
        addDate(clauses, f, binds);
        clauses.add('(Resume_Parse_Status__c = null OR Resume_Parse_Status__c != \'Parsed\')');
        return Database.countQueryWithBinds('SELECT COUNT() FROM Contact WHERE ' + String.join(clauses, ' AND '),
                                            binds, AccessLevel.USER_MODE);
    }

    public static StartResult start(Id jobId, Filters f) {
        // 1) The job requirements are NOT extracted here. JobRequirementsBatch / JobRequirementsScheduler fill them beforehand,
        //    so this click makes no prompt call for the job; it only reads what is already on the record.
        Job__c job = Database.query('SELECT ' + CandidateMatchService.JOB_FIELDS + ' FROM Job__c WHERE Id = :jobId');

        // 2) Filter (parsed resumes only)
        Filters filters = f == null ? new Filters() : f;
        if (filters.jobId == null) { filters.jobId = jobId; }            // so the skill filter can read this job's skill map
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
