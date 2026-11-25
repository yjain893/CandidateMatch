/**
 * Creates a Case from a saved call transcript (Chat_Conversation__c).
 * Calls the prompt template Create_Case_From_Transcript, checks the category
 * against the live Case.Category__c picklist, and links the Case to the transcript.
 * Does not touch Is_Classified__c.
 */
public with sharing class CaseFromTranscript {
    public static final String TEMPLATE = 'Create_Case_From_Transcript';
    public static final String FALLBACK_CATEGORY = 'Other';

    @TestVisible static String mockResponse;
    @TestVisible static String mockError;

    public class Request {
        @InvocableVariable(label='Chat Conversation Id' required=true)
        public Id conversationId;
    }
    public class Result {
        @InvocableVariable public Id caseId;
        @InvocableVariable public String category;
        @InvocableVariable public String message;
    }
    public class CaseException extends Exception {}

    @InvocableMethod(label='Create Case From Transcript' description='Creates a Case from a Chat Conversation transcript using a prompt template')
    public static List<Result> run(List<Request> requests) {
        List<Result> out = new List<Result>();
        for (Request r : requests) {
            Result res = new Result();
            try {
                Case c = createCase(r.conversationId);
                res.caseId = c.Id;
                res.category = c.Category__c;
                res.message = 'OK';
            } catch (Exception e) {
                res.message = e.getMessage();
            }
            out.add(res);
        }
        return out;
    }

    /** Returns the existing Case for this conversation, or creates one. */
    public static Case createCase(Id conversationId) {
        if (conversationId == null) throw new CaseException('conversationId is required');
        List<Case> existing = [SELECT Id, Category__c FROM Case WHERE Chat_Conversation__c = :conversationId LIMIT 1];
        if (!existing.isEmpty()) return existing[0];

        List<Chat_Conversation__c> convs = [SELECT Id, Transcript__c FROM Chat_Conversation__c WHERE Id = :conversationId LIMIT 1];
        if (convs.isEmpty()) throw new CaseException('Chat Conversation not found: ' + conversationId);

        List<String> allowed = categoryValues();
        Map<String, Object> parsed = parse(generate(conversationId, allowed));

        String subject = asText(parsed.get('subject'));
        if (String.isBlank(subject)) subject = 'Phone call';
        String description = asText(parsed.get('description'));
        String category = pickCategory(asText(parsed.get('category')), allowed);

        Case c = new Case(
            Subject = subject.abbreviate(255),
            Description = description,
            Category__c = category,
            Origin = 'Phone',
            Chat_Conversation__c = conversationId
        );
        insert c;
        return c;
    }

    /** Current Category picklist values, so edits to the picklist are picked up automatically. */
    @TestVisible
    static List<String> categoryValues() {
        List<String> values = new List<String>();
        for (Schema.PicklistEntry e : Case.Category__c.getDescribe().getPicklistValues()) {
            if (e.isActive()) values.add(e.getValue());
        }
        return values;
    }

    /** Returns the matching picklist value (case-insensitive) or the fallback. */
    @TestVisible
    static String pickCategory(String suggested, List<String> allowed) {
        if (suggested != null) {
            for (String v : allowed) {
                if (v.equalsIgnoreCase(suggested.trim())) return v;
            }
        }
        for (String v : allowed) {
            if (v.equalsIgnoreCase(FALLBACK_CATEGORY)) return v;
        }
        return null;
    }

    static String generate(Id conversationId, List<String> allowed) {
        if (mockError != null) throw new CaseException(mockError);
        if (mockResponse != null) return mockResponse;

        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.numGenerations = 1;
        input.additionalConfig.applicationName = 'PromptTemplateGenerationsInvocable';

        ConnectApi.WrappedValue conv = new ConnectApi.WrappedValue();
        conv.value = new Map<String, String>{ 'id' => conversationId };
        ConnectApi.WrappedValue cats = new ConnectApi.WrappedValue();
        cats.value = String.join(allowed, ', ');
        input.inputParams = new Map<String, ConnectApi.WrappedValue>{
            'Input:Conversation' => conv,
            'Input:Categories' => cats
        };

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation r =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(TEMPLATE, input);
        if (r == null || r.generations == null || r.generations.isEmpty()) {
            throw new CaseException('The prompt template returned no text');
        }
        return r.generations[0].text;
    }

    /** Pulls the {...} object out of the model text and parses it. */
    @TestVisible
    static Map<String, Object> parse(String text) {
        if (String.isBlank(text)) throw new CaseException('Empty answer from the prompt template');
        Integer a = text.indexOf('{');
        Integer b = text.lastIndexOf('}');
        if (a < 0 || b <= a) throw new CaseException('No JSON in the answer: ' + text.abbreviate(200));
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(text.substring(a, b + 1));
        } catch (Exception e) {
            throw new CaseException('Could not read the answer as JSON: ' + e.getMessage());
        }
    }

    static String asText(Object o) {
        return o == null ? null : String.valueOf(o).trim();
    }
}
