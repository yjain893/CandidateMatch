/**
 * Direct mode, step 1: reads the resumes of the candidates in one screen run, a couple at a time
 * (one prompt call per resume), saves Skills / Education / Employment, then moves them on.
 * When it finishes, DirectScoreBatch starts for the same run.
 */
public with sharing class DirectParseBatch implements Database.Batchable<SObject>, Database.AllowsCallouts {
    private String runKey;

    public DirectParseBatch(String runKey) { this.runKey = runKey; }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Contact__c, Job__c FROM Candidate_Match__c
            WHERE Run_Key__c = :runKey AND Status__c = 'Reading resume'
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Candidate_Match__c> scope) {
        Set<Id> ids = new Set<Id>();
        for (Candidate_Match__c m : scope) { ids.add(m.Contact__c); }
        List<Id> contactIds = new List<Id>(ids);
        try {
            ResumeParserService.process(contactIds);
            CandidateMatchService.afterParse(contactIds, false);
        } catch (Exception e) {
            for (Candidate_Match__c m : scope) { m.Status__c = 'Failed: resume reading error'; }
            update scope;
        }
    }

    public void finish(Database.BatchableContext bc) {
        Integer n = [SELECT COUNT() FROM Candidate_Match__c WHERE Run_Key__c = :runKey AND Status__c = 'Queued for scoring'];
        if (n > 0 && !Test.isRunningTest()) { Database.executeBatch(new DirectScoreBatch(runKey), 2); }
    }
}
