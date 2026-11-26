@IsTest
private class TokenComparisonControllerTest {

    // A test user holding the permission sets the dashboard and the voice agent save use.
    static User makeRunner() {
        User runner;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
            String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', 'n');
            runner = new User(
                Alias = 'tokcmp', Email = 'tokencompare' + unique + '@example.com', EmailEncodingKey = 'UTF-8',
                LastName = 'TokenCompare', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = admin.Id,
                TimeZoneSidKey = 'America/Los_Angeles', Username = 'tokencompare' + unique + '@example.com'
            );
            insert runner;
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
            for (PermissionSet ps : [SELECT Id FROM PermissionSet WHERE Name = 'Voice_Agent_Access']) {
                assignments.add(new PermissionSetAssignment(AssigneeId = runner.Id, PermissionSetId = ps.Id));
            }
            insert assignments;
        }
        return runner;
    }

    static Chat_Conversation__c call(String id, String agent, Integer input, Integer output, Integer thought, Integer voiceIn, Integer voiceOut) {
        return new Chat_Conversation__c(
            Conversation_Identifier__c = id, Voice_Agent_Name__c = agent, Actual_Tokens_Status__c = 'Done',
            Actual_Model_Input_Tokens__c = input, Actual_Model_Output_Tokens__c = output, Actual_Model_Thought_Tokens__c = thought,
            Actual_Voice_Input_Tokens__c = voiceIn, Actual_Voice_Output_Tokens__c = voiceOut,
            Actual_Total_Tokens__c = input + output + thought + voiceIn + voiceOut
        );
    }

    @IsTest
    static void comparesAgentsAndFiltersBars() {
        System.runAs(makeRunner()) {
            insert new List<Chat_Conversation__c>{
                call('simulator-b1', 'Baseline', 4000, 200, 0, 100, 800),
                call('simulator-b2', 'Baseline', 6000, 300, 100, 100, 800),
                call('simulator-o1', 'Optimized', 3000, 200, 0, 100, 800),
                call('simulator-o2', 'Optimized', 3000, 100, 0, 100, 800),
                call('simulator-old', null, 5000, 100, 0, 100, 800),
                new Chat_Conversation__c(Conversation_Identifier__c = 'simulator-pending')
            };
            TokenComparisonController.Result all = TokenComparisonController.load('', 30);
            System.assertEquals(5, all.bars.size(), 'only calls with saved numbers');
            System.assertEquals(3, all.summaries.size());
            System.assertEquals(new List<String>{ 'Baseline', 'Optimized', 'Unlabelled' }, all.agents);
            // Baseline average total (5100 + 7300) / 2 = 6200; Optimized (4100 + 4000) / 2 = 4050
            Decimal baseline; Decimal optimized; Integer baselineCalls;
            for (TokenComparisonController.Summary s : all.summaries) {
                if (s.agent == 'Baseline') { baseline = s.avgTotal; baselineCalls = s.calls; }
                if (s.agent == 'Optimized') { optimized = s.avgTotal; }
            }
            System.assertEquals(6200, baseline);
            System.assertEquals(4050, optimized);
            System.assertEquals(2, baselineCalls);
            System.assertEquals(34.7, all.percentFewer, '(6200 - 4050) / 6200');

            TokenComparisonController.Result onlyOptimized = TokenComparisonController.load('Optimized', 30);
            System.assertEquals(2, onlyOptimized.bars.size());
            for (TokenComparisonController.Bar b : onlyOptimized.bars) {
                System.assertEquals('Optimized', b.agent);
            }
            System.assertEquals(3, onlyOptimized.summaries.size(), 'the comparison always shows every agent');

            TokenComparisonController.Result unlabelled = TokenComparisonController.load('Unlabelled', 30);
            System.assertEquals(1, unlabelled.bars.size());
            System.assertEquals('simulator-old', unlabelled.bars[0].identifier);
        }
    }

    @IsTest
    static void limitsTheNumberOfBarsAndKeepsOldestFirst() {
        System.runAs(makeRunner()) {
            List<Chat_Conversation__c> rows = new List<Chat_Conversation__c>();
            for (Integer i = 0; i < 5; i++) {
                rows.add(call('simulator-n' + i, 'Baseline', 1000 + i, 0, 0, 0, 0));
            }
            insert rows;
            for (Integer i = 0; i < 5; i++) {
                Test.setCreatedDate(rows[i].Id, System.now().addMinutes(-(5 - i)));
            }
            TokenComparisonController.Result r = TokenComparisonController.load('', 3);
            System.assertEquals(3, r.bars.size());
            System.assertEquals('simulator-n2', r.bars[0].identifier, 'the newest 3, oldest of them first');
            System.assertEquals('simulator-n4', r.bars[2].identifier);
            System.assertEquals(null, r.percentFewer, 'no comparison without both agents');
        }
    }

    @IsTest
    static void emptyOrganisationGivesEmptyResult() {
        System.runAs(makeRunner()) {
            TokenComparisonController.Result r = TokenComparisonController.load(null, null);
            System.assertEquals(0, r.bars.size());
            System.assertEquals(0, r.summaries.size());
            System.assertEquals(null, r.percentFewer);
        }
    }

    @IsTest
    static void blankLabelBecomesUnlabelled() {
        System.assertEquals('Unlabelled', TokenComparisonController.label(null));
        System.assertEquals('Unlabelled', TokenComparisonController.label('  '));
        System.assertEquals('Optimized', TokenComparisonController.label(' Optimized '));
    }
}
