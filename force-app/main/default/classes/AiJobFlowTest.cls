/** Tests the AiJobRun / AiJobRunItem path with the platform calls stubbed out. */
@IsTest
private class AiJobFlowTest {
    static final String PARSE_JSON = '{"summary":"Dev","confidence":"high","skills":[{"name":"Java","years":5},{"name":"Apex","years":3}],'
        + '"education":[{"institution":"MIT","degree":"BS","fieldOfStudy":"CS","startDate":"2010","endDate":"2014"}],'
        + '"employment":[{"employer":"Acme","role":"Engineer","startDate":"2015-01","endDate":null,"description":"Built things"}]}';

    static String envelope(String text) { return JSON.serialize(new Map<String, Object>{ 'promptResponse' => text }); }

    static AiJobGateway.ItemResult result(String itemId, String status, String text) {
        AiJobGateway.ItemResult r = new AiJobGateway.ItemResult();
        r.itemId = itemId; r.status = status;
        r.response = text == null ? null : envelope(text);
        r.errorMessage = status == 'Failed' ? 'model error' : null;
        return r;
    }

    static Contact pdfContact() {
        Contact c = new Contact(LastName = 'T');
        insert c;
        insert new ContentVersion(Title = 'r', PathOnClient = 'r.pdf', VersionData = Blob.valueOf('x'), FirstPublishLocationId = c.Id);
        return c;
    }

    static List<AI_Item_Map__c> maps(String kind) {
        return [SELECT Id, Item_Id__c, Run_Id__c, Kind__c, Contact__c, Job__c FROM AI_Item_Map__c WHERE Kind__c = :kind];
    }

    @IsTest static void resumeRunEndToEnd() {
        Contact c = pdfContact();
        AiJobGateway.testMode = true;
        System.assertEquals(1, ResumeJobService.startFor(new List<Id>{ c.Id }));
        System.assertEquals('Processing', [SELECT Resume_Parse_Status__c FROM Contact WHERE Id = :c.Id].Resume_Parse_Status__c);

        List<AI_Item_Map__c> ms = maps('RESUME');
        Integer n = AiJobResultService.apply(ms, new Map<String, AiJobGateway.ItemResult>{
            ms[0].Item_Id__c => result(ms[0].Item_Id__c, 'Completed', PARSE_JSON) });
        System.assertEquals(1, n);
        Contact r = [SELECT Resume_Parse_Status__c, Total_Experience_Years__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals('Parsed', r.Resume_Parse_Status__c);
        System.assert(r.Total_Experience_Years__c > 5);
        System.assertEquals(true, [SELECT Processed__c FROM AI_Item_Map__c].Processed__c);
    }

    @IsTest static void failedAndGarbageItemsAreReported() {
        Contact a = pdfContact();
        Contact b = pdfContact();
        AiJobGateway.testMode = true;
        ResumeJobService.startFor(new List<Id>{ a.Id, b.Id });
        List<AI_Item_Map__c> ms = maps('RESUME');
        Map<String, AiJobGateway.ItemResult> res = new Map<String, AiJobGateway.ItemResult>();
        for (AI_Item_Map__c m : ms) {
            res.put(m.Item_Id__c, m.Contact__c == a.Id ? result(m.Item_Id__c, 'Failed', null)
                                                         : result(m.Item_Id__c, 'Completed', 'not json'));
        }
        AiJobResultService.apply(ms, res);
        System.assertEquals('Failed', [SELECT Resume_Parse_Status__c FROM Contact WHERE Id = :a.Id].Resume_Parse_Status__c);
        System.assertEquals('Failed', [SELECT Resume_Parse_Status__c FROM Contact WHERE Id = :b.Id].Resume_Parse_Status__c);
    }

    @IsTest static void runningItemsAreLeftForLater() {
        Contact c = pdfContact();
        AiJobGateway.testMode = true;
        ResumeJobService.startFor(new List<Id>{ c.Id });
        List<AI_Item_Map__c> ms = maps('RESUME');
        System.assertEquals(0, AiJobResultService.apply(ms, new Map<String, AiJobGateway.ItemResult>{
            ms[0].Item_Id__c => result(ms[0].Item_Id__c, 'InProgress', null) }));
        System.assertEquals(false, [SELECT Processed__c FROM AI_Item_Map__c].Processed__c);
    }

    @IsTest static void parsedResumeFlowsStraightIntoScoring() {
        Job__c job = new Job__c(Name = 'Dev', Job_Description__c = '<p>Java dev</p>', City__c = 'Austin');
        insert job;
        Contact c = pdfContact();
        update new Contact(Id = c.Id, City__c = 'Austin');
        insert new Candidate_Match__c(Job__c = job.Id, Contact__c = c.Id, Status__c = 'Reading resume', Run_Key__c = 'k1');
        AiJobGateway.testMode = true;
        ResumeJobService.startFor(new List<Id>{ c.Id });

        List<AI_Item_Map__c> rm = maps('RESUME');
        AiJobResultService.apply(rm, new Map<String, AiJobGateway.ItemResult>{
            rm[0].Item_Id__c => result(rm[0].Item_Id__c, 'Completed', PARSE_JSON) });
        System.assertEquals('Scoring', [SELECT Status__c FROM Candidate_Match__c].Status__c);   // chained automatically

        List<AI_Item_Map__c> mm = maps('MATCH');
        System.assertEquals(1, mm.size());
        String score = '{"skillsScore":90,"experienceScore":80,"fitScore":100,"educationScore":70,'
            + '"matchedSkills":["Java","Kubernetes"],"missingSkills":["SQL"],"fitNote":"Lives in Austin","reasoning":"Good fit"}';
        AiJobResultService.apply(mm, new Map<String, AiJobGateway.ItemResult>{
            mm[0].Item_Id__c => result(mm[0].Item_Id__c, 'Completed', score) });

        Candidate_Match__c m = [SELECT Status__c, Score__c, Matched_Skills__c, Needs_Review__c FROM Candidate_Match__c];
        System.assertEquals('Scored', m.Status__c);
        System.assertEquals(88, m.Score__c);                      // (90*45 + 80*25 + 100*20 + 70*10) / 100 = 87.5, rounded
        System.assertEquals('Java', m.Matched_Skills__c);         // Kubernetes is not in the profile
        System.assertEquals(true, m.Needs_Review__c);
    }

    @IsTest static void reviewResumeIsNotScored() {
        Job__c job = new Job__c(Name = 'Dev', Job_Description__c = 'x');
        insert job;
        Contact c = pdfContact();
        insert new Candidate_Match__c(Job__c = job.Id, Contact__c = c.Id, Status__c = 'Reading resume', Run_Key__c = 'k1');
        AiJobGateway.testMode = true;
        ResumeJobService.startFor(new List<Id>{ c.Id });
        List<AI_Item_Map__c> rm = maps('RESUME');
        AiJobResultService.apply(rm, new Map<String, AiJobGateway.ItemResult>{
            rm[0].Item_Id__c => result(rm[0].Item_Id__c, 'Completed',
                '{"summary":"x","confidence":"low","skills":[],"education":[],"employment":[]}') });
        System.assertEquals('Needs review (resume)', [SELECT Status__c FROM Candidate_Match__c].Status__c);
        System.assertEquals(0, maps('MATCH').size());
    }

    @IsTest static void failedScoringItemIsShown() {
        Job__c job = new Job__c(Name = 'Dev', Job_Description__c = 'x');
        insert job;
        Contact c = new Contact(LastName = 'P', Resume_Parse_Status__c = 'Parsed', Candidate_Profile__c = 'Skills: Java');
        insert c;
        insert new Candidate_Match__c(Job__c = job.Id, Contact__c = c.Id, Status__c = 'Queued for scoring', Run_Key__c = 'k1');
        AiJobGateway.testMode = true;
        System.assertEquals(1, CandidateMatchService.submitScoring(job.Id, new List<Id>{ c.Id }));
        System.assertEquals(0, CandidateMatchService.submitScoring(job.Id, new List<Id>{ c.Id }));   // already in flight
        List<AI_Item_Map__c> mm = maps('MATCH');
        AiJobResultService.apply(mm, new Map<String, AiJobGateway.ItemResult>{
            mm[0].Item_Id__c => result(mm[0].Item_Id__c, 'Failed', null) });
        System.assertEquals('Failed: AI scoring', [SELECT Status__c FROM Candidate_Match__c].Status__c);
    }

    @IsTest static void fitCountsOnlyWhenJobSpecifiesIt() {
        Job__c job = new Job__c(Name = 'Dev', Job_Description__c = 'x');
        insert job;
        Contact c = new Contact(LastName = 'Cand');
        insert c;
        CandidateMatchService.ScoreResult r = new CandidateMatchService.ScoreResult();
        r.skillsScore = 100; r.experienceScore = 100; r.fitScore = 0; r.educationScore = 100;
        r.matchedSkills = new List<String>{ 'Java' }; r.reasoning = 'Strong skills'; r.fitNote = 'Far away';

        Candidate_Match__c withFit = CandidateMatchService.buildMatch(job.Id, c.Id, r, 'Skills: Java', null, true);
        System.assertEquals(80, withFit.Score__c);               // (4500+2500+0+1000)/100
        System.assert(withFit.Reasoning__c.contains('Far away'));
        Candidate_Match__c noFit = CandidateMatchService.buildMatch(job.Id, c.Id, r, 'Skills: Java', null, false);
        System.assertEquals(100, noFit.Score__c);
        System.assertEquals(null, noFit.Fit_Score__c);
    }

    @IsTest static void unverifiedHighScoreIsCapped() {
        Job__c job = new Job__c(Name = 'Dev', Job_Description__c = 'x');
        insert job;
        Contact c = new Contact(LastName = 'Cand');
        insert c;
        CandidateMatchService.ScoreResult r = new CandidateMatchService.ScoreResult();
        r.skillsScore = 95; r.experienceScore = 95; r.fitScore = 95; r.educationScore = 95;
        r.matchedSkills = new List<String>{ 'Kubernetes' }; r.reasoning = 'Great';
        Candidate_Match__c m = CandidateMatchService.buildMatch(job.Id, c.Id, r, 'Skills: Java', null, true);
        System.assertEquals(50, m.Score__c);
        System.assertEquals(true, m.Needs_Review__c);
    }

    @IsTest static void sweeperFindsUnprocessedRuns() {
        Contact c = pdfContact();
        AiJobGateway.testMode = true;
        ResumeJobService.startFor(new List<Id>{ c.Id });
        AiJobGateway.testResults = new Map<String, AiJobGateway.ItemResult>();
        Test.startTest();
        System.assertEquals(1, AiJobSweeper.sweep());
        Test.stopTest();
    }

    @IsTest static void resultBatchProcessesARun() {
        Contact c = pdfContact();
        AiJobGateway.testMode = true;
        ResumeJobService.startFor(new List<Id>{ c.Id });
        List<AI_Item_Map__c> ms = maps('RESUME');
        AiJobGateway.testResults = new Map<String, AiJobGateway.ItemResult>{
            ms[0].Item_Id__c => result(ms[0].Item_Id__c, 'Completed', PARSE_JSON) };
        Test.startTest();
        Database.executeBatch(new AiJobResultBatch(ms[0].Run_Id__c), 25);
        Test.stopTest();
        System.assertEquals('Parsed', [SELECT Resume_Parse_Status__c FROM Contact WHERE Id = :c.Id].Resume_Parse_Status__c);
    }
}