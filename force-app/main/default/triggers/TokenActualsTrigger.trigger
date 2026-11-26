// Starts the lookup of real token counts 2 minutes after a call transcript is finished
// (Conversation_Status__c = Closed: on insert, or on the update that closes it).
// Google writes the last log entry about 1 to 2 seconds after the save; 2 minutes leaves a safe margin.
// The lookup runs as the user who saved the transcript, so that user needs the permission set
// "Voice_Agent_Access". If the lookup fails, the scheduled job
// (TokenActualsScheduler) retries later.
trigger TokenActualsTrigger on Chat_Conversation__c (after insert, after update) {
    Boolean finished = false;
    for (Chat_Conversation__c c : Trigger.new) {
        if (c.Conversation_Status__c != 'Closed') {
            continue;
        }
        if (Trigger.isInsert || Trigger.oldMap.get(c.Id).Conversation_Status__c != 'Closed') {
            finished = true;
            break;
        }
    }
    if (finished && !System.isQueueable() && !System.isFuture() && !System.isBatch()) {
        System.enqueueJob(new TokenActualsQueueable(), TokenActualsQueueable.FIRST_LOOKUP_DELAY_MINUTES);
    }
}
