// Fills in the real token counts for call transcripts that do not have them yet.
// Picks transcripts that are at least 1 minute old (Google writes the last turn's log 1 to 2 seconds
// after the save) and at most 7 days old. Retries "No log entries" and errors for 3 hours.
// At most 25 transcripts per run, to stay under Google's limit of 60 log reads per minute.
public with sharing class TokenActualsQueueable implements Queueable, Database.AllowsCallouts {

    @TestVisible static final Integer BATCH_SIZE = 25;
    public static final Integer MIN_AGE_MINUTES = 1;
    public static final Integer FIRST_LOOKUP_DELAY_MINUTES = 2; // used by TokenActualsTrigger
    // Salesforce allows 120 s of waiting for Google in one run. We stop starting new lookups after 60 s.
    @TestVisible static Long budgetMs = 60000;

    public void execute(QueueableContext context) {
        Datetime now = System.now();
        Datetime oldEnough = now.addMinutes(-MIN_AGE_MINUTES);
        Datetime notOlderThan = now.addDays(-7);
        Datetime retryWindow = now.addHours(-3);
        Datetime retryAfter = now.addMinutes(-15);
        List<Chat_Conversation__c> pending = [
            SELECT Id, Conversation_Identifier__c, CreatedDate
            FROM Chat_Conversation__c
            WHERE Conversation_Identifier__c != null
              AND CreatedDate <= :oldEnough
              AND CreatedDate >= :notOlderThan
              AND (Actual_Tokens_Status__c = null
                   OR ((Actual_Tokens_Status__c = 'No log entries' OR Actual_Tokens_Status__c LIKE 'Error%')
                       AND Actual_Tokens_Checked_At__c < :retryAfter
                       AND CreatedDate >= :retryWindow))
            ORDER BY CreatedDate ASC
            LIMIT :BATCH_SIZE
        ];
        // All Google calls first, then one update: a callout is not allowed after saving data.
        Long started = System.currentTimeMillis();
        List<Chat_Conversation__c> handled = new List<Chat_Conversation__c>();
        Boolean leftOver = false;
        for (Chat_Conversation__c record : pending) {
            if (System.currentTimeMillis() - started > budgetMs) {
                leftOver = true; // out of time: untouched, the next run picks it up
                continue;
            }
            try {
                TokenActualsService.apply(record, TokenActualsService.fetchTotals(record.Conversation_Identifier__c, record.CreatedDate));
            } catch (Exception e) {
                TokenActualsService.applyError(record, e);
            }
            handled.add(record);
        }
        if (!handled.isEmpty()) {
            update handled;
        }
        if (leftOver && !Test.isRunningTest()) {
            System.enqueueJob(new TokenActualsQueueable(), 1); // continue in 1 minute
        }
    }
}
