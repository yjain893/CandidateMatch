@IsTest
private class JobRequirementsBatchTest {
    private static final String EXTRACT_JSON = '{"requiredSkills":["Apex","SOQL"],"niceToHaveSkills":["Experience Cloud"],'
        + '"synonyms":["Salesforce"],"location":"Toronto, ON","workMode":"Hybrid","minExperienceYears":4}';

    private static Job__c newJob(String name, String description) {
        Job__c j = new Job__c(Name = name, Job_Description__c = description);
        insert j;
        return j;
    }

    private static Job__c reload(Id jobId) {
        return [SELECT Required_Skills__c, Nice_To_Have_Skills__c, Skill_Synonyms__c, City__c, Work_Modes__c,
                       Min_Experience_Years__c, Requirements_Hash__c, Requirements_Extracted_On__c
                FROM Job__c WHERE Id = :jobId];
    }

    @IsTest static void theBatchFillsTheRequirementsOnANewJobWithoutAnyApplyClick() {
        Job__c job = newJob('Dev', '<p>Senior Salesforce developer in Toronto, hybrid, 4+ years.</p>');
        PromptRunner.mockResponse = EXTRACT_JSON;

        Test.startTest();
        Id batchId = JobRequirementsScheduler.runNow();
        Test.stopTest();

        System.assertNotEquals(null, batchId);
        Job__c r = reload(job.Id);
        System.assertEquals('Apex, SOQL', r.Required_Skills__c);
        System.assertEquals('Experience Cloud', r.Nice_To_Have_Skills__c);
        System.assert(r.Skill_Synonyms__c.contains('Salesforce'));
        System.assertEquals('Toronto', r.City__c);
        System.assertEquals('Hybrid', r.Work_Modes__c);
        System.assertEquals(4, r.Min_Experience_Years__c);
        System.assertNotEquals(null, r.Requirements_Hash__c);
        System.assertNotEquals(null, r.Requirements_Extracted_On__c);
    }

    @IsTest static void aNewJobIsPickedUpByTheBatchQuery() {
        Job__c job = newJob('Dev', 'Apex developer');
        Set<Id> picked = new Set<Id>();
        Database.QueryLocatorIterator it = new JobRequirementsBatch().start(null).iterator();
        while (it.hasNext()) { picked.add(((Job__c) it.next()).Id); }
        System.assert(picked.contains(job.Id));
    }

    @IsTest static void anUnchangedJobCostsNoPromptCall() {
        Job__c job = newJob('Dev', 'Apex developer');
        JobRequirementsService.applyText(job.Id, EXTRACT_JSON);
        PromptRunner.mockError = 'the prompt must not be called for an unchanged job';

        JobRequirementsBatch b = new JobRequirementsBatch();
        b.execute(null, new List<SObject>{ job });

        System.assertEquals(1, b.total);
        System.assertEquals(0, b.failed, 'a prompt call would have thrown and been counted as a failure');
    }

    @IsTest static void aChangedDescriptionIsExtractedAgain() {
        Job__c job = newJob('Dev', 'Apex developer');
        JobRequirementsService.applyText(job.Id, EXTRACT_JSON);
        String oldHash = reload(job.Id).Requirements_Hash__c;

        job.Job_Description__c = 'Apex developer who also knows Flow';
        update job;
        PromptRunner.mockResponse = '{"requiredSkills":["Apex","Flow"],"niceToHaveSkills":[],"synonyms":[]}';
        new JobRequirementsBatch().execute(null, new List<SObject>{ job });

        Job__c r = reload(job.Id);
        System.assertEquals('Apex, Flow', r.Required_Skills__c);
        System.assertNotEquals(oldHash, r.Requirements_Hash__c);
    }

    @IsTest static void aBlankDescriptionIsSkippedWithoutAFailure() {
        Job__c job = newJob('Empty', null);
        PromptRunner.mockError = 'the prompt must not be called without a description';

        JobRequirementsBatch b = new JobRequirementsBatch();
        b.execute(null, new List<SObject>{ job });

        System.assertEquals(0, b.failed);
        System.assertEquals(null, reload(job.Id).Requirements_Hash__c);
    }

    @IsTest static void aFailureIsCountedNotThrownAndTheJobIsRetriedOnTheNextRun() {
        Job__c first = newJob('One', 'Apex developer');
        Job__c second = newJob('Two', 'Flow administrator');
        List<SObject> scope = new List<SObject>{ first, second };

        PromptRunner.mockError = 'API request failed: 429 Too Many Requests';
        JobRequirementsBatch failing = new JobRequirementsBatch();
        failing.execute(null, scope);                                   // must not throw: the rest of the run goes on
        System.assertEquals(2, failing.failed);
        System.assertEquals(null, reload(first.Id).Requirements_Hash__c, 'no hash is saved, so the next run tries again');

        PromptRunner.mockError = null;
        PromptRunner.mockResponse = EXTRACT_JSON;
        JobRequirementsBatch retry = new JobRequirementsBatch();
        retry.execute(null, scope);
        System.assertEquals(0, retry.failed);
        System.assertNotEquals(null, reload(first.Id).Requirements_Hash__c);
        System.assertNotEquals(null, reload(second.Id).Requirements_Hash__c);
    }

    @IsTest static void applyFiltersNoLongerExtractsTheRequirements() {
        Job__c job = newJob('Dev', '<p>Senior Salesforce developer in Toronto, hybrid, 4+ years.</p>');
        PromptRunner.mockByTemplate = new Map<String, String>{ JobRequirementsService.TEMPLATE => EXTRACT_JSON };

        CandidateMatchOrchestrator.start(job.Id, new CandidateMatchOrchestrator.Filters());

        Job__c r = reload(job.Id);
        System.assertEquals(null, r.Requirements_Hash__c, 'extraction belongs to the batch, not to the Apply click');
        System.assertEquals(null, r.Required_Skills__c);
    }
}
