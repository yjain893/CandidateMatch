/**
 * The AI reads the (rich text) job description ONCE and extracts requirements (required / nice-to-have skills,
 * synonyms, city, work mode, minimum experience) and, for every skill, the other names a resume could use for it (the skill map saved in
 * Skill_Map__c, used by the candidate matcher's skill filter). Re-runs only when the description changes (hash) or EXTRACTION_VERSION is raised.
 * Values a recruiter typed on the Job (City, Work Modes, Min Experience) are never overwritten.
 */
public with sharing class JobRequirementsService {
    public static final String TEMPLATE = 'Extract_Job_Requirements';

    public class Requirements {
        public List<String> requiredSkills;
        public List<String> niceToHaveSkills;
        public Map<String, List<String>> skillAliases;   // skill (as written in the two lists) -> other names for the same skill
        public List<String> synonyms;
        public String location;
        public String workMode;
        public Decimal minExperienceYears;
    }

    private static final Integer MAX_ALIASES = 10;      // per skill, as the prompt asks
    private static final Integer MAX_ALIAS_LENGTH = 60;

    /**
     * Version of what the AI is asked to extract. It is part of the saved hash, so raising it makes every job count as "not read yet"
     * and the requirements batch reads each one once more (needed when the prompt starts returning something new, like skill aliases).
     */
    @TestVisible private static final String EXTRACTION_VERSION = 'skill-aliases-2';

    /** What is compared with Requirements_Hash__c to know whether the job must be read again. */
    public static String contentHash(String description) {
        return hashOf(EXTRACTION_VERSION + '|' + description);
    }

    public static void ensureFresh(Id jobId) {
        Job__c job = [SELECT Id, Job_Description__c, Requirements_Hash__c FROM Job__c WHERE Id = :jobId];
        if (String.isBlank(job.Job_Description__c)) { return; }
        if (contentHash(job.Job_Description__c) == job.Requirements_Hash__c) { return; }
        String raw = PromptRunner.run(TEMPLATE, new Map<String, Object>{
            'Job_Description' => plain(job.Job_Description__c).left(8000) });
        applyText(jobId, raw);
    }

    public static void applyText(Id jobId, String raw) {
        Requirements r = (Requirements) PromptRunner.parse(raw, Requirements.class);
        Job__c job = [SELECT Id, Job_Description__c, City__c, Work_Modes__c, Min_Experience_Years__c
                      FROM Job__c WHERE Id = :jobId];
        job.Required_Skills__c = joinList(r.requiredSkills, 2000);
        job.Nice_To_Have_Skills__c = joinList(r.niceToHaveSkills, 2000);
        List<String> all = new List<String>();
        if (r.synonyms != null) { all.addAll(r.synonyms); }
        if (r.requiredSkills != null) { all.addAll(r.requiredSkills); }
        if (r.niceToHaveSkills != null) { all.addAll(r.niceToHaveSkills); }
        job.Skill_Synonyms__c = joinList(all, 4000);
        job.Skill_Map__c = skillMapJson(r);
        if (String.isBlank(job.City__c) && String.isNotBlank(r.location)) {
            job.City__c = r.location.split(',')[0].trim().left(100);
        }
        if (String.isBlank(job.Work_Modes__c)) { job.Work_Modes__c = normalizeMode(r.workMode); }
        if (job.Min_Experience_Years__c == null) { job.Min_Experience_Years__c = r.minExperienceYears; }
        job.Requirements_Hash__c = contentHash(job.Job_Description__c);
        job.Requirements_Extracted_On__c = System.now();
        update job;
    }

    /**
     * The skill map saved on the job: every required and nice-to-have skill with the other names the AI listed for it, as JSON like
     * {"REST API": ["REST API Integration", "REST APIs"]}. The AI's keys are matched to the skills by normalized name. Aliases that are
     * blank, too long, repeat the skill or repeat each other are dropped, and each skill keeps at most 10. Null when there is no skill.
     */
    @TestVisible
    private static String skillMapJson(Requirements r) {
        List<String> skills = new List<String>();
        if (r.requiredSkills != null) { skills.addAll(r.requiredSkills); }
        if (r.niceToHaveSkills != null) { skills.addAll(r.niceToHaveSkills); }
        Map<String, List<String>> given = new Map<String, List<String>>();
        if (r.skillAliases != null) {
            for (String k : r.skillAliases.keySet()) { given.put(ResumeParserService.normalizeKey(k), r.skillAliases.get(k)); }
        }
        Map<String, List<String>> out = new Map<String, List<String>>();
        for (String skill : skills) {
            String skillKey = ResumeParserService.normalizeKey(skill);
            if (String.isBlank(skillKey) || out.containsKey(skill)) { continue; }
            List<String> aliases = new List<String>();
            Set<String> seen = new Set<String>{ skillKey };
            List<String> wanted = given.get(skillKey);
            if (wanted != null) {
                for (String a : wanted) {
                    if (a == null || a.length() >= MAX_ALIAS_LENGTH) { continue; }
                    String key = ResumeParserService.normalizeKey(a);
                    if (String.isBlank(key) || !seen.add(key)) { continue; }
                    aliases.add(a.trim());
                    if (aliases.size() >= MAX_ALIASES) { break; }
                }
            }
            out.put(skill, aliases);
        }
        return out.isEmpty() ? null : JSON.serialize(out);
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