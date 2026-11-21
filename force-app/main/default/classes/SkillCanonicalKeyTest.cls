/** The standard name of each skill (Skill__c.Canonical_Key__c): saved by the resume parser, and used by the skill filter and counts. */
@IsTest
private class SkillCanonicalKeyTest {

    // ---------------------------------------------------------------------------------------------------- helpers

    /** A candidate with a parsed resume. skills: the name as written on the resume -> the standard name the AI gave (null when none). */
    static Contact candidate(String lastName, Map<String, String> skills) {
        Contact c = new Contact(LastName = lastName, Has_Resume__c = true, Resume_Parse_Status__c = 'Parsed',
                                Candidate_Profile__c = 'Skills: ' + String.join(new List<String>(skills.keySet()), ', '));
        insert c;
        List<Skill__c> rows = new List<Skill__c>();
        for (String name : skills.keySet()) {
            String standard = skills.get(name);
            rows.add(new Skill__c(Name = name, Name_Key__c = ResumeParserService.normalizeKey(name), Contact__c = c.Id,
                Canonical_Key__c = standard == null ? null : ResumeParserService.normalizeKey(standard)));
        }
        insert rows;
        return c;
    }

    static Job__c newJob(String skillMap) {
        Job__c j = new Job__c(Name = 'Dev', Job_Description__c = 'Developer', Skill_Map__c = skillMap);
        insert j;
        return j;
    }

    static CandidateMatchOrchestrator.Filters filters(Id jobId, List<String> selected, List<String> options) {
        CandidateMatchOrchestrator.Filters f = new CandidateMatchOrchestrator.Filters();
        f.jobId = jobId; f.skills = selected; f.skillOptions = options;
        return f;
    }

    static List<String> names(List<Contact> contacts) {
        List<String> out = new List<String>();
        for (Contact c : contacts) { out.add(c.Name); }
        return out;
    }

    static CandidateMatcherV2Controller.SkillCount skillOf(CandidateMatcherV2Controller.MatchCount c, String name) {
        for (CandidateMatcherV2Controller.SkillCount s : c.skills) { if (s.name == name) { return s; } }
        return null;
    }

    // ------------------------------------------------------------------------------------- the parser saves it

    @IsTest static void theParserSavesTheStandardNameOnEachSkill() {
        Contact c = new Contact(LastName = 'Parsed');
        insert c;
        String answer = '{"summary":"Dev","confidence":"high","skills":['
            + '{"name":"LWC","canonical":"Lightning Web Components","years":3},'
            + '{"name":"Apex","canonical":"Apex"},'
            + '{"name":"Flow"},'
            + '{"name":"Platform Developer 2","canonical":"  Salesforce Platform Developer II "}],'
            + '"education":[],"employment":[{"employer":"Acme","role":"Dev","startDate":"2020-01","endDate":null,"description":"x"}]}';

        ResumeParserService.persist(new List<Id>{ c.Id },
            new Map<Id, ResumeParserService.ParsedResume>{ c.Id => ResumeParserService.parseText(answer) }, new Map<Id, String>());

        Map<String, String> standardByName = new Map<String, String>();
        for (Skill__c s : [SELECT Name, Name_Key__c, Canonical_Key__c FROM Skill__c WHERE Contact__c = :c.Id]) {
            standardByName.put(s.Name, s.Canonical_Key__c);
        }
        System.assertEquals(4, standardByName.size());
        System.assertEquals('lightning web components', standardByName.get('LWC'));
        System.assertEquals('apex', standardByName.get('Apex'), 'the same as its own key: still saved, so the field is filled on every row');
        System.assertEquals('flow', standardByName.get('Flow'), 'the AI gave none: the skill\'s own key');
        System.assertEquals('salesforce platform developer ii', standardByName.get('Platform Developer 2'), 'normalized like Name Key');
    }

    @IsTest static void everyParsedSkillGetsAStandardNameAndItFallsBackToTheSkillsOwnKey() {
        ResumeParserService.SkillRow row = new ResumeParserService.SkillRow();
        row.name = 'REST API Integration';
        row.canonical = 'REST API';
        System.assertEquals('rest api', ResumeParserService.canonicalKeyOf(row));
        row.canonical = '  rest api   integration ';
        System.assertEquals('rest api integration', ResumeParserService.canonicalKeyOf(row), 'same key as the name: kept');
        row.canonical = '   ';
        System.assertEquals('rest api integration', ResumeParserService.canonicalKeyOf(row), 'blank: the skill\'s own key');
        row.canonical = null;
        System.assertEquals('rest api integration', ResumeParserService.canonicalKeyOf(row), 'none: the skill\'s own key');
    }

    // ----------------------------------------------------------------------------------- the filter uses it

    @IsTest static void aCandidateMatchesBySkillStandardNameEvenWhenTheJobHasNoMap() {
        Job__c job = newJob(null);
        candidate('Alpha', new Map<String, String>{ 'LWC' => 'Lightning Web Components' });
        candidate('Bravo', new Map<String, String>{ 'LWC' => null });
        candidate('Charlie', new Map<String, String>{ 'Lightning Web Components' => null });

        System.assertEquals(new List<String>{ 'Alpha', 'Charlie' },
            names(CandidateMatchOrchestrator.findCandidates(filters(job.Id, new List<String>{ 'Lightning Web Components' }, null), 200)),
            'Alpha by the standard name the AI gave, Charlie by the name itself; Bravo has no standard name stored');
    }

    @IsTest static void theStandardNameAndTheJobsAliasesWorkTogether() {
        Job__c job = newJob('{"Platform Developer certification":["Salesforce Platform Developer"]}');
        candidate('Pat', new Map<String, String>{ 'PD2' => 'Salesforce Platform Developer' });       // the AI's standard name is one of the aliases
        candidate('Quinn', new Map<String, String>{ 'Salesforce Platform Developer' => null });      // the name on the resume is one of the aliases
        candidate('Robin', new Map<String, String>{ 'Java' => 'Java' });

        System.assertEquals(new List<String>{ 'Pat', 'Quinn' },
            names(CandidateMatchOrchestrator.findCandidates(
                filters(job.Id, new List<String>{ 'Platform Developer certification' }, null), 200)));
    }

    @IsTest static void aStandardNameThatContainsAnAliasAsWholeWordsMatchesToo() {
        Job__c job = newJob('{"Platform Developer certification":["Platform Developer I"]}');
        candidate('Pat', new Map<String, String>{ 'PD1' => 'Salesforce Platform Developer I' });        // standard name contains the alias
        candidate('Quinn', new Map<String, String>{ 'PD2' => 'Salesforce Platform Developer II' });     // "II" is another word than "I"

        System.assertEquals(new List<String>{ 'Pat' },
            names(CandidateMatchOrchestrator.findCandidates(
                filters(job.Id, new List<String>{ 'Platform Developer certification' }, null), 200)));
    }

    @IsTest static void everyCountOnTheScreenUsesTheStandardNameToo() {
        candidate('A', new Map<String, String>{ 'LWC' => 'Lightning Web Components', 'REST API Integration' => 'REST API' });
        candidate('B', new Map<String, String>{ 'Lightning Web Components' => null });
        candidate('C', new Map<String, String>{ 'Java' => null });
        List<String> options = new List<String>{ 'Lightning Web Components', 'REST API' };

        CandidateMatcherV2Controller.MatchCount c = CandidateMatcherV2Controller.countMatches(
            JSON.serialize(filters(null, new List<String>{ 'Lightning Web Components' }, options)));
        System.assertEquals(3, c.pool);
        System.assertEquals(2, c.matched, 'A by its standard name, B by its name');
        System.assertEquals(1, skillOf(c, 'REST API').count, 'only A, whose "REST API Integration" has the standard name "rest api"');
        System.assertEquals(3, skillOf(c, 'Lightning Web Components').count, 'selected: what removing it would give, C would join');
    }

    @IsTest static void skillsStoredBeforeTheStandardNameExistedStillMatchByTheirOwnName() {
        candidate('Old', new Map<String, String>{ 'REST API' => null });
        System.assertEquals(new List<String>{ 'Old' },
            names(CandidateMatchOrchestrator.findCandidates(filters(null, new List<String>{ 'REST API' }, null), 200)));
    }
}
