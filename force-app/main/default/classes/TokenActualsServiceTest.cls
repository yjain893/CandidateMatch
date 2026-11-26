@IsTest
private class TokenActualsServiceTest {

    // Plays back prepared Google responses, one per call; the last one repeats. Remembers the last request.
    class MockGoogle implements HttpCalloutMock {
        List<HttpResponse> responses = new List<HttpResponse>();
        Integer calls = 0;
        String lastBody;
        String lastEndpoint;

        MockGoogle add(Integer status, String body) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(body);
            responses.add(res);
            return this;
        }

        public HttpResponse respond(HttpRequest req) {
            lastBody = req.getBody();
            lastEndpoint = req.getEndpoint();
            Integer index = calls < responses.size() ? calls : responses.size() - 1;
            calls++;
            return responses[index];
        }
    }

    static Map<String, Object> llm(Integer i, Integer o, Integer t) {
        return new Map<String, Object>{
            'name' => 'LLM',
            'attributes' => new Map<String, Object>{
                'input token count' => i, 'output token count' => o, 'thought token count' => t, 'model' => 'gemini-composite-v2'
            }
        };
    }

    static Map<String, Object> tts(Integer i, Integer o) {
        return new Map<String, Object>{
            'name' => 'TTS',
            'attributes' => new Map<String, Object>{
                'input token count' => i, 'output token count' => o,
                'tts input token count' => i, 'tts output token count' => o, 'audio duration (ms)' => 2400
            }
        };
    }

    static Map<String, Object> guardrail() {
        return new Map<String, Object>{ 'name' => 'Guardrail', 'attributes' => new Map<String, Object>{ 'model' => 'gemini-3.5-flash-lite', 'triggered' => false } };
    }

    static Map<String, Object> tool(List<Object> kids) {
        return new Map<String, Object>{ 'name' => 'Tool', 'attributes' => new Map<String, Object>(), 'childSpans' => kids };
    }

    static Map<String, Object> entry(String insertId, List<Object> spans) {
        return new Map<String, Object>{
            'insertId' => insertId,
            'jsonPayload' => new Map<String, Object>{
                'diagnosticInfo' => new Map<String, Object>{
                    'rootSpan' => new Map<String, Object>{ 'name' => 'Root', 'attributes' => new Map<String, Object>(), 'childSpans' => spans }
                }
            }
        };
    }

    static String page(List<Object> entries, String nextToken) {
        Map<String, Object> body = new Map<String, Object>{ 'entries' => entries };
        if (nextToken != null) {
            body.put('nextPageToken', nextToken);
        }
        return JSON.serialize(body);
    }

    @IsTest
    static void addsUpAllTurnsOverPagesAndSkipsDuplicates() {
        Map<String, Object> e1 = entry('e1', new List<Object>{ guardrail(), llm(4254, 20, 0), tts(63, 378) });
        Map<String, Object> e2 = entry('e2', new List<Object>{ tool(new List<Object>{ llm(100, 5, 1) }), guardrail() });
        MockGoogle mock = new MockGoogle()
            .add(200, page(new List<Object>{ e1 }, 'next-page'))
            .add(200, page(new List<Object>{ e1, e2 }, null));
        Test.setMock(HttpCalloutMock.class, mock);
        TokenActualsService.projectIdOverride = 'test-project';

        Test.startTest();
        TokenActualsService.Totals t = TokenActualsService.fetchTotals('simulator-abc-123', System.now());
        Test.stopTest();

        System.assertEquals(2, mock.calls, 'two pages');
        System.assertEquals(2, t.entries, 'the repeated entry counts once');
        System.assertEquals(4354, t.modelIn);
        System.assertEquals(25, t.modelOut);
        System.assertEquals(1, t.modelThought);
        System.assertEquals(63, t.voiceIn, 'TTS numbers are taken once, not twice');
        System.assertEquals(378, t.voiceOut);
        System.assertEquals(4354 + 25 + 1 + 63 + 378, t.total());
        System.assertEquals(2, t.llmSpans);
        System.assertEquals(1, t.ttsSpans);
        System.assert(!t.truncated);
        System.assert(mock.lastBody.contains('labels.session_id'), 'asks for this session only');
        System.assert(mock.lastBody.contains('simulator-abc-123'));
        System.assert(mock.lastBody.contains('timestamp>='), 'search is limited to a time window');
        System.assert(mock.lastBody.contains('timestamp<='));
        System.assert(mock.lastBody.contains('next-page'), 'second request carries the page token');
        System.assert(mock.lastEndpoint.startsWith('callout:Google_Logging_API'));
    }

    @IsTest
    static void numbersGivenAsTextOrDecimalAreRead() {
        Map<String, Object> e = entry('e1', new List<Object>{
            new Map<String, Object>{ 'name' => 'LLM', 'attributes' => new Map<String, Object>{ 'input token count' => '10', 'output token count' => 2.0, 'thought token count' => 'oops' } }
        });
        Test.setMock(HttpCalloutMock.class, new MockGoogle().add(200, page(new List<Object>{ e }, null)));
        TokenActualsService.projectIdOverride = 'test-project';
        TokenActualsService.Totals t = TokenActualsService.fetchTotals('s1', System.now());
        System.assertEquals(10, t.modelIn);
        System.assertEquals(2, t.modelOut);
        System.assertEquals(0, t.modelThought, 'unreadable value counts as 0');
    }

    @IsTest
    static void emptyAnswerMeansNoLogEntries() {
        Test.setMock(HttpCalloutMock.class, new MockGoogle().add(200, '{}'));
        TokenActualsService.projectIdOverride = 'test-project';
        TokenActualsService.Totals t = TokenActualsService.fetchTotals('s1', System.now());
        System.assertEquals(0, t.entries);
        Chat_Conversation__c c = new Chat_Conversation__c(Conversation_Identifier__c = 's1');
        TokenActualsService.apply(c, t);
        System.assertEquals('No log entries', c.Actual_Tokens_Status__c);
        System.assertEquals(null, c.Actual_Total_Tokens__c);
        System.assertNotEquals(null, c.Actual_Tokens_Checked_At__c);
    }

    @IsTest
    static void entriesWithoutTokenCountsAreReported() {
        Test.setMock(HttpCalloutMock.class, new MockGoogle().add(200, page(new List<Object>{ entry('e1', new List<Object>{ guardrail() }) }, null)));
        TokenActualsService.projectIdOverride = 'test-project';
        Chat_Conversation__c c = new Chat_Conversation__c(Conversation_Identifier__c = 's1');
        TokenActualsService.apply(c, TokenActualsService.fetchTotals('s1', System.now()));
        System.assertEquals('No token counts found', c.Actual_Tokens_Status__c);
    }

    @IsTest
    static void applyFillsFieldsAndMarksDone() {
        TokenActualsService.Totals t = new TokenActualsService.Totals();
        t.entries = 1; t.llmSpans = 1; t.ttsSpans = 1;
        t.modelIn = 10; t.modelOut = 2; t.modelThought = 3; t.voiceIn = 4; t.voiceOut = 5;
        Chat_Conversation__c c = new Chat_Conversation__c(Conversation_Identifier__c = 's1');
        TokenActualsService.apply(c, t);
        System.assertEquals('Done', c.Actual_Tokens_Status__c);
        System.assertEquals(10, c.Actual_Model_Input_Tokens__c);
        System.assertEquals(2, c.Actual_Model_Output_Tokens__c);
        System.assertEquals(3, c.Actual_Model_Thought_Tokens__c);
        System.assertEquals(4, c.Actual_Voice_Input_Tokens__c);
        System.assertEquals(5, c.Actual_Voice_Output_Tokens__c);
        System.assertEquals(24, c.Actual_Total_Tokens__c);
        t.truncated = true;
        TokenActualsService.apply(c, t);
        System.assert(c.Actual_Tokens_Status__c.startsWith('Partial'));
    }

    @IsTest
    static void tooManyPagesIsMarkedTruncated() {
        // every page says there is another one
        Test.setMock(HttpCalloutMock.class, new MockGoogle().add(200, page(new List<Object>{ entry('e' + 1, new List<Object>{ llm(1, 1, 0) }) }, 'more')));
        TokenActualsService.projectIdOverride = 'test-project';
        TokenActualsService.Totals t = TokenActualsService.fetchTotals('s1', System.now());
        System.assert(t.truncated);
        System.assertEquals(1, t.entries, 'same insertId every page: counted once');
    }

    @IsTest
    static void googleErrorBecomesShortMessage() {
        Test.setMock(HttpCalloutMock.class, new MockGoogle().add(403, '{"error":{"code":403,"message":"Permission denied on the log"}}'));
        TokenActualsService.projectIdOverride = 'test-project';
        try {
            TokenActualsService.fetchTotals('s1', System.now());
            System.assert(false, 'should have failed');
        } catch (TokenActualsService.TokenActualsException e) {
            System.assert(e.getMessage().contains('status 403'));
            System.assert(e.getMessage().contains('Permission denied'));
            Chat_Conversation__c c = new Chat_Conversation__c(Conversation_Identifier__c = 's1');
            TokenActualsService.applyError(c, e);
            System.assert(c.Actual_Tokens_Status__c.startsWith('Error: '));
        }
    }

    @IsTest
    static void badSessionIdIsRefusedBeforeAnyCall() {
        TokenActualsService.projectIdOverride = 'test-project';
        for (String bad : new List<String>{ null, '', 'a" OR 1=1', 'has space' }) {
            try {
                TokenActualsService.fetchTotals(bad, System.now());
                System.assert(false, 'should have failed for: ' + bad);
            } catch (TokenActualsService.TokenActualsException e) {
                System.assert(e.getMessage().contains('not a valid session id'));
            }
        }
    }

    @IsTest
    static void missingProjectConfigGivesClearError() {
        TokenActualsService.projectIdOverride = null;
        if (Token_Log_Config__mdt.getInstance('Default') != null) {
            return; // the org already has the record: nothing to prove here
        }
        try {
            TokenActualsService.fetchTotals('s1', System.now());
            System.assert(false, 'should have failed');
        } catch (TokenActualsService.TokenActualsException e) {
            System.assert(e.getMessage().contains('Token_Log_Config__mdt'));
        }
    }

    // A test user that has the permission set the real job user will have: it gives access to the new fields.
    static User makeRunner() {
        User runner;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
            String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', 'n');
            runner = new User(
                Alias = 'tokact', Email = 'tokenactuals' + unique + '@example.com', EmailEncodingKey = 'UTF-8',
                LastName = 'TokenActuals', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = admin.Id,
                TimeZoneSidKey = 'America/Los_Angeles', Username = 'tokenactuals' + unique + '@example.com'
            );
            insert runner;
            insert new PermissionSetAssignment(
                AssigneeId = runner.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Voice_Agent_Access' LIMIT 1].Id
            );
        }
        return runner;
    }

    @IsTest
    static void queueableFillsOldEnoughTranscriptsOnly() {
        User runner = makeRunner();
        System.runAs(runner) {
            runFillsOldEnough();
        }
    }

    static void runFillsOldEnough() {
        Chat_Conversation__c old1 = new Chat_Conversation__c(Conversation_Identifier__c = 'simulator-old-1');
        Chat_Conversation__c tooNew = new Chat_Conversation__c(Conversation_Identifier__c = 'simulator-new-1');
        Chat_Conversation__c done = new Chat_Conversation__c(Conversation_Identifier__c = 'simulator-done-1', Actual_Tokens_Status__c = 'Done', Actual_Total_Tokens__c = 7);
        Chat_Conversation__c ancient = new Chat_Conversation__c(Conversation_Identifier__c = 'simulator-ancient-1');
        insert new List<Chat_Conversation__c>{ old1, tooNew, done, ancient };
        Test.setCreatedDate(old1.Id, System.now().addHours(-1));
        Test.setCreatedDate(done.Id, System.now().addHours(-1));
        Test.setCreatedDate(ancient.Id, System.now().addDays(-9));

        Map<String, Object> e1 = entry('e1', new List<Object>{ llm(100, 10, 0), tts(5, 50) });
        Test.setMock(HttpCalloutMock.class, new MockGoogle().add(200, page(new List<Object>{ e1 }, null)));
        TokenActualsService.projectIdOverride = 'test-project';

        Test.startTest();
        new TokenActualsQueueable().execute(null); // same steps as the real job, run right here
        Test.stopTest();

        Map<Id, Chat_Conversation__c> after = new Map<Id, Chat_Conversation__c>([
            SELECT Actual_Tokens_Status__c, Actual_Total_Tokens__c, Actual_Model_Input_Tokens__c FROM Chat_Conversation__c
        ]);
        System.assertEquals('Done', after.get(old1.Id).Actual_Tokens_Status__c);
        System.assertEquals(165, after.get(old1.Id).Actual_Total_Tokens__c);
        System.assertEquals(100, after.get(old1.Id).Actual_Model_Input_Tokens__c);
        System.assertEquals(null, after.get(tooNew.Id).Actual_Tokens_Status__c, 'younger than 10 minutes: wait');
        System.assertEquals(7, after.get(done.Id).Actual_Total_Tokens__c, 'already done: untouched');
        System.assertEquals(null, after.get(ancient.Id).Actual_Tokens_Status__c, 'older than 7 days: skipped');
    }

    @IsTest
    static void outOfTimeLeavesRecordsUntouched() {
        User runner = makeRunner();
        System.runAs(runner) {
            Chat_Conversation__c c = new Chat_Conversation__c(Conversation_Identifier__c = 'simulator-slow-1');
            insert c;
            Test.setCreatedDate(c.Id, System.now().addHours(-1));
            MockGoogle mock = new MockGoogle().add(200, '{}');
            Test.setMock(HttpCalloutMock.class, mock);
            TokenActualsService.projectIdOverride = 'test-project';
            TokenActualsQueueable.budgetMs = -1; // no time left
            Test.startTest();
            new TokenActualsQueueable().execute(null);
            Test.stopTest();
            System.assertEquals(0, mock.calls, 'no call to Google');
            System.assertEquals(null, [SELECT Actual_Tokens_Status__c FROM Chat_Conversation__c WHERE Id = :c.Id].Actual_Tokens_Status__c);
        }
    }

    @IsTest
    static void queueableRecordsTheErrorAndKeepsGoing() {
        User runner = makeRunner();
        System.runAs(runner) {
            runRecordsError();
        }
    }

    static void runRecordsError() {
        Chat_Conversation__c c = new Chat_Conversation__c(Conversation_Identifier__c = 'simulator-err-1');
        insert c;
        Test.setCreatedDate(c.Id, System.now().addHours(-1));
        Test.setMock(HttpCalloutMock.class, new MockGoogle().add(500, '{"error":{"message":"backend busy"}}'));
        TokenActualsService.projectIdOverride = 'test-project';

        Test.startTest();
        new TokenActualsQueueable().execute(null); // same steps as the real job, run right here
        Test.stopTest();

        Chat_Conversation__c after = [SELECT Actual_Tokens_Status__c, Actual_Tokens_Checked_At__c FROM Chat_Conversation__c WHERE Id = :c.Id];
        System.assert(after.Actual_Tokens_Status__c.startsWith('Error: Google returned status 500'));
        System.assertNotEquals(null, after.Actual_Tokens_Checked_At__c);
    }

    @IsTest
    static void finishingATranscriptQueuesTheLookupOnce() {
        Chat_Conversation__c open = new Chat_Conversation__c(Conversation_Identifier__c = 'simulator-trigger-1', Conversation_Status__c = 'Open');
        insert open;
        System.assertEquals(0, Limits.getQueueableJobs(), 'a call that is still open queues nothing');
        Test.startTest();
        open.Conversation_Status__c = 'Closed';
        update open;
        Integer afterClose = Limits.getQueueableJobs();
        System.assert(afterClose >= 1, 'closing queues the lookup');
        open.Message_Count__c = 3;
        update open;
        System.assertEquals(afterClose, Limits.getQueueableJobs(), 'a later edit queues nothing more');
        Test.stopTest();
    }

    @IsTest
    static void schedulerStartsFourJobsAndCanStopThem() {
        Test.startTest();
        TokenActualsScheduler.scheduleEvery15Minutes();
        Integer started = [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'Token actuals :%'];
        TokenActualsScheduler.unschedule();
        Integer left = [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'Token actuals :%'];
        Test.stopTest();
        System.assertEquals(4, started);
        System.assertEquals(0, left);
    }
}
