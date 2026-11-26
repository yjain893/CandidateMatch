// Runs TokenActualsQueueable on a schedule.
// Start it once (Execute Anonymous):  TokenActualsScheduler.scheduleEvery15Minutes();
// Stop it:  TokenActualsScheduler.unschedule();
// The user who schedules it runs the jobs, so that user needs the permission set "Voice_Agent_Access"
// (it gives access to the Google login and to these classes).
public with sharing class TokenActualsScheduler implements Schedulable {

    static final List<String> MINUTES = new List<String>{ '0', '15', '30', '45' };
    static final String NAME_PREFIX = 'Token actuals :';

    public void execute(SchedulableContext context) {
        System.enqueueJob(new TokenActualsQueueable());
    }

    public static void scheduleEvery15Minutes() {
        for (String minute : MINUTES) {
            System.schedule(NAME_PREFIX + minute.leftPad(2, '0'), '0 ' + minute + ' * * * ?', new TokenActualsScheduler());
        }
    }

    public static void unschedule() {
        for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE :(NAME_PREFIX + '%')]) {
            System.abortJob(ct.Id);
        }
    }
}
