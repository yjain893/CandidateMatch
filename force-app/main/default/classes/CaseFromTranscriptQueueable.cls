/** Creates the Case for finished transcripts, outside the trigger transaction. */
public with sharing class CaseFromTranscriptQueueable implements Queueable, Database.AllowsCallouts {
    public static final String CLOSED = 'Closed';
    @TestVisible static Integer jobsRun = 0;
    private final List<Id> ids;

    public CaseFromTranscriptQueueable(List<Id> ids) { this.ids = ids; }

    public static Boolean qualifies(Chat_Conversation__c c) {
        return c != null && c.Conversation_Status__c == CLOSED && !String.isBlank(c.Transcript__c);
    }

    public void execute(QueueableContext ctx) {
        jobsRun++;
        for (Id convId : ids) {
            try {
                CaseFromTranscript.createCase(convId);
            } catch (Exception e) {
                // One failed transcript must not stop the others; the transcript itself is already saved.
                System.debug(LoggingLevel.ERROR, 'CaseFromTranscript failed for ' + convId + ': ' + e.getMessage());
            }
        }
    }
}
