/**
 * Keeps the job requirements up to date BEFORE anyone uses the matcher screen. Starts JobRequirementsBatch, which reads each new
 * or edited job description with the Extract_Job_Requirements prompt and fills Required_Skills__c, Nice_To_Have_Skills__c and the
 * other requirement fields. Skips the run if the previous one is still going.
 * Schedule hourly:  System.schedule('Extract job requirements', '0 0 * * * ?', new JobRequirementsScheduler());
 * Run once by hand: JobRequirementsScheduler.runNow();     // e.g. right after creating a job, or to fill all existing jobs
 */
public with sharing class JobRequirementsScheduler implements Schedulable {
    public void execute(SchedulableContext sc) { runNow(); }

    /** Returns the batch job id, or null if a requirements batch is already running. */
    public static Id runNow() {
        Integer running = [SELECT COUNT() FROM AsyncApexJob
            WHERE ApexClass.Name = 'JobRequirementsBatch' AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')];
        if (running > 0) { return null; }
        return Database.executeBatch(new JobRequirementsBatch(), 1); // 1 job per run: one prompt call, then a save
    }
}
