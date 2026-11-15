/** One-off: sets Has_Resume__c = true on contacts that already have a PDF attached. Run once for existing data. */
public with sharing class ResumeBackfillBatch implements Database.Batchable<SObject> {
    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator('SELECT Id FROM Contact WHERE Has_Resume__c = false');
    }
    public void execute(Database.BatchableContext bc, List<Contact> scope) {
        Set<Id> ids = new Map<Id, Contact>(scope).keySet();
        Set<Id> withResume = new Set<Id>();
        for (ContentDocumentLink l : [
            SELECT LinkedEntityId FROM ContentDocumentLink
            WHERE LinkedEntityId IN :ids AND ContentDocument.FileExtension = 'pdf'
        ]) { withResume.add(l.LinkedEntityId); }
        List<Contact> toUpdate = new List<Contact>();
        for (Id cid : withResume) { toUpdate.add(new Contact(Id = cid, Has_Resume__c = true)); }
        update toUpdate;
    }
    public void finish(Database.BatchableContext bc) {}
}
