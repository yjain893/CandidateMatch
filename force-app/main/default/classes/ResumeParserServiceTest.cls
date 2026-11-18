@IsTest
private class ResumeParserServiceTest {
    static final String RESPONSE = '```json\n{"summary":"Developer","confidence":"high","skills":[{"name":"Java","years":5},{"name":"Apex","years":null}],'
        + '"education":[{"institution":"MIT","degree":"BS","fieldOfStudy":"CS","startDate":"2010","endDate":"2014"}],'
        + '"employment":[{"employer":"Acme","role":"Senior Engineer","startDate":"2015-01","endDate":null,"description":"Built things"}]}\n```';

    static Contact contactWithPdf(String status) {
        Contact c = new Contact(LastName = 'Tester', Resume_Parse_Status__c = status);
        insert c;
        insert new ContentVersion(Title = 'resume', PathOnClient = 'resume.pdf',
            VersionData = Blob.valueOf('x'), FirstPublishLocationId = c.Id);
        return c;
    }

    @IsTest static void syncPathParsesAndSavesChildrenWithRole() {
        Contact c = contactWithPdf('Pending');
        PromptRunner.mockResponse = RESPONSE;
        Test.startTest();
        Integer failed = ResumeParserService.process(new List<Id>{ c.Id });
        Test.stopTest();
        System.assertEquals(0, failed);
        System.assertEquals(2, [SELECT COUNT() FROM Skill__c WHERE Contact__c = :c.Id]);
        System.assertEquals(1, [SELECT COUNT() FROM Education_History__c WHERE Contact__c = :c.Id]);
        Employment_History__c e = [SELECT Name, Role__c FROM Employment_History__c WHERE Contact__c = :c.Id];
        System.assertEquals('Acme', e.Name);
        System.assertEquals('Senior Engineer', e.Role__c);
        Contact r = [SELECT Resume_Parse_Status__c, Candidate_Profile__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals('Parsed', r.Resume_Parse_Status__c);
        System.assert(r.Candidate_Profile__c.contains('Senior Engineer'));
    }

    @IsTest static void aRepeatedKeyInTheResumeAnswerStillParses() {
        // The model sometimes repeats a key (here at the top and inside a skill). Typed parsing used to reject the whole answer.
        Contact c = contactWithPdf('Pending');
        PromptRunner.mockResponse = '{"summary":"Developer","summary":"Dev","confidence":"high",'
            + '"skills":[{"name":"Java","years":5,"years":6},{"name":"Apex","years":null}],'
            + '"education":[{"institution":"MIT","degree":"BS","fieldOfStudy":"CS","startDate":"2010","endDate":"2014"}],'
            + '"employment":[{"employer":"Acme","role":"Senior Engineer","startDate":"2015-01","endDate":null,"description":"Built things"}]}';
        System.assertEquals(0, ResumeParserService.process(new List<Id>{ c.Id }));
        System.assertEquals('Parsed', [SELECT Resume_Parse_Status__c FROM Contact WHERE Id = :c.Id].Resume_Parse_Status__c);
        System.assertEquals(6, [SELECT Years_Experience__c FROM Skill__c WHERE Contact__c = :c.Id AND Name = 'Java'].Years_Experience__c);
    }

    @IsTest static void aBrokenAnswerStillFailsTheContact() {
        Contact c = contactWithPdf('Pending');
        PromptRunner.mockResponse = '{"summary": "broken", "skills": [}';   // braces are there, the JSON itself is invalid
        System.assertEquals(1, ResumeParserService.process(new List<Id>{ c.Id }));
        System.assertEquals('Failed', [SELECT Resume_Parse_Status__c FROM Contact WHERE Id = :c.Id].Resume_Parse_Status__c);
    }

    @IsTest static void thinParseGoesToReview() {
        Contact c = contactWithPdf('Pending');
        PromptRunner.mockResponse = '{"summary":"x","confidence":"low","skills":[],"education":[],"employment":[]}';
        ResumeParserService.process(new List<Id>{ c.Id });
        System.assertEquals('Review', [SELECT Resume_Parse_Status__c FROM Contact WHERE Id = :c.Id].Resume_Parse_Status__c);
    }

    @IsTest static void missingResumeFails() {
        Contact c = new Contact(LastName = 'NoFile');
        insert c;
        PromptRunner.mockResponse = RESPONSE;
        System.assertEquals(1, ResumeParserService.process(new List<Id>{ c.Id }));
        System.assertEquals('Failed', [SELECT Resume_Parse_Status__c FROM Contact WHERE Id = :c.Id].Resume_Parse_Status__c);
    }

    @IsTest static void attachingPdfSetsHasResumeAndResetsStatus() {
        Contact c = new Contact(LastName = 'Trig', Resume_Parse_Status__c = 'Parsed');
        insert c;
        insert new ContentVersion(Title = 'cv', PathOnClient = 'cv.pdf', VersionData = Blob.valueOf('x'), FirstPublishLocationId = c.Id);
        Contact r = [SELECT Has_Resume__c, Resume_Parse_Status__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(true, r.Has_Resume__c);
        System.assertEquals(null, r.Resume_Parse_Status__c);     // will be re-read next time
    }

    @IsTest static void nonPdfDoesNotCount() {
        Contact c = new Contact(LastName = 'Doc');
        insert c;
        insert new ContentVersion(Title = 'note', PathOnClient = 'note.txt', VersionData = Blob.valueOf('x'), FirstPublishLocationId = c.Id);
        System.assertEquals(false, [SELECT Has_Resume__c FROM Contact WHERE Id = :c.Id].Has_Resume__c);
    }

    @IsTest static void backfillMarksExistingContacts() {
        Contact c = contactWithPdf(null);
        update new Contact(Id = c.Id, Has_Resume__c = false);        // simulate data from before the trigger existed
        Test.startTest();
        Database.executeBatch(new ResumeBackfillBatch(), 200);
        Test.stopTest();
        System.assertEquals(true, [SELECT Has_Resume__c FROM Contact WHERE Id = :c.Id].Has_Resume__c);
    }

    @IsTest static void syncBatchParsesContactsWithResume() {
        Contact c = contactWithPdf(null);
        PromptRunner.mockResponse = RESPONSE;
        Test.startTest();
        Database.executeBatch(new ResumeParseBatch(), 5);
        Test.stopTest();
        System.assertEquals('Parsed', [SELECT Resume_Parse_Status__c FROM Contact WHERE Id = :c.Id].Resume_Parse_Status__c);
    }
}