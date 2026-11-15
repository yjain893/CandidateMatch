/** Parses all contacts with Resume_Parse_Status__c = 'Pending'. Run with a small scope (3-5). */
public with sharing class ResumeParseBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {
    private Integer total = 0;
    private Integer failed = 0;

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator('SELECT Id FROM Contact WHERE Has_Resume__c = true AND (Resume_Parse_Status__c = null OR Resume_Parse_Status__c = \'Pending\')');
    }
    public void execute(Database.BatchableContext bc, List<Contact> scope) {
        List<Id> ids = new List<Id>(new Map<Id, Contact>(scope).keySet());
        failed += ResumeParserService.process(ids);
        total += ids.size();
    }
    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO, 'Resume parsing finished. Contacts: ' + total + ', failed: ' + failed);
    }
}
