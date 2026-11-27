@IsTest
private class TokenEfficiencyControllerTest {

    static User makeRunner() {
        User runner;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
            String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', 'n');
            runner = new User(
                Alias = 'tokeff', Email = 'tokeneff' + unique + '@example.com', EmailEncodingKey = 'UTF-8',
                LastName = 'TokenEff', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = admin.Id,
                TimeZoneSidKey = 'America/Los_Angeles', Username = 'tokeneff' + unique + '@example.com'
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

    static Chat_Conversation__c call(String id, String agent, Integer input, Integer output, Integer thought, Integer voice, Integer turns) {
        return new Chat_Conversation__c(
            Conversation_Identifier__c = id, Voice_Agent_Name__c = agent, Actual_Tokens_Status__c = 'Done', Message_Count__c = turns,
            Actual_Model_Input_Tokens__c = input, Actual_Model_Output_Tokens__c = output, Actual_Model_Thought_Tokens__c = thought,
            Actual_Voice_Input_Tokens__c = voice, Actual_Voice_Output_Tokens__c = 0,
            Actual_Total_Tokens__c = input + output + thought + voice
        );
    }

    @IsTest
    static void comparesAgentsWithTheirParts() {
        System.runAs(makeRunner()) {
            insert new List<Chat_Conversation__c>{
                call('simulator-b1', 'Baseline', 4000, 200, 0, 100, 4),
                call('simulator-b2', 'Baseline', 6000, 300, 100, 100, 6),
                call('simulator-o1', 'Optimized', 3000, 200, 0, 100, 4),
                call('simulator-o2', 'Optimized', 3000, 100, 0, 100, 4),
                call('simulator-old', null, 5000, 100, 0, 100, 4),
                new Chat_Conversation__c(Conversation_Identifier__c = 'simulator-pending')
            };
            TokenEfficiencyController.Result r = TokenEfficiencyController.load(20, false);
            System.assertEquals(2, r.agents.size(), 'unlabelled calls are left out by default');
            System.assertEquals('Baseline', r.agents[0].agent);
            System.assertEquals('Optimized', r.agents[1].agent);
            TokenEfficiencyController.AgentStat b = r.agents[0];
            TokenEfficiencyController.AgentStat o = r.agents[1];
            System.assertEquals(2, b.calls);
            System.assertEquals(5400, b.avgTotal, '(4300 + 6500) / 2');
            System.assertEquals(5000, b.avgModelInput);
            System.assertEquals(250, b.avgModelOutput);
            System.assertEquals(50, b.avgModelThought);
            System.assertEquals(100, b.avgVoice);
            System.assertEquals(4300, b.minTotal);
            System.assertEquals(6500, b.maxTotal);
            System.assertEquals(5.0, b.avgTurns);
            System.assertEquals(3250, o.avgTotal, '(3300 + 3200) / 2');
            System.assertEquals(39.8, r.percentFewer, '(5400 - 3250) / 5400');
            System.assertEquals(2150, r.tokensSaved);
            System.assertEquals(2, b.points.size());

            TokenEfficiencyController.Result withOld = TokenEfficiencyController.load(20, true);
            System.assertEquals(3, withOld.agents.size());
            System.assertEquals('Unlabelled', withOld.agents[2].agent, 'Unlabelled comes last');
        }
    }

    @IsTest
    static void takesTheLatestCallsOfEachAgentAndKeepsOldestFirst() {
        System.runAs(makeRunner()) {
            List<Chat_Conversation__c> rows = new List<Chat_Conversation__c>();
            for (Integer i = 0; i < 4; i++) {
                rows.add(call('simulator-b' + i, 'Baseline', 1000 + i, 0, 0, 0, 4));
                rows.add(call('simulator-o' + i, 'Optimized', 500 + i, 0, 0, 0, 4));
            }
            insert rows;
            for (Integer i = 0; i < rows.size(); i++) {
                Test.setCreatedDate(rows[i].Id, System.now().addMinutes(-(rows.size() - i)));
            }
            TokenEfficiencyController.Result r = TokenEfficiencyController.load(2, false);
            System.assertEquals(2, r.agents[0].calls, 'two latest of each agent');
            System.assertEquals(2, r.agents[1].calls);
            System.assertEquals(1002, r.agents[0].points[0].total, 'oldest of the latest two first');
            System.assertEquals(1003, r.agents[0].points[1].total);
        }
    }

    @IsTest
    static void noComparisonWithoutBothAgents() {
        System.runAs(makeRunner()) {
            insert call('simulator-only', 'Baseline', 1000, 0, 0, 0, 4);
            TokenEfficiencyController.Result r = TokenEfficiencyController.load(null, null);
            System.assertEquals(1, r.agents.size());
            System.assertEquals(null, r.percentFewer);
            System.assertEquals(null, r.tokensSaved);
        }
    }

    @IsTest
    static void orderPutsBaselineFirstAndUnlabelledLast() {
        List<String> o = TokenEfficiencyController.orderAgents(new Set<String>{ 'Unlabelled', 'Zeta', 'Optimized', 'Alpha', 'Baseline' });
        System.assertEquals(new List<String>{ 'Baseline', 'Optimized', 'Alpha', 'Zeta', 'Unlabelled' }, o);
        System.assertEquals('Unlabelled', TokenEfficiencyController.label(' '));
    }
}