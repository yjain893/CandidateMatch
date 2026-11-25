@IsTest
private class CaseFromTranscriptQueueableTest {
    static Chat_Conversation__c make(String status, String text) {
        Chat_Conversation__c c = new Chat_Conversation__c(
            Conversation_Identifier__c = 'T-' + String.valueOf(Crypto.getRandomLong()),
            Conversation_Status__c = status, Transcript__c = text);
        insert c;
        return c;
    }

    @IsTest
    static void closedTranscriptCreatesOneCase() {
        CaseFromTranscript.mockResponse = '{"subject":"S","description":"D","category":"Other"}';
        Chat_Conversation__c c = make('Closed', 'Caller: hi');
        Test.startTest();
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Case WHERE Chat_Conversation__c = :c.Id]);
    }

    @IsTest
    static void laterEditDoesNotQueueAgain() {
        CaseFromTranscript.mockResponse = '{"subject":"S","description":"D","category":"Other"}';
        Test.startTest();
        Chat_Conversation__c c = make('Closed', 'Caller: hi');
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Case WHERE Chat_Conversation__c = :c.Id]);
        Integer before = Limits.getQueueableJobs();
        c.Transcript__c = 'Caller: hi again';
        update c;
        System.assertEquals(before, Limits.getQueueableJobs(), 'an edit must not queue another job');
    }

    @IsTest
    static void becomingClosedCreatesCase() {
        CaseFromTranscript.mockResponse = '{"subject":"S","description":"D","category":"Other"}';
        Chat_Conversation__c c = make('Open', 'Caller: hi');
        System.assertEquals(0, Limits.getQueueableJobs(), 'open transcript must not queue');
        Test.startTest();
        c.Conversation_Status__c = 'Closed';
        update c;
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Case WHERE Chat_Conversation__c = :c.Id]);
    }

    @IsTest
    static void blankTranscriptDoesNothing() {
        Chat_Conversation__c c = make('Closed', '');
        Test.startTest();
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Case WHERE Chat_Conversation__c = :c.Id]);
    }

    @IsTest
    static void failureDoesNotBreakSaving() {
        CaseFromTranscript.mockError = 'boom';
        Chat_Conversation__c c = make('Closed', 'Caller: hi');
        Test.startTest();
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Case WHERE Chat_Conversation__c = :c.Id]);
        System.assertEquals(1, [SELECT COUNT() FROM Chat_Conversation__c WHERE Id = :c.Id]);
    }
}
