@IsTest
private class CaseTranscriptsForPromptTest {
    static String run(String caseId) {
        CaseTranscriptsForPrompt.Request r = new CaseTranscriptsForPrompt.Request();
        r.caseId = caseId;
        return CaseTranscriptsForPrompt.getTranscripts(new List<CaseTranscriptsForPrompt.Request>{ r })[0].Prompt;
    }

    @IsTest
    static void returnsLinkedTranscript() {
        Chat_Conversation__c t = new Chat_Conversation__c(Conversation_Identifier__c = 'T-1', Transcript__c = 'Caller: hello\nAgent: hi', Message_Count__c = 2);
        insert t;
        Case c = new Case(Subject = 'S');
        insert c;
        t.Case__c = c.Id;
        update t;
        String out = run(c.Id);
        System.assert(out.contains('Caller: hello Agent: hi'), out);
        System.assert(out.contains('Messages: 2'), out);
    }

    @IsTest
    static void noLinkOrBlankIdGivesNoRecords() {
        Case c = new Case(Subject = 'S');
        insert c;
        System.assertEquals('NO TRANSCRIPT RECORDS', run(c.Id));
        System.assertEquals('NO TRANSCRIPT RECORDS', run(null));
    }

    @IsTest
    static void longTranscriptIsClipped() {
        Chat_Conversation__c t = new Chat_Conversation__c(Conversation_Identifier__c = 'T-2', Transcript__c = 'x'.repeat(5000));
        insert t;
        Case c = new Case(Subject = 'S');
        insert c;
        t.Case__c = c.Id;
        update t;
        System.assert(run(c.Id).endsWith('...'));
    }

    @IsTest
    static void manyTranscriptsOnOneCase() {
        Case c = new Case(Subject = 'S');
        insert c;
        insert new List<Chat_Conversation__c>{
            new Chat_Conversation__c(Conversation_Identifier__c = 'T-A', Transcript__c = 'first call', Case__c = c.Id),
            new Chat_Conversation__c(Conversation_Identifier__c = 'T-B', Transcript__c = 'second call', Case__c = c.Id)
        };
        String out = run(c.Id);
        System.assert(out.contains('first call') && out.contains('second call'), out);
    }
}
