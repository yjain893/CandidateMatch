// Opens a Case when a call transcript is finished: Status = Closed and a non-blank transcript.
// Fires once per conversation (insert, or the update that makes it qualify).
trigger ChatConversationCaseTrigger on Chat_Conversation__c (after insert, after update) {
    List<Id> ready = new List<Id>();
    for (Chat_Conversation__c c : Trigger.new) {
        if (!CaseFromTranscriptQueueable.qualifies(c)) continue;
        if (Trigger.isUpdate && CaseFromTranscriptQueueable.qualifies(Trigger.oldMap.get(c.Id))) continue;
        ready.add(c.Id);
    }
    if (!ready.isEmpty() && !System.isQueueable() && !System.isFuture() && !System.isBatch()) {
        System.enqueueJob(new CaseFromTranscriptQueueable(ready));
    }
}
