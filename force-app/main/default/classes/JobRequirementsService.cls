/**
 * The AI reads the (rich text) job description ONCE and extracts requirements (required / nice-to-have skills,
 * synonyms, city, work mode, minimum experience). Re-runs only when the description changes (hash).
 * Values a recruiter typed on the Job (City, Work Modes, Min Experience) are never overwritten.
 */
public with sharing class JobRequirementsService {
    public static final String TEMPLATE = 'Extract_Job_Requirements';

    public class Requirements {
        public List<String> requiredSkills;
        public List<String> niceToHaveSkills;
        public List<String> synonyms;
        public String location;
        public String workMode;
        public Decimal minExperienceYears;
    }

    public static void ensureFresh(Id jobId) {
        Job__c job = [SELECT Id, Job_Description__c, Requirements_Hash__c FROM Job__c WHERE Id = :jobId];
        if (String.isBlank(job.Job_Description__c)) { return; }
        if (hashOf(job.Job_Description__c) == job.Requirements_Hash__c) { return; }
        String raw = PromptRunner.run(TEMPLATE, new Map<String, Object>{
            'Job_Description' => plain(job.Job_Description__c).left(8000) });
        applyText(jobId, raw);
    }

    public static void applyText(Id jobId, String raw) {
        Requirements r = (Requirements) JSON.deserialize(PromptRunner.clean(raw), Requirements.class);
        Job__c job = [SELECT Id, Job_Description__c, City__c, Work_Modes__c, Min_Experience_Years__c
                      FROM Job__c WHERE Id = :jobId];
        job.Required_Skills__c = joinList(r.requiredSkills, 2000);
        job.Nice_To_Have_Skills__c = joinList(r.niceToHaveSkills, 2000);
        List<String> all = new List<String>();
        if (r.synonyms != null) { all.addAll(r.synonyms); }
        if (r.requiredSkills != null) { all.addAll(r.requiredSkills); }
        if (r.niceToHaveSkills != null) { all.addAll(r.niceToHaveSkills); }
        job.Skill_Synonyms__c = joinList(all, 4000);
        if (String.isBlank(job.City__c) && String.isNotBlank(r.location)) {
            job.City__c = r.location.split(',')[0].trim().left(100);
        }
        if (String.isBlank(job.Work_Modes__c)) { job.Work_Modes__c = normalizeMode(r.workMode); }
        if (job.Min_Experience_Years__c == null) { job.Min_Experience_Years__c = r.minExperienceYears; }
        job.Requirements_Hash__c = hashOf(job.Job_Description__c);
        job.Requirements_Extracted_On__c = System.now();
        update job;
    }

    /** Maps free text to our picklist values: Remote, On-site, Hybrid (or null). */
    public static String normalizeMode(String s) {
        if (String.isBlank(s)) { return null; }
        String t = s.toLowerCase().replace('-', '').replace(' ', '');
        if (t.contains('remote')) { return 'Remote'; }
        if (t.contains('hybrid')) { return 'Hybrid'; }
        if (t.contains('onsite') || t.contains('office')) { return 'On-site'; }
        return null;
    }

    /** Rich text (HTML) to plain text for the AI. */
    public static String plain(String html) {
        if (html == null) { return ''; }
        String t = html.replaceAll('(?i)<br\\s*/?>', '\n')
                       .replaceAll('(?i)</(p|div|li|h[1-6]|tr)>', '\n')
                       .replaceAll('<[^>]+>', ' ')
                       .replace('&nbsp;', ' ').replace('&amp;', '&').replace('&lt;', '<')
                       .replace('&gt;', '>').replace('&quot;', '"').replace('&#39;', '\'');
        return t.replaceAll('[ \\t]+', ' ').replaceAll('\\s*\\n\\s*', '\n').trim();
    }

    private static String joinList(List<String> items, Integer maxLen) {
        if (items == null || items.isEmpty()) { return null; }
        return String.join(items, ', ').left(maxLen);
    }

    public static String hashOf(String s) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(s == null ? '' : s)));
    }
}
