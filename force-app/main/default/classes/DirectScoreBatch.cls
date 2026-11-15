/** Direct mode, step 2: scores the candidates of one screen run, a couple at a time (one prompt call each). */
public with sharing class DirectScoreBatch implements Database.Batchable<SObject>, Database.AllowsCallouts {
    private String runKey;

    public DirectScoreBatch(String runKey) { this.runKey = runKey; }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Contact__c, Job__c FROM Candidate_Match__c
            WHERE Run_Key__c = :runKey AND Status__c = 'Queued for scoring'
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Candidate_Match__c> scope) {
        Map<Id, List<Id>> byJob = new Map<Id, List<Id>>();
        for (Candidate_Match__c m : scope) {
            if (!byJob.containsKey(m.Job__c)) { byJob.put(m.Job__c, new List<Id>()); }
            byJob.get(m.Job__c).add(m.Contact__c);
        }
        try {
            for (Id jobId : byJob.keySet()) { CandidateMatchService.scoreDirect(jobId, byJob.get(jobId)); }
        } catch (Exception e) {
            for (Candidate_Match__c m : scope) { m.Status__c = 'Failed: AI scoring'; }
            update scope;
        }
    }

    public void finish(Database.BatchableContext bc) {}
}
