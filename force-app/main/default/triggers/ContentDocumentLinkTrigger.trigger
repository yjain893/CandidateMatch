trigger ContentDocumentLinkTrigger on ContentDocumentLink (after insert) {
    ResumeQueueHandler.markHasResume(Trigger.new);
}
