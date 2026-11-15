/**
 * Turns parsed-resume JSON into Skill__c / Education_History__c / Employment_History__c records.
 *  - persist(): shared by the AiJobRun path and the synchronous path (single contact / fallback).
 *  - Accuracy guard: thin or low-confidence parses get status 'Review' and are excluded from matching until a human approves.
 */
public with sharing class ResumeParserService {
    public static final String TEMPLATE = 'Parse_Resume';

    public class SkillRow { public String name; public Decimal years; }
    public class EducationRow {
        public String institution; public String degree; public String fieldOfStudy;
        public String startDate; public String endDate;
    }
    public class EmploymentRow {
        public String employer; public String role; public String startDate;
        public String endDate; public String description;
    }
    public class ParsedResume {
        public String summary;
        public String confidence; // high | medium | low
        public List<SkillRow> skills;
        public List<EducationRow> education;
        public List<EmploymentRow> employment;
    }

    public static ParsedResume parseText(String raw) {
        return (ParsedResume) JSON.deserialize(PromptRunner.clean(raw), ParsedResume.class);
    }

    /** Synchronous path: one prompt call per contact (agent action, small volumes, fallback). */
    public static Integer process(List<Id> contactIds) {
        Map<Id, Id> fileByContact = findResumeFiles(contactIds);
        Map<Id, ParsedResume> parsed = new Map<Id, ParsedResume>();
        Map<Id, String> errors = new Map<Id, String>();
        for (Id cid : contactIds) { // all callouts first, DML after
            try {
                Id docId = fileByContact.get(cid);
                if (docId == null) { errors.put(cid, 'No PDF resume found on contact'); continue; }
                String raw = PromptRunner.run(TEMPLATE,
                    new Map<String, Object>{ 'Resume' => new Map<String, String>{ 'id' => docId } });
                parsed.put(cid, parseText(raw));
            } catch (Exception e) {
                errors.put(cid, e.getMessage());
            }
        }
        return persist(contactIds, parsed, errors);
    }

    /** Saves results. Returns the number of contacts that failed. */
    public static Integer persist(List<Id> contactIds, Map<Id, ParsedResume> parsed, Map<Id, String> errors) {
        Set<Id> okIds = parsed.keySet().clone();
        if (!okIds.isEmpty()) { // idempotent: replace old child rows
            delete [SELECT Id FROM Skill__c WHERE Contact__c IN :okIds];
            delete [SELECT Id FROM Education_History__c WHERE Contact__c IN :okIds];
            delete [SELECT Id FROM Employment_History__c WHERE Contact__c IN :okIds];
        }

        List<SObject> skillRows = new List<SObject>();
        List<SObject> eduRows = new List<SObject>();
        List<SObject> empRows = new List<SObject>();
        Map<Id, String> profiles = new Map<Id, String>();
        Map<Id, Integer> skillCount = new Map<Id, Integer>();
        Map<Id, Integer> empCount = new Map<Id, Integer>();
        Map<Id, Decimal> expYears = new Map<Id, Decimal>();

        for (Id cid : okIds) {
            ParsedResume p = parsed.get(cid);
            Set<String> seen = new Set<String>();
            List<String> skillText = new List<String>();
            List<String> eduText = new List<String>();
            List<String> empText = new List<String>();

            if (p.skills != null) {
                for (SkillRow s : p.skills) {
                    if (s == null || String.isBlank(s.name)) { continue; }
                    String key = normalizeKey(s.name);
                    if (String.isBlank(key) || !seen.add(key)) { continue; }
                    skillRows.add(new Skill__c(Name = s.name.left(80), Name_Key__c = key.left(80),
                        Years_Experience__c = s.years, Contact__c = cid));
                    skillText.add(s.name + (s.years != null ? ' (' + s.years + 'y)' : ''));
                }
            }
            if (p.education != null) {
                for (EducationRow r : p.education) {
                    if (r == null || String.isBlank(r.institution)) { continue; }
                    eduRows.add(new Education_History__c(Name = r.institution.left(80),
                        Degree__c = r.degree == null ? null : r.degree.left(150),
                        Field_Of_Study__c = r.fieldOfStudy == null ? null : r.fieldOfStudy.left(150),
                        Start_Date__c = toDate(r.startDate), End_Date__c = toDate(r.endDate), Contact__c = cid));
                    eduText.add(nz(r.degree) + ' ' + nz(r.fieldOfStudy) + ' - ' + r.institution
                        + ' (' + nz(r.startDate) + ' to ' + nz(r.endDate) + ')');
                }
            }
            if (p.employment != null) {
                for (EmploymentRow r : p.employment) {
                    if (r == null || String.isBlank(r.employer)) { continue; }
                    empRows.add(new Employment_History__c(Name = r.employer.left(80),
                        Role__c = r.role == null ? null : r.role.left(150),
                        Start_Date__c = toDate(r.startDate), End_Date__c = toDate(r.endDate),
                        Description__c = r.description, Contact__c = cid));
                    expYears.put(cid, dz(expYears.get(cid)) + yearsBetween(r.startDate, r.endDate));
                    empText.add(nz(r.role) + ' at ' + r.employer + ' (' + nz(r.startDate) + ' to '
                        + (String.isBlank(r.endDate) ? 'present' : r.endDate) + '): ' + nz(r.description));
                }
            }
            skillCount.put(cid, skillText.size());
            empCount.put(cid, empText.size());
            // Profile used for matching. Deliberately has no name / contact details.
            profiles.put(cid, ('Summary: ' + nz(p.summary)
                + '\nSkills: ' + String.join(skillText, ', ')
                + '\nEducation:\n' + String.join(eduText, '\n')
                + '\nEmployment:\n' + String.join(empText, '\n')).left(32000));
        }

        saveRows(skillRows, errors);
        saveRows(eduRows, errors);
        saveRows(empRows, errors);

        List<Contact> updates = new List<Contact>();
        Integer failed = 0;
        for (Id cid : contactIds) {
            Contact c = new Contact(Id = cid);
            if (errors.containsKey(cid)) {
                failed++;
                c.Resume_Parse_Status__c = 'Failed';
                c.Resume_Parse_Error__c = errors.get(cid) == null ? 'Unknown error' : errors.get(cid).left(255);
            } else {
                ParsedResume p = parsed.get(cid);
                List<String> why = new List<String>();
                if (skillCount.get(cid) == 0) { why.add('no skills found'); }
                if (empCount.get(cid) == 0) { why.add('no employment found'); }
                if ('low'.equalsIgnoreCase(p.confidence)) { why.add('AI reported low confidence'); }
                c.Resume_Parse_Status__c = why.isEmpty() ? 'Parsed' : 'Review';
                c.Resume_Parse_Error__c = why.isEmpty() ? null : ('Needs review: ' + String.join(why, ', '));
                c.Resume_Parsed_On__c = System.now();
                c.Candidate_Profile__c = profiles.get(cid);
                Decimal cap = 99;
                Decimal ey = dz(expYears.get(cid));
                c.Total_Experience_Years__c = (ey > cap ? cap : ey).setScale(1);
            }
            updates.add(c);
        }
        update updates;
        return failed;
    }

    /** Latest PDF linked to each contact. */
    public static Map<Id, Id> findResumeFiles(List<Id> contactIds) {
        Map<Id, Id> docByContact = new Map<Id, Id>();
        Map<Id, Datetime> latest = new Map<Id, Datetime>();
        if (contactIds == null || contactIds.isEmpty()) { return docByContact; } // ContentDocumentLink needs a non-empty id filter
        for (ContentDocumentLink l : [
            SELECT LinkedEntityId, ContentDocumentId, ContentDocument.LastModifiedDate
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :contactIds AND ContentDocument.FileExtension = 'pdf'
        ]) {
            Datetime d = l.ContentDocument.LastModifiedDate;
            if (!latest.containsKey(l.LinkedEntityId) || d > latest.get(l.LinkedEntityId)) {
                latest.put(l.LinkedEntityId, d);
                docByContact.put(l.LinkedEntityId, l.ContentDocumentId);
            }
        }
        return docByContact;
    }

    private static void saveRows(List<SObject> rows, Map<Id, String> errors) {
        if (rows.isEmpty()) { return; }
        List<Database.SaveResult> res = Database.insert(rows, false);
        for (Integer i = 0; i < res.size(); i++) {
            if (!res[i].isSuccess()) {
                errors.put((Id) rows[i].get('Contact__c'), res[i].getErrors()[0].getMessage());
            }
        }
    }

    public static String normalizeKey(String s) {
        if (s == null) { return ''; }
        String t = s.toLowerCase().replaceAll('[^a-z0-9+#.]+', ' ');
        t = t.replaceAll('\\.(?=\\s|$)', ' ');
        return t.replaceAll('\\s+', ' ').trim();
    }

    /** Approximate years in a role (overlapping roles are counted twice). */
    private static Decimal yearsBetween(String startS, String endS) {
        Date s = toDate(startS);
        if (s == null) { return 0; }
        Date e = String.isBlank(endS) ? Date.today() : toDate(endS);
        if (e == null || e < s) { return 0; }
        return Decimal.valueOf(s.daysBetween(e)) / 365.25;
    }

    private static Date toDate(String s) {
        if (String.isBlank(s)) { return null; }
        try {
            String t = s.trim();
            if (t.length() == 4) { t += '-01-01'; }
            else if (t.length() == 7) { t += '-01'; }
            return Date.valueOf(t);
        } catch (Exception e) { return null; }
    }

    private static Decimal dz(Decimal d) {
        Decimal zero = 0;
        return d == null ? zero : d;
    }

    private static String nz(String s) { return s == null ? '' : s; }
}
