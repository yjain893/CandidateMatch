/** The extra endpoints used by the candidateMatcherV2 component: the live match count and the result rows. */
@IsTest
private class CandidateMatcherV2ControllerTest {

    @TestSetup static void setup() {
        insert new List<Contact>{
            new Contact(LastName = 'Anna', Has_Resume__c = true, Work_Modes__c = 'Remote', City__c = 'Austin', Expected_Salary__c = 90000,
                        Role_Types__c = 'Developer', Resume_Parse_Status__c = 'Parsed', Candidate_Profile__c = 'Skills: Java',
                        Total_Experience_Years__c = 8.5),
            new Contact(LastName = 'Ben', Has_Resume__c = true, Work_Modes__c = 'Hybrid;Remote', City__c = 'London', Expected_Salary__c = 150000,
                        Role_Types__c = 'Developer;Architect', Resume_Parse_Status__c = 'Parsed', Candidate_Profile__c = 'Skills: Java, Apex'),
            new Contact(LastName = 'Dan', Has_Resume__c = true, Work_Modes__c = 'Remote', City__c = 'Austin', Expected_Salary__c = 70000,
                        Role_Types__c = 'Developer'),                                     // resume not parsed yet
            new Contact(LastName = 'Eve', Has_Resume__c = true, Work_Modes__c = 'On-site', City__c = 'Paris', Expected_Salary__c = 70000,
                        Role_Types__c = 'Designer', Resume_Parse_Status__c = 'Parsed', Candidate_Profile__c = 'Skills: Figma')
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
        System.assertEquals(1, CandidateMatcherV2Controller.countMatches(filters(null, null, null, new List<String>{ 'Architect' })).matched);
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
