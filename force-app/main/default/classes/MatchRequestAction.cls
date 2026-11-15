/** Agent action: same as the screen, using the job's own City / Work Modes / Salary / Role Types as filters. Only parsed resumes are used. */
public with sharing class MatchRequestAction {
    public class Request {
        @InvocableVariable(required=true label='Job Id' description='Id of the Job record')
        public Id jobId;
    }
    public class Response {
        @InvocableVariable(label='Result' description='Status message')
        public String message;
    }

    @InvocableMethod(label='Start Candidate Matching for Job'
        description='Finds candidates whose resume is already parsed and whose city, work mode, salary and role types fit the job, and scores them in the background. Use Get Top Candidates afterwards.')
    public static List<Response> run(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request r : requests) {
            Job__c job = [SELECT Work_Modes__c, Role_Types__c, City__c, Expected_Salary__c FROM Job__c WHERE Id = :r.jobId];
            CandidateMatchOrchestrator.StartResult s = CandidateMatchOrchestrator.start(r.jobId, CandidateMatchOrchestrator.fromJob(job));
            Response res = new Response();
            String parsedNote = s.notParsed > 0
                ? ' ' + s.notParsed + ' more candidates fit the filters but their resumes are not parsed yet or need review.' : '';
            res.message = s.matched == 0
                ? 'No candidates with a parsed resume match this job\'s city, work mode, salary and role filters.' + parsedNote
                : s.matched + ' candidates with parsed resumes match the filters: ' + s.toScore + ' are being scored, '
                    + s.cached + ' already have up-to-date scores. Ask for the top candidates again in a few minutes.' + parsedNote
                    + (s.capped ? ' Only the first ' + CandidateMatchOrchestrator.MAX_CANDIDATES + ' were used; narrow the filters to see others.' : '');
            out.add(res);
        }
        return out;
    }
}
