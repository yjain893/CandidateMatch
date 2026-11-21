/** The extra endpoints used by the candidateMatcherV2 component: the live match count and the result rows. */
@IsTest
private class CandidateMatcherV2ControllerTest {

    /** The org's own Role Types values: the picklist is restricted, and an org can hold other values than the ones this test was first written with. */
    static List<String> activeRoles() {
        List<String> out = new List<String>();
        for (Schema.PicklistEntry e : Contact.Role_Types__c.getDescribe().getPicklistValues()) { if (e.isActive()) { out.add(e.getValue()); } }
        return out;
    }
    static final List<String> ROLES = activeRoles();
    static final String ROLE_A = ROLES[0];      // the role of most candidates below
    static final String ROLE_B = ROLES[1];      // only Ben has it besides ROLE_A
    static final String ROLE_C = ROLES[2];      // only Eve has it

    @TestSetup static void setup() {
        insert new List<Contact>{
            new Contact(LastName = 'Anna', Has_Resume__c = true, Work_Modes__c = 'Remote', City__c = 'Austin', Expected_Salary__c = 90000,
                        Role_Types__c = ROLE_A, Resume_Parse_Status__c = 'Parsed', Candidate_Profile__c = 'Skills: Java',
                        Total_Experience_Years__c = 8.5),
            new Contact(LastName = 'Ben', Has_Resume__c = true, Work_Modes__c = 'Hybrid;Remote', City__c = 'London', Expected_Salary__c = 150000,
                        Role_Types__c = ROLE_A + ';' + ROLE_B, Resume_Parse_Status__c = 'Parsed', Candidate_Profile__c = 'Skills: Java, Apex'),
            new Contact(LastName = 'Dan', Has_Resume__c = true, Work_Modes__c = 'Remote', City__c = 'Austin', Expected_Salary__c = 70000,
                        Role_Types__c = ROLE_A),                                          // resume not parsed yet
            new Contact(LastName = 'Eve', Has_Resume__c = true, Work_Modes__c = 'On-site', City__c = 'Paris', Expected_Salary__c = 70000,
                        Role_Types__c = ROLE_C, Resume_Parse_Status__c = 'Parsed', Candidate_Profile__c = 'Skills: Figma')
        };
        insert new Job__c(Name = 'Dev', Job_Description__c = '<p>Java developer</p>');
        Contact anna = [SELECT Id FROM Contact WHERE LastName = 'Anna'];
        insert new ContentVersion(Title = 'Anna_Resume', PathOnClient = 'Anna_Resume.pdf', VersionData = Blob.valueOf('%PDF-1.4 x'),
                                  FirstPublishLocationId = anna.Id);
        // attaching a PDF resets the parse status (the file trigger wants the resume re-read), so mark her as parsed again
        update new Contact(Id = anna.Id, Resume_Parse_Status__c = 'Parsed');
    }

    static String filters(List<String> modes, String cities, Decimal maxSalary, List<String> roles) {
        CandidateMatchOrchestrator.Filters f = new CandidateMatchOrchestrator.Filters();
        f.workModes = modes; f.cities = cities; f.maxSalary = maxSalary; f.roleTypes = roles;
        return JSON.serialize(f);
    }

    // ----------------------------------------------------------------------------------------------- countMatches

    @IsTest static void countCountsParsedCandidatesAndTheNotParsedOnesSeparately() {
        CandidateMatcherV2Controller.MatchCount c = CandidateMatcherV2Controller.countMatches(
            filters(new List<String>{ 'Remote' }, null, null, null));
        System.assertEquals(2, c.matched, 'Anna and Ben are parsed and Remote');
        System.assertEquals(1, c.notParsed, 'Dan is Remote but not parsed yet');
        System.assertEquals(false, c.capped);
        System.assertEquals(200, c.cap);
    }

    @IsTest static void countFollowsEveryFilter() {
        System.assertEquals(1, CandidateMatcherV2Controller.countMatches(filters(null, 'Austin', null, null)).matched);
        System.assertEquals(2, CandidateMatcherV2Controller.countMatches(filters(null, 'Austin, London', null, null)).matched);
        System.assertEquals(2, CandidateMatcherV2Controller.countMatches(filters(null, null, 100000, null)).matched, 'Anna (90000) and Eve (70000); Ben asks for 150000');
        System.assertEquals(1, CandidateMatcherV2Controller.countMatches(filters(null, null, null, new List<String>{ ROLE_B })).matched);
        System.assertEquals(0, CandidateMatcherV2Controller.countMatches(filters(new List<String>{ 'On-site' }, 'Austin', null, null)).matched);
    }

    @IsTest static void countWithoutFiltersCountsEveryParsedResume() {
        CandidateMatcherV2Controller.MatchCount a = CandidateMatcherV2Controller.countMatches(null);
        CandidateMatcherV2Controller.MatchCount b = CandidateMatcherV2Controller.countMatches('{}');
        System.assertEquals(3, a.matched);
        System.assertEquals(3, b.matched);
        System.assertEquals(1, a.notParsed);
    }

    @IsTest static void countReportsBadInputAsAFriendlyError() {
        try {
            CandidateMatcherV2Controller.countMatches('not json');
            System.assert(false, 'expected an AuraHandledException');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }
    }

    // ------------------------------------------------------------------------------- skills and date available

    static String skillFilters(List<String> selected, List<String> options, Integer withinDays) {
        CandidateMatchOrchestrator.Filters f = new CandidateMatchOrchestrator.Filters();
        f.skills = selected; f.skillOptions = options; f.availableWithinDays = withinDays;
        return JSON.serialize(f);
    }

    /** Anna: Apex, SOQL, available today. Ben: Apex, in 10 days. Eve: SOQL, Flow, no date. Dan (resume not parsed): Apex, today. */
    static void addSkillsAndDates() {
        Map<String, Id> ids = new Map<String, Id>();
        for (Contact c : [SELECT Id, LastName FROM Contact]) { ids.put(c.LastName, c.Id); }
        update new List<Contact>{
            new Contact(Id = ids.get('Anna'), Date_Available__c = Date.today()),
            new Contact(Id = ids.get('Ben'), Date_Available__c = Date.today().addDays(10)),
            new Contact(Id = ids.get('Dan'), Date_Available__c = Date.today())
        };
        insert new List<Skill__c>{
            skill('Apex', ids.get('Anna')), skill('SOQL', ids.get('Anna')),
            skill('Apex', ids.get('Ben')),
            skill('SOQL', ids.get('Eve')), skill('Flow', ids.get('Eve')),
            skill('Apex', ids.get('Dan'))
        };
    }

    static Skill__c skill(String name, Id contactId) {
        return new Skill__c(Name = name, Name_Key__c = name.toLowerCase(), Contact__c = contactId);
    }

    static CandidateMatcherV2Controller.SkillCount skillOf(CandidateMatcherV2Controller.MatchCount c, String name) {
        for (CandidateMatcherV2Controller.SkillCount s : c.skills) { if (s.name == name) { return s; } }
        return null;
    }

    static List<Integer> dateCounts(CandidateMatcherV2Controller.MatchCount c) {
        List<Integer> out = new List<Integer>();
        for (CandidateMatcherV2Controller.DateCount d : c.dates) { out.add(d.count); }
        return out;
    }

    @IsTest static void everySkillAndDateShowsHowManyCandidatesWouldBeLeftIfItWereAdded() {
        addSkillsAndDates();
        List<String> options = new List<String>{ 'Apex', 'SOQL', 'Flow' };
        CandidateMatcherV2Controller.MatchCount c = CandidateMatcherV2Controller.countMatches(skillFilters(null, options, null));

        System.assertEquals(true, c.facets);
        System.assertEquals(false, c.tooBroad);
        System.assertEquals(3, c.pool, 'Anna, Ben and Eve are parsed; Dan is not');
        System.assertEquals(3, c.matched);
        System.assertEquals(2, skillOf(c, 'Apex').count, 'Anna and Ben');
        System.assertEquals(2, skillOf(c, 'SOQL').count, 'Anna and Eve');
        System.assertEquals(1, skillOf(c, 'Flow').count, 'Eve');
        System.assertEquals(false, skillOf(c, 'Apex').selected);
        System.assertEquals(new List<Integer>{ 1, 2, 2, 2 }, dateCounts(c), 'now: Anna. 2 weeks: Anna and Ben. Eve has no date, so she is never counted');
        System.assertEquals(CandidateMatcherV2Controller.DATE_WINDOWS.size(), c.dates.size());
    }

    @IsTest static void selectingASkillNarrowsEveryOtherNumber() {
        addSkillsAndDates();
        List<String> options = new List<String>{ 'Apex', 'SOQL', 'Flow' };
        CandidateMatcherV2Controller.MatchCount c = CandidateMatcherV2Controller.countMatches(
            skillFilters(new List<String>{ 'Apex' }, options, null));

        System.assertEquals(2, c.matched, 'Anna and Ben have Apex');
        System.assertEquals(2, c.skillMatched);
        System.assertEquals(true, skillOf(c, 'Apex').selected);
        System.assertEquals(3, skillOf(c, 'Apex').count, 'a selected skill shows what removing it would give: Eve would join');
        System.assertEquals(1, skillOf(c, 'SOQL').count, 'only Anna has Apex and SOQL');
        System.assertEquals(0, skillOf(c, 'Flow').count);
        System.assertEquals(new List<Integer>{ 1, 2, 2, 2 }, dateCounts(c));
    }

    @IsTest static void theDateWindowNarrowsTheMatchesButNotTheDateTiles() {
        addSkillsAndDates();
        List<String> options = new List<String>{ 'Apex', 'SOQL', 'Flow' };
        CandidateMatcherV2Controller.MatchCount c = CandidateMatcherV2Controller.countMatches(
            skillFilters(new List<String>{ 'Apex' }, options, 0));

        System.assertEquals(1, c.matched, 'only Anna has Apex and is available now');
        System.assertEquals(2, c.skillMatched, 'before the date: Anna and Ben');
        System.assertEquals(1, skillOf(c, 'Apex').count, 'Eve has no date, so removing Apex would not let her in');
        System.assertEquals(1, skillOf(c, 'SOQL').count);
        System.assertEquals(new List<Integer>{ 1, 2, 2, 2 }, dateCounts(c), 'the tiles keep counting against the skills only');
    }

    @IsTest static void aCandidateWithoutADateIsLeftOutOnceAWindowIsChosen() {
        addSkillsAndDates();
        List<String> options = new List<String>{ 'Apex', 'SOQL', 'Flow' };
        System.assertEquals(2, CandidateMatcherV2Controller.countMatches(skillFilters(null, options, 62)).matched, 'Eve has no date');
        System.assertEquals(3, CandidateMatcherV2Controller.countMatches(skillFilters(null, options, null)).matched);
    }

    @IsTest static void theDateFilterAloneIsCountedWithoutLookingAtSkills() {
        addSkillsAndDates();
        CandidateMatcherV2Controller.MatchCount c = CandidateMatcherV2Controller.countMatches(skillFilters(null, null, 0));
        System.assertEquals(false, c.facets);
        System.assertEquals(1, c.matched, 'Anna is parsed and available now');
        System.assertEquals(1, c.notParsed, 'Dan is available now but his resume is not parsed');
    }

    @IsTest static void whenTooManyCandidatesFitTheOtherFiltersSkillsAreNotChecked() {
        addSkillsAndDates();
        CandidateMatchOrchestrator.poolLimitOverride = 2;                 // the pool is 3
        List<String> options = new List<String>{ 'Apex', 'SOQL' };

        CandidateMatcherV2Controller.MatchCount withSkill = CandidateMatcherV2Controller.countMatches(
            skillFilters(new List<String>{ 'Apex' }, options, null));
        System.assertEquals(true, withSkill.tooBroad);
        System.assertEquals(false, withSkill.facets);
        System.assertEquals(null, withSkill.matched, 'cannot be counted without checking skills');
        System.assertEquals(3, withSkill.pool);
        System.assertEquals(false, withSkill.capped);

        CandidateMatcherV2Controller.MatchCount noSkill = CandidateMatcherV2Controller.countMatches(skillFilters(null, options, null));
        System.assertEquals(true, noSkill.tooBroad);
        System.assertEquals(3, noSkill.matched, 'without a selected skill the count is plain SOQL');
    }

    @IsTest static void findCandidatesChecksTheSelectedSkillsAndTheDate() {
        addSkillsAndDates();
        CandidateMatchOrchestrator.Filters f = new CandidateMatchOrchestrator.Filters();
        f.skills = new List<String>{ 'Apex', ' SOQL ' };                  // spelling and spacing do not matter
        List<Contact> got = CandidateMatchOrchestrator.findCandidates(f, 200);
        System.assertEquals(1, got.size());
        System.assertEquals('Anna', got[0].Name);

        f.skills = new List<String>{ 'apex' };
        f.availableWithinDays = 14;
        got = CandidateMatchOrchestrator.findCandidates(f, 200);
        System.assertEquals(2, got.size());
        System.assertEquals('Anna', got[0].Name, 'sorted by name');
        System.assertEquals('Ben', got[1].Name);

        f.availableWithinDays = 5;
        System.assertEquals(1, CandidateMatchOrchestrator.findCandidates(f, 200).size(), 'Ben is only free in 10 days');

        f.skills = new List<String>{ 'Rust' };
        System.assertEquals(0, CandidateMatchOrchestrator.findCandidates(f, 200).size());
    }

    @IsTest static void findCandidatesReturnsOneMoreThanTheCapSoTheScreenCanSayThereAreMore() {
        addSkillsAndDates();
        CandidateMatchOrchestrator.Filters f = new CandidateMatchOrchestrator.Filters();
        f.skills = new List<String>{ 'Apex' };
        System.assertEquals(2, CandidateMatchOrchestrator.findCandidates(f, 1).size());
    }

    @IsTest static void findCandidatesRefusesToCheckSkillsWhenTheOtherFiltersLeaveTooMany() {
        addSkillsAndDates();
        CandidateMatchOrchestrator.poolLimitOverride = 2;
        CandidateMatchOrchestrator.Filters f = new CandidateMatchOrchestrator.Filters();
        f.skills = new List<String>{ 'Apex' };
        try {
            CandidateMatchOrchestrator.findCandidates(f, 200);
            System.assert(false, 'expected a FilterException');
        } catch (CandidateMatchOrchestrator.FilterException e) {
            System.assert(e.getMessage().contains('Narrow'));
        }
    }

    // ------------------------------------------------------------------------------------------------ job skills

    @IsTest static void jobSkillsAreListedOnceRequiredFirst() {
        Job__c job = [SELECT Id FROM Job__c];
        job.Required_Skills__c = 'Apex, SOQL, apex , Flow';
        job.Nice_To_Have_Skills__c = 'Flow, Experience Cloud, Git';
        update job;
        CandidateMatcherV2Controller.JobSkills s = CandidateMatcherV2Controller.getJobSkills(job.Id);
        System.assertEquals(new List<String>{ 'Apex', 'SOQL', 'Flow' }, s.required, 'the repeat of Apex is dropped');
        System.assertEquals(new List<String>{ 'Experience Cloud', 'Git' }, s.niceToHave, 'Flow is already required');
    }

    @IsTest static void longSkillListsAreCutToWhatFitsThePanel() {
        List<String> required = new List<String>();
        List<String> nice = new List<String>();
        for (Integer i = 0; i < 20; i++) { required.add('Required ' + i); nice.add('Nice ' + i); }
        Job__c job = [SELECT Id FROM Job__c];
        job.Required_Skills__c = String.join(required, ', ');
        job.Nice_To_Have_Skills__c = String.join(nice, ', ');
        update job;
        CandidateMatcherV2Controller.JobSkills s = CandidateMatcherV2Controller.getJobSkills(job.Id);
        System.assertEquals(CandidateMatcherV2Controller.MAX_REQUIRED, s.required.size());
        System.assertEquals(CandidateMatcherV2Controller.MAX_NICE, s.niceToHave.size());
        System.assertEquals('Required 0', s.required[0]);
    }

    @IsTest static void aJobWithoutExtractedSkillsGivesEmptyLists() {
        Job__c job = [SELECT Id FROM Job__c];
        CandidateMatcherV2Controller.JobSkills s = CandidateMatcherV2Controller.getJobSkills(job.Id);
        System.assertEquals(0, s.required.size());
        System.assertEquals(0, s.niceToHave.size());
    }

    // ------------------------------------------------------------------------------------------------ getResults

    static void addMatches(String runKey) {
        Job__c job = [SELECT Id FROM Job__c];
        Map<String, Id> ids = new Map<String, Id>();
        for (Contact c : [SELECT Id, LastName FROM Contact]) { ids.put(c.LastName, c.Id); }
        insert new List<Candidate_Match__c>{
            new Candidate_Match__c(Job__c = job.Id, Contact__c = ids.get('Ben'), Run_Key__c = runKey, Status__c = 'Scored', Score__c = 60,
                Skills_Score__c = 55, Experience_Score__c = 65, Education_Score__c = 70, Needs_Review__c = true,
                Matched_Skills__c = 'Java', Missing_Skills__c = 'Apex, SOQL', Reasoning__c = 'Mixed'),
            new Candidate_Match__c(Job__c = job.Id, Contact__c = ids.get('Anna'), Run_Key__c = runKey, Status__c = 'Scored', Score__c = 90,
                Skills_Score__c = 95, Experience_Score__c = 88, Education_Score__c = 80, Needs_Review__c = false,
                Matched_Skills__c = 'Java ,Apex', Missing_Skills__c = '', Reasoning__c = 'Strong match'),
            new Candidate_Match__c(Job__c = job.Id, Contact__c = ids.get('Dan'), Run_Key__c = runKey, Status__c = 'Queued for scoring'),
            new Candidate_Match__c(Job__c = job.Id, Contact__c = ids.get('Eve'), Run_Key__c = runKey, Status__c = 'Failed: AI scoring',
                Reasoning__c = 'Error: boom')
        };
    }

    @IsTest static void tiedScoresAreOrderedBySkillsThenExperienceNotByName() {
        Job__c job = [SELECT Id FROM Job__c];
        Map<String, Id> ids = new Map<String, Id>();
        for (Contact c : [SELECT Id, LastName FROM Contact]) { ids.put(c.LastName, c.Id); }
        insert new List<Candidate_Match__c>{
            new Candidate_Match__c(Job__c = job.Id, Contact__c = ids.get('Anna'), Run_Key__c = 'rkTie', Status__c = 'Scored', Score__c = 90,
                Skills_Score__c = 95, Experience_Score__c = 99, Education_Score__c = 80),
            new Candidate_Match__c(Job__c = job.Id, Contact__c = ids.get('Ben'), Run_Key__c = 'rkTie', Status__c = 'Scored', Score__c = 90,
                Skills_Score__c = 100, Experience_Score__c = 90, Education_Score__c = 80),
            new Candidate_Match__c(Job__c = job.Id, Contact__c = ids.get('Dan'), Run_Key__c = 'rkTie', Status__c = 'Scored', Score__c = 90,
                Skills_Score__c = 100, Experience_Score__c = 96, Education_Score__c = 80) };

        List<CandidateMatcherV2Controller.Row> rows = CandidateMatcherV2Controller.getResults('rkTie').rows;
        System.assertEquals('Dan', rows[0].name, 'same score, best skills, best experience');
        System.assertEquals('Ben', rows[1].name, 'same score and skills, less experience');
        System.assertEquals('Anna', rows[2].name, 'first by name, but the weakest skills');
    }

    @IsTest static void resultsComeBackBestFirstWithEverythingTheScreenNeeds() {
        addMatches('rk1');
        CandidateMatcherV2Controller.Results res = CandidateMatcherV2Controller.getResults('rk1');

        System.assertEquals(4, res.total);
        System.assertEquals(2, res.scored);
        System.assertEquals(1, res.failed);
        System.assertEquals(1, res.inProgress);
        System.assertEquals(false, res.done, 'Dan is still waiting');
        System.assertEquals('Anna', res.rows[0].name);                    // best score first
        System.assertEquals('Ben', res.rows[1].name);

        CandidateMatcherV2Controller.Row anna = res.rows[0];
        System.assertEquals(90, anna.score);
        System.assertEquals(95, anna.skillsScore);
        System.assertEquals(88, anna.experienceScore);
        System.assertEquals(80, anna.educationScore);
        System.assertEquals(8.5, anna.experienceYears);
        System.assertEquals(90000, anna.salary);
        System.assertEquals('Austin', anna.city);
        System.assertEquals(new List<String>{ 'Java', 'Apex' }, anna.matched, 'skills are split and trimmed');
        System.assertEquals(0, anna.missing.size());
        System.assertEquals('Strong match', anna.reasoning);
        System.assertEquals(false, anna.needsReview);
        System.assertEquals('/lightning/r/Contact/' + anna.contactId + '/view', anna.nameUrl);

        CandidateMatcherV2Controller.Row ben = res.rows[1];
        System.assertEquals(true, ben.needsReview);
        System.assertEquals(new List<String>{ 'Apex', 'SOQL' }, ben.missing);
        System.assertEquals(null, ben.experienceYears, 'no experience recorded');
    }

    @IsTest static void resumeFileIdIsOnlySetForContactsThatHaveAPdf() {
        addMatches('rk2');
        Map<String, CandidateMatcherV2Controller.Row> byName = new Map<String, CandidateMatcherV2Controller.Row>();
        for (CandidateMatcherV2Controller.Row r : CandidateMatcherV2Controller.getResults('rk2').rows) { byName.put(r.name, r); }
        System.assertNotEquals(null, byName.get('Anna').resumeDocId);
        System.assertEquals(null, byName.get('Ben').resumeDocId);
        System.assertEquals([SELECT ContentDocumentId FROM ContentVersion WHERE Title = 'Anna_Resume'].ContentDocumentId, byName.get('Anna').resumeDocId);
    }

    @IsTest static void pendingAndFailedRowsComeThroughWithTheirStatus() {
        addMatches('rk3');
        Map<String, CandidateMatcherV2Controller.Row> byName = new Map<String, CandidateMatcherV2Controller.Row>();
        for (CandidateMatcherV2Controller.Row r : CandidateMatcherV2Controller.getResults('rk3').rows) { byName.put(r.name, r); }
        System.assertEquals('Queued for scoring', byName.get('Dan').status);
        System.assertEquals(null, byName.get('Dan').score);
        System.assertEquals('Failed: AI scoring', byName.get('Eve').status);
        System.assertEquals('Error: boom', byName.get('Eve').reasoning);
    }

    @IsTest static void runIsDoneWhenNothingIsWaitingAnymore() {
        addMatches('rk4');
        delete [SELECT Id FROM Candidate_Match__c WHERE Run_Key__c = 'rk4' AND Status__c = 'Queued for scoring'];
        System.assertEquals(true, CandidateMatcherV2Controller.getResults('rk4').done);
    }

    @IsTest static void blankOrUnknownRunKeyGivesAnEmptyFinishedResult() {
        CandidateMatcherV2Controller.Results a = CandidateMatcherV2Controller.getResults(null);
        CandidateMatcherV2Controller.Results b = CandidateMatcherV2Controller.getResults('does-not-exist');
        System.assertEquals(0, a.rows.size());
        System.assertEquals(true, a.done);
        System.assertEquals(0, b.total);
        System.assertEquals(true, b.done);
    }

    @IsTest static void splitSkillsHandlesBlanksAndSpacing() {
        System.assertEquals(0, CandidateMatcherV2Controller.splitSkills(null).size());
        System.assertEquals(0, CandidateMatcherV2Controller.splitSkills('').size());
        System.assertEquals(new List<String>{ 'A', 'B', 'C' }, CandidateMatcherV2Controller.splitSkills(' A ,B,, C '));
    }
}
