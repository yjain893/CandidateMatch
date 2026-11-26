public with sharing class CaseTranscriptsForPrompt {

    private static final Integer MAX_TRANSCRIPTS = 3;
    private static final Integer MAX_TEXT = 3000;

    @InvocableMethod(label='Get Case Call Transcripts' description='Returns the saved call transcripts linked to a case as text.')
    public static List<Response> getTranscripts(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            Response res = new Response();
            res.Prompt = buildText(String.isBlank(req.caseId) ? null : (Id) req.caseId);
            responses.add(res);
        }
        return responses;
    }

    private static String buildText(Id caseId) {
        if (caseId == null) {
            return 'NO TRANSCRIPT RECORDS';
        }
        List<String> lines = new List<String>();
        for (Chat_Conversation__c t : [
            SELECT Name, Start_Timestamp__c, Message_Count__c, Transcript__c
            FROM Chat_Conversation__c
            WHERE Case__c = :caseId
            ORDER BY Start_Timestamp__c DESC NULLS LAST
            LIMIT :MAX_TRANSCRIPTS
        ]) {
            lines.add('Call transcript'
                + (t.Start_Timestamp__c != null ? ' | Started: ' + t.Start_Timestamp__c.format() : '')
                + (t.Message_Count__c != null ? ' | Messages: ' + String.valueOf(t.Message_Count__c) : '')
                + (String.isNotBlank(t.Transcript__c) ? ' | Transcript: ' + clip(t.Transcript__c) : ' | Transcript: (empty)'));
        }
        return lines.isEmpty() ? 'NO TRANSCRIPT RECORDS' : String.join(lines, '\n');
    }

    private static String clip(String value) {
        String flat = value.replaceAll('\\s+', ' ').trim();
        return flat.length() > MAX_TEXT ? flat.substring(0, MAX_TEXT) + '...' : flat;
    }

    public class Request {
        @InvocableVariable(required=true)
        public String caseId;
    }

    public class Response {
        @InvocableVariable
        public String Prompt;
    }
}
