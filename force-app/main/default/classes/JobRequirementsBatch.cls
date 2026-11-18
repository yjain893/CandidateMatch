/**
 * Extracts the job requirements BEFORE anyone uses the matcher screen, so Required_Skills__c, Nice_To_Have_Skills__c,
 * Skill_Synonyms__c, City__c, Work_Modes__c and Min_Experience_Years__c are already on the job when a recruiter picks it.
 * "Apply filters" no longer extracts anything (see CandidateMatchOrchestrator.start).
 *
 * Which jobs: never extracted (no Requirements_Hash__c), or saved within the look-back window (default 1 day). SOQL cannot compare
 * the description hash, so JobRequirementsService.ensureFresh does that check for each job: a job whose description has not
 * changed costs no prompt call.
 *
 * Run it with a scope of 1. ensureFresh makes the prompt call and then saves the job, and Apex does not allow a callout after a
 * save in the same transaction. JobRequirementsScheduler starts it that way.
 *     Run once by hand:  JobRequirementsScheduler.runNow();
 *     Longer look-back:  Database.executeBatch(new JobRequirementsBatch(30), 1);   // also re-checks jobs saved in the last 30 days
 */
public with sharing class JobRequirementsBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {
    private final Integer lookbackDays;
    @TestVisible private Integer total = 0;
    @TestVisible private Integer failed = 0;

    public JobRequirementsBatch() { this(1); }

    public JobRequirementsBatch(Integer lookbackDays) {
        this.lookbackDays = (lookbackDays == null || lookbackDays < 1) ? 1 : lookbackDays;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        Datetime since = System.now().addDays(-lookbackDays);
        return Database.getQueryLocator([
            SELECT Id FROM Job__c
            WHERE Requirements_Hash__c = null OR LastModifiedDate >= :since
            ORDER BY CreatedDate
        ]);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        for (SObject s : scope) {
            total++;
            try {
                JobRequirementsService.ensureFresh((Id) s.get('Id'));
            } catch (Exception e) {
                // Left untouched (no hash is saved), so the next run tries this job again.
                failed++;
                System.debug(LoggingLevel.ERROR, 'Job requirements not extracted for ' + s.get('Id') + ': '
                    + e.getTypeName() + ': ' + e.getMessage());
            }
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO, 'Job requirements: ' + total + ' jobs checked, ' + failed + ' failed.');
    }
}
