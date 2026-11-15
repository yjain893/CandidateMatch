/** Keeps Contact.Has_Resume__c correct. A newly attached PDF also resets the parse status so the resume is re-read next time. */
public without sharing class ResumeQueueHandler {
    public static void markHasResume(List<ContentDocumentLink> links) {
        String prefix = Contact.SObjectType.getDescribe().getKeyPrefix();
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink l : links) {
            if (String.valueOf(l.LinkedEntityId).startsWith(prefix)) { docIds.add(l.ContentDocumentId); }
        }
        if (docIds.isEmpty()) { return; }
        Set<Id> pdfDocs = new Map<Id, ContentDocument>(
            [SELECT Id FROM ContentDocument WHERE Id IN :docIds AND FileExtension = 'pdf']).keySet();

        Set<Id> contactIds = new Set<Id>();
        for (ContentDocumentLink l : links) {
            if (String.valueOf(l.LinkedEntityId).startsWith(prefix) && pdfDocs.contains(l.ContentDocumentId)) {
                contactIds.add(l.LinkedEntityId);
            }
        }
        if (contactIds.isEmpty()) { return; }
        List<Contact> toUpdate = new List<Contact>();
        for (Contact c : [SELECT Id, Has_Resume__c, Resume_Parse_Status__c FROM Contact WHERE Id IN :contactIds]) {
            Boolean changed = false;
            if (c.Has_Resume__c != true) { c.Has_Resume__c = true; changed = true; }
            String st = c.Resume_Parse_Status__c;
            if (st == 'Parsed' || st == 'Review' || st == 'Failed') { c.Resume_Parse_Status__c = null; changed = true; }
            if (changed) { toUpdate.add(c); }
        }
        if (!toUpdate.isEmpty()) { update toUpdate; }
    }
}
