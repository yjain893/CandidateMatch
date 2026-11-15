/**
 * Primary path for thousands of resumes: each execute() submits ONE AiJobRun.
 * Run with a scope of 200-1000 (max 1,000 items per AiJobRun on standard models):
 *   Database.executeBatch(new ResumeJobStarterBatch(), 200);
 * No callouts happen here; the platform processes the runs asynchronously.
 */
public with sharing class ResumeJobStarterBatch implements Database.Batchable<SObject> {
    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator('SELECT Id FROM Contact WHERE Has_Resume__c = true AND (Resume_Parse_Status__c = null OR Resume_Parse_Status__c = \'Pending\')');
    }
    public void execute(Database.BatchableContext bc, List<Contact> scope) {
        ResumeJobService.startFor(new List<Id>(new Map<Id, Contact>(scope).keySet()));
    }
    public void finish(Database.BatchableContext bc) {}
}
