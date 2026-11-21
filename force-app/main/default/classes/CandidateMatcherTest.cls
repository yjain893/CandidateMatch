/** Filters, the apply-filters orchestration (scoring only) and the UI controller. */
@IsTest
private class CandidateMatcherTest {
    static final String EXTRACT_JSON = '{"requiredSkills":["Java"],"niceToHaveSkills":[],"synonyms":[],"location":"","workMode":"","minExperienceYears":null}';
    /**
     * Role Types values that exist on BOTH Contact and Job in the org the test runs in. The picklist is restricted and an org can hold other
     * values than the ones this test was first written with (this one now holds executive roles), so the test never hardcodes them.
     */
    static List<String> sharedRoles() {
        Set<String> onJob = new Set<String>();
        for (Schema.PicklistEntry e : Job__c.Role_Types__c.getDescribe().getPicklistValues()) { if (e.isActive()) { onJob.add(e.getValue()); } }
        List<String> out = new List<String>();
        for (Schema.PicklistEntry e : Contact.Role_Types__c.getDescribe().getPicklistValues()) {
            if (e.isActive() && onJob.contains(e.getValue())) { out.add(e.getValue()); }
        }
        return out;
    }
    static final List<String> ROLES = sharedRoles();
    static final String ROLE_A = ROLES[0];      // the role of every candidate and of the job below
    static final String ROLE_B = ROLES[1];      // only Ben has it besides ROLE_A

    static String scoreJson(Integer s) {
        return '{"skillsScore":' + s + ',"experienceScore":' + s + ',"fitScore":' + s + ',"educationScore":' + s
            + ',"matchedSkills":["Java"],"missingSkills":[],"fitNote":"","reasoning":"ok"}';
    }

    @TestSetup static void setup() {
        insert new List<Contact>{
            new Contact(LastName = 'Anna', Has_Resume__c = true, Work_Modes__c = 'Remote', City__c = 'Austin', Expected_Salary__c = 90000,
                        Role_Types__c = ROLE_A, Resume_Parse_Status__c = 'Parsed', Candidate_Profile__c = 'Skills: Java'),
            new Contact(LastName = 'Ben', Has_Resume__c = true, Work_Modes__c = 'Hybrid;Remote', City__c = 'London', Expected_Salary__c = 150000,
                        Role_Types__c = ROLE_A + ';' + ROLE_B, Resume_Parse_Status__c = 'Parsed', Candidate_Profile__c = 'Skills: Java, Apex'),
            new Contact(LastName = 'Cara', Has_Resume__c = false, Work_Modes__c = 'Remote', City__c = 'Austin', Expected_Salary__c = 50000,
                        Role_Types__c = ROLE_A),
            new Contact(LastName = 'Dan', Has_Resume__c = true, Work_Modes__c = 'Remote', City__c = 'Austin', Expected_Salary__c = 70000,
                        Role_Types__c = ROLE_A),                                        // resume not parsed yet
            new Contact(LastName = 'Eve', Has_Resume__c = true, Work_Modes__c = 'Remote', City__c = 'Austin', Expected_Salary__c = 70000,
                        Role_Types__c = ROLE_A, Resume_Parse_Status__c = 'Review') // parse needs a human check
        };
        insert new Job__c(Name = 'Dev', Job_Description__c = '<p>Java developer</p>', City__c = 'Austin',
                          Work_Modes__c = 'Remote', Expected_Salary__c = 100000, Role_Types__c = ROLE_A);
    }

    static Set<String> names(CandidateMatchOrchestrator.Filters f) {
        Set<String> out = new Set<String>();
        for (Contact c : CandidateMatchOrchestrator.findCandidates(f, 200)) { out.add(c.Name); }
        return out;
    }

    @IsTest static void onlyParsedResumesAndChosenFiltersApply() {
        CandidateMatchOrchestrator.Filters f = new CandidateMatchOrchestrator.Filters();
        System.assertEquals(new Set<String>{ 'Anna', 'Ben' }, names(f));   // Cara: no resume, Dan: not parsed, Eve: needs review
        System.assertEquals(2, CandidateMatchOrchestrator.countNotParsed(f));

        f.workModes = new List<String>{ 'Hybrid' };
        System.assertEquals(new Set<String>{ 'Ben' }, names(f));
        f.workModes = new List<String>{ 'Hybrid', 'Remote' };               // ANY of the chosen values
        System.assertEquals(new Set<String>{ 'Anna', 'Ben' }, names(f));
        f.workModes = new List<String>{ 'On-site' };
        System.assertEquals(0, names(f).size());

        f = new CandidateMatchOrchestrator.Filters(); f.cities = 'austin, paris';
        System.assertEquals(new Set<String>{ 'Anna' }, names(f));
        System.assertEquals(2, CandidateMatchOrchestrator.countNotParsed(f));   // Dan and Eve also live in Austin
        f = new CandidateMatchOrchestrator.Filters(); f.maxSalary = 100000;
        System.assertEquals(new Set<String>{ 'Anna' }, names(f));
        f = new CandidateMatchOrchestrator.Filters(); f.roleTypes = new List<String>{ ROLE_B };
        System.assertEquals(new Set<String>{ 'Ben' }, names(f));

        f = new CandidateMatchOrchestrator.Filters();
        f.workModes = new List<String>{ 'Remote' }; f.cities = 'Austin'; f.maxSalary = 100000;
        System.assertEquals(new Set<String>{ 'Anna' }, names(f));

        f = new CandidateMatchOrchestrator.Filters(); f.workModes = new List<String>{ 'Bogus\' OR Name != \'' };
        System.assertEquals(new Set<String>{ 'Anna', 'Ben' }, names(f));    // invalid values are ignored, never injected
    }

    @IsTest static void filtersPrefillFromJob() {
        Job__c job = [SELECT Work_Modes__c, City__c, Expected_Salary__c, Role_Types__c FROM Job__c];
        CandidateMatchOrchestrator.Filters f = CandidateMatchOrchestrator.fromJob(job);
        System.assertEquals(new List<String>{ 'Remote' }, f.workModes);
        System.assertEquals('Austin', f.cities);
        System.assertEquals(100000, f.maxSalary);
        Map<String, Object> m = CandidateMatcherController.getJobFilters([SELECT Id FROM Job__c].Id);
        System.assertEquals('Austin', m.get('city'));
    }

    @IsTest static void applyFiltersScoresParsedCandidatesOnly() {
        Job__c job = [SELECT Id FROM Job__c];
        PromptRunner.mockByTemplate = new Map<String, String>{
            'Extract_Job_Requirements' => EXTRACT_JSON, 'Score_Candidate_For_Job' => scoreJson(85) };
        CandidateMatchOrchestrator.Filters f = new CandidateMatchOrchestrator.Filters();
        f.workModes = new List<String>{ 'Remote', 'Hybrid' };

        Test.startTest();
        Map<String, Object> started = CandidateMatcherController.startMatching(job.Id, JSON.serialize(f));
        Test.stopTest();                                         // the score batch runs here

        System.assertEquals(2, started.get('matched'));          // Anna, Ben (Dan / Eve are not parsed)
        System.assertEquals(2, started.get('toScore'));
        System.assertEquals(2, started.get('notParsed'));        // Dan and Eve match the filters but cannot be shown
        System.assertEquals(0, [SELECT COUNT() FROM Skill__c]);         // nothing was parsed on this screen

        CandidateMatcherController.Results res = CandidateMatcherController.getResults((String) started.get('runKey'));
        System.assertEquals(2, res.total);
        System.assertEquals(2, res.scored);
        System.assertEquals(true, res.done);
        System.assertEquals(85, res.rows[0].score);
    }

    @IsTest static void alreadyScoredCandidatesAreReused() {
        Job__c job = [SELECT Id FROM Job__c];
        PromptRunner.mockByTemplate = new Map<String, String>{
            'Extract_Job_Requirements' => EXTRACT_JSON, 'Score_Candidate_For_Job' => scoreJson(80) };
        CandidateMatchOrchestrator.Filters f = new CandidateMatchOrchestrator.Filters();
        f.cities = 'Austin';                                      // Anna only
        Test.startTest();
        CandidateMatchOrchestrator.start(job.Id, f);
        Test.stopTest();
        System.assertEquals('Scored', [SELECT Status__c FROM Candidate_Match__c].Status__c);

        CandidateMatchOrchestrator.StartResult again = CandidateMatchOrchestrator.start(job.Id, f);
        System.assertEquals(1, again.cached);
        System.assertEquals(0, again.toScore);
    }

    @IsTest static void resultsAreSortedBestScoreFirstAndFlagRowsToCheck() {
        Job__c job = [SELECT Id FROM Job__c];
        Contact anna = [SELECT Id FROM Contact WHERE LastName = 'Anna'];
        Contact ben = [SELECT Id FROM Contact WHERE LastName = 'Ben'];
        insert new List<Candidate_Match__c>{
            new Candidate_Match__c(Job__c = job.Id, Contact__c = ben.Id, Run_Key__c = 'rk1', Status__c = 'Scored', Score__c = 60, Needs_Review__c = false),
            new Candidate_Match__c(Job__c = job.Id, Contact__c = anna.Id, Run_Key__c = 'rk1', Status__c = 'Scored', Score__c = 90, Needs_Review__c = true)
        };
        CandidateMatcherController.Results out = CandidateMatcherController.getResults('rk1');
        System.assertEquals(true, out.done);
        System.assertEquals(2, out.scored);
        System.assertEquals('Anna', out.rows[0].name);            // best score first
        System.assertEquals(90, out.rows[0].score);
        System.assertEquals('Scored (please check)', out.rows[0].status);
        System.assertEquals(60, out.rows[1].score);
        System.assertEquals('Scored', out.rows[1].status);
    }

    @IsTest static void emptyMatchAndOptions() {
        CandidateMatchOrchestrator.Filters f = new CandidateMatchOrchestrator.Filters();
        f.cities = 'Nowhere';
        PromptRunner.mockResponse = EXTRACT_JSON;
        CandidateMatchOrchestrator.StartResult r = CandidateMatchOrchestrator.start([SELECT Id FROM Job__c].Id, f);
        System.assertEquals(0, r.matched);
        System.assertEquals(0, r.notParsed);
        System.assertEquals(3, CandidateMatcherController.getOptions().get('workModes').size());
        System.assertEquals(true, CandidateMatcherController.getResults(null).done);
    }
}
