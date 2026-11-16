/** Direct scoring (no AiJobRun) and the pre-parse scheduler. */
@IsTest
private class DirectModeTest {
    static final String PARSE_JSON = '{"summary":"Dev","confidence":"high","skills":[{"name":"Java","years":5}],"education":[],'
        + '"employment":[{"employer":"Acme","role":"Engineer","startDate":"2015-01","endDate":null,"description":"x"}]}';
    static final String SCORE_JSON = '{"skillsScore":80,"experienceScore":70,"fitScore":90,"educationScore":70,'
        + '"matchedSkills":["Java"],"missingSkills":[],"fitNote":"nearby","reasoning":"Good fit"}';

    static void mocks() {
        PromptRunner.mockByTemplate = new Map<String, String>{
            'Parse_Resume' => PARSE_JSON, 'Score_Candidate_For_Job' => SCORE_JSON };
    }

    @IsTest static void scoreBatchScoresQueuedCandidates() {
        Job__c job = new Job__c(Name = 'Dev', Job_Description__c = 'Java', City__c = 'Jaipur');
        insert job;
        Contact c = new Contact(LastName = 'Scored', City__c = 'Jaipur', Resume_Parse_Status__c = 'Parsed',
                                Candidate_Profile__c = 'Skills: Java (5y)');
        insert c;
        insert new Candidate_Match__c(Job__c = job.Id, Contact__c = c.Id, Status__c = 'Queued for scoring', Run_Key__c = 'k1');
        mocks();
        Test.startTest();
        Database.executeBatch(new DirectScoreBatch('k1'), 2);
        Test.stopTest();
        Candidate_Match__c m = [SELECT Status__c, Score__c, Matched_Skills__c FROM Candidate_Match__c];
        System.assertEquals('Scored', m.Status__c);
        System.assert(m.Score__c == 78 || m.Score__c == 79);   // (80*45 + 70*25 + 90*20 + 70*10) / 100 = 78.5, rounding mode may differ
        System.assertEquals('Java', m.Matched_Skills__c);
    }

    @IsTest static void scoreBatchMarksFailures() {
        Job__c job = new Job__c(Name = 'Dev', Job_Description__c = 'Java');
        insert job;
        Contact c = new Contact(LastName = 'NoProfile', Resume_Parse_Status__c = 'Parsed');   // parsed but no profile text
        insert c;
        insert new Candidate_Match__c(Job__c = job.Id, Contact__c = c.Id, Status__c = 'Queued for scoring', Run_Key__c = 'k2');
        mocks();
        Test.startTest();
        Database.executeBatch(new DirectScoreBatch('k2'), 2);
        Test.stopTest();
        System.assertEquals('Failed: AI scoring', [SELECT Status__c FROM Candidate_Match__c].Status__c);
    }

    static Id queuedRow(String runKey) {
        Job__c job = new Job__c(Name = 'Dev', Job_Description__c = 'Java');
        insert job;
        Contact c = new Contact(LastName = 'Throttled', Resume_Parse_Status__c = 'Parsed', Candidate_Profile__c = 'Skills: Java');
        insert c;
        Candidate_Match__c m = new Candidate_Match__c(Job__c = job.Id, Contact__c = c.Id,
            Status__c = 'Queued for scoring', Run_Key__c = runKey);
        insert m;
        return m.Id;
    }

    @IsTest static void aiErrorFailsImmediatelyAndShowsTheReason() {
        Id mid = queuedRow('k3');
        PromptRunner.mockError = 'API request failed: 429 Too Many Requests';
        Test.startTest();
        Database.executeBatch(new DirectScoreBatch('k3'), 2);
        Test.stopTest();
        Candidate_Match__c m = [SELECT Status__c, Reasoning__c FROM Candidate_Match__c WHERE Id = :mid];
        System.assertEquals('Failed: AI scoring', m.Status__c);
        System.assert(m.Reasoning__c.contains('429 Too Many Requests'));
    }

    @IsTest static void preParseSchedulerReadsPendingResumes() {
        Contact c = new Contact(LastName = 'Reader');
        insert c;
        insert new ContentVersion(Title = 'r', PathOnClient = 'r.pdf', VersionData = Blob.valueOf('x'), FirstPublishLocationId = c.Id);
        mocks();
        Test.startTest();
        Id jobId = ResumeParseScheduler.runNow();      // the batch runs at stopTest
        Test.stopTest();
        System.assertNotEquals(null, jobId);
        System.assertEquals('Parsed', [SELECT Resume_Parse_Status__c FROM Contact WHERE Id = :c.Id].Resume_Parse_Status__c);
        System.assertEquals(1, [SELECT COUNT() FROM Employment_History__c WHERE Contact__c = :c.Id AND Role__c = 'Engineer']);
    }
}
