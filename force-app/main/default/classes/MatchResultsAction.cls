/** Agent action: read the best scored matches for a job. */
public with sharing class MatchResultsAction {
    public class Request {
        @InvocableVariable(required=true label='Job Id' description='Id of the Job record')
        public Id jobId;
        @InvocableVariable(label='Top N' description='How many candidates to return (default 10, max 50)')
        public Integer topN;
    }
    public class Response {
        @InvocableVariable(label='Ranked Candidates' description='Candidates sorted by match score, highest first')
        public String rankedList;
        @InvocableVariable(label='Count')
        public Integer resultCount;
    }

    @InvocableMethod(label='Get Top Candidates for Job'
        description='Returns the best matching candidates for a job, highest score first, with reasoning.')
    public static List<Response> run(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request r : requests) {
            List<Candidate_Match__c> rows = CandidateMatchService.getRanked(r.jobId, r.topN);
            Response res = new Response();
            res.resultCount = rows.size();
            if (rows.isEmpty()) {
                res.rankedList = 'No scored candidates yet. Run Start Candidate Matching for Job first, then ask again in a few minutes.';
            } else {
                List<String> lines = new List<String>();
                Integer i = 1;
                for (Candidate_Match__c m : rows) {
                    lines.add(i + '. ' + m.Contact__r.Name + ' (' + m.Contact__c + ') - ' + m.Score__c + '/100 (skills '
                        + m.Skills_Score__c + ', experience ' + m.Experience_Score__c + ', fit '
                        + (m.Fit_Score__c == null ? 'n/a' : String.valueOf(m.Fit_Score__c)) + ', education ' + m.Education_Score__c + ')'
                        + (m.Needs_Review__c ? ' [needs human review]' : '') + '. '
                        + (m.Reasoning__c == null ? '' : m.Reasoning__c)
                        + ' Matched: ' + (String.isBlank(m.Matched_Skills__c) ? '-' : m.Matched_Skills__c)
                        + '. Missing: ' + (String.isBlank(m.Missing_Skills__c) ? '-' : m.Missing_Skills__c) + '.');
                    i++;
                }
                res.rankedList = String.join(lines, '\n');
            }
            out.add(res);
        }
        return out;
    }
}
