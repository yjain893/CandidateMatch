@IsTest
private class CaseFromTranscriptTest {
    static Chat_Conversation__c conv(String transcript) {
        Chat_Conversation__c c = new Chat_Conversation__c(Transcript__c = transcript, Conversation_Identifier__c = 'T-' + String.valueOf(Crypto.getRandomLong()));
        insert c;
        return c;
    }

    @IsTest
    static void createsAndLinksCase() {
        Chat_Conversation__c c = conv('Caller asked for order status.');
        CaseFromTranscript.mockResponse = 'Here: {"subject":"Order status","description":"Caller asked where the order is.","category":"order status","confidence":"high"}';
        Test.startTest();
        Case made = CaseFromTranscript.createCase(c.Id);
        Test.stopTest();
        Case got = [SELECT Subject, Description, Category__c, Origin FROM Case WHERE Id = :made.Id];
        System.assertEquals('Order status', got.Subject);
        System.assertEquals('Order Status', got.Category__c);
        System.assertEquals('Phone', got.Origin);
        System.assertEquals(made.Id, [SELECT Case__c FROM Chat_Conversation__c WHERE Id = :c.Id].Case__c);
    }

    @IsTest
    static void unknownCategoryFallsBackToOther() {
        Chat_Conversation__c c = conv('x');
        CaseFromTranscript.mockResponse = '{"subject":"S","description":"D","category":"Made Up"}';
        Case made = CaseFromTranscript.createCase(c.Id);
        System.assertEquals('Other', [SELECT Category__c FROM Case WHERE Id = :made.Id].Category__c);
    }

    @IsTest
    static void secondCallReturnsSameCase() {
        Chat_Conversation__c c = conv('x');
        CaseFromTranscript.mockResponse = '{"subject":"S","description":"D","category":"Other"}';
        Case a = CaseFromTranscript.createCase(c.Id);
        Case b = CaseFromTranscript.createCase(c.Id);
        System.assertEquals(a.Id, b.Id);
        System.assertEquals(1, [SELECT COUNT() FROM Case WHERE Id IN (SELECT Case__c FROM Chat_Conversation__c WHERE Id = :c.Id)]);
    }

    @IsTest
    static void invocableReportsErrorsWithoutThrowing() {
        Chat_Conversation__c c = conv('x');
        CaseFromTranscript.mockError = 'boom';
        CaseFromTranscript.Request r = new CaseFromTranscript.Request();
        r.conversationId = c.Id;
        List<CaseFromTranscript.Result> out = CaseFromTranscript.run(new List<CaseFromTranscript.Request>{ r });
        System.assertEquals('boom', out[0].message);
        System.assertEquals(null, out[0].caseId);
    }

    @IsTest
    static void invocableCreatesCase() {
        Chat_Conversation__c c = conv('x');
        CaseFromTranscript.mockResponse = '{"subject":"S","description":"D","category":"Complaint"}';
        CaseFromTranscript.Request r = new CaseFromTranscript.Request();
        r.conversationId = c.Id;
        List<CaseFromTranscript.Result> out = CaseFromTranscript.run(new List<CaseFromTranscript.Request>{ r });
        System.assertNotEquals(null, out[0].caseId);
        System.assertEquals('Complaint', out[0].category);
    }

    @IsTest
    static void badAnswersAreRejected() {
        Chat_Conversation__c c = conv('x');
        for (String bad : new List<String>{ '', 'no json here', '{broken' }) {
            CaseFromTranscript.mockResponse = bad == '' ? null : bad;
            CaseFromTranscript.mockError = bad == '' ? 'empty' : null;
            try { CaseFromTranscript.createCase(c.Id); System.assert(false, 'should fail'); }
            catch (CaseFromTranscript.CaseException e) { System.assert(true); }
        }
        System.assertEquals(0, [SELECT COUNT() FROM Case WHERE Id IN (SELECT Case__c FROM Chat_Conversation__c WHERE Id = :c.Id)]);
    }

    @IsTest
    static void missingConversationFails() {
        try { CaseFromTranscript.createCase(null); System.assert(false); }
        catch (CaseFromTranscript.CaseException e) { System.assert(true); }
    }

    @IsTest
    static void pickCategoryMatchesIgnoringCase() {
        List<String> allowed = new List<String>{ 'Complaint', 'Other' };
        System.assertEquals('Complaint', CaseFromTranscript.pickCategory(' complaint ', allowed));
        System.assertEquals('Other', CaseFromTranscript.pickCategory(null, allowed));
    }

    @IsTest
    static void realTemplateCallIsAttemptedWithoutMock() {
        Chat_Conversation__c c = conv('x');
        CaseFromTranscript.Request r = new CaseFromTranscript.Request();
        r.conversationId = c.Id;
        // No mock: the ConnectApi call cannot succeed inside a test, but the error must be reported, not thrown.
        List<CaseFromTranscript.Result> out = CaseFromTranscript.run(new List<CaseFromTranscript.Request>{ r });
        System.assertEquals(1, out.size());
    }
}
