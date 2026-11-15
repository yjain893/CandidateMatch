/**
 * Parses resumes BEFORE anyone uses the matcher screen. Picks up every contact with a PDF resume and no parse status yet
 * (new uploads are reset automatically by the file trigger). Skips the run if the previous one is still going.
 * Schedule hourly:  System.schedule('Parse new resumes', '0 0 * * * ?', new ResumeParseScheduler());
 * Run once by hand: ResumeParseScheduler.runNow();
 */
public with sharing class ResumeParseScheduler implements Schedulable {
    public void execute(SchedulableContext sc) { runNow(); }

    /** Returns the batch job id, or null if a parse batch is already running. */
    public static Id runNow() {
        Integer running = [SELECT COUNT() FROM AsyncApexJob
            WHERE ApexClass.Name = 'ResumeParseBatch' AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')];
        if (running > 0) { return null; }
        return Database.executeBatch(new ResumeParseBatch(), 2); // 2 resumes per run: each is one prompt call
    }
}
