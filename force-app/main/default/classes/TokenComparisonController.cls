// Feeds the Token Comparison dashboard (LWC tokenComparisonDashboard): tokens per call and which voice agent made it.
// Reads only transcripts whose real token counts are saved (Actual_Tokens_Status__c = Done). Read-only, runs as the viewing user.
public with sharing class TokenComparisonController {

    public static final String UNLABELLED = 'Unlabelled';

    public class Bar {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String name;
        @AuraEnabled public String identifier;
        @AuraEnabled public String agent;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public Decimal modelInput;
        @AuraEnabled public Decimal modelOutput;
        @AuraEnabled public Decimal modelThought;
        @AuraEnabled public Decimal voiceInput;
        @AuraEnabled public Decimal voiceOutput;
        @AuraEnabled public Decimal total;
    }

    public class Summary {
        @AuraEnabled public String agent;
        @AuraEnabled public Integer calls;
        @AuraEnabled public Decimal avgTotal;
        @AuraEnabled public Decimal avgModelInput;
        @AuraEnabled public Decimal avgModelOutput;
        @AuraEnabled public Decimal avgModelThought;
        @AuraEnabled public Decimal avgVoice;
    }

    public class Result {
        @AuraEnabled public List<Bar> bars = new List<Bar>();
        @AuraEnabled public List<Summary> summaries = new List<Summary>();
        @AuraEnabled public List<String> agents = new List<String>();
        // (Baseline average - Optimized average) / Baseline average * 100. Null unless both agents have calls.
        @AuraEnabled public Decimal percentFewer;
    }

    // agent: empty = all agents, 'Unlabelled' = calls with no label, otherwise the exact agent name.
    @AuraEnabled(cacheable=true)
    public static Result load(String agent, Integer maxBars) {
        Integer lim = maxBars == null ? 30 : Math.max(1, Math.min(maxBars, 100));
        Result result = new Result();

        String soql = 'SELECT Id, Name, Conversation_Identifier__c, Voice_Agent_Name__c, CreatedDate, Actual_Model_Input_Tokens__c, '
            + 'Actual_Model_Output_Tokens__c, Actual_Model_Thought_Tokens__c, Actual_Voice_Input_Tokens__c, '
            + 'Actual_Voice_Output_Tokens__c, Actual_Total_Tokens__c FROM Chat_Conversation__c WHERE Actual_Tokens_Status__c = \'Done\'';
        Map<String, Object> binds = new Map<String, Object>{ 'lim' => lim };
        if (String.isNotBlank(agent)) {
            if (agent == UNLABELLED) {
                soql += ' AND Voice_Agent_Name__c = null';
            } else {
                soql += ' AND Voice_Agent_Name__c = :agentName';
                binds.put('agentName', agent);
            }
        }
        soql += ' ORDER BY CreatedDate DESC LIMIT :lim';
        for (SObject so : Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE)) {
            Chat_Conversation__c c = (Chat_Conversation__c) so;
            Bar b = new Bar();
            b.recordId = c.Id;
            b.name = c.Name;
            b.identifier = c.Conversation_Identifier__c;
            b.agent = label(c.Voice_Agent_Name__c);
            b.createdDate = c.CreatedDate;
            b.modelInput = num(c.Actual_Model_Input_Tokens__c);
            b.modelOutput = num(c.Actual_Model_Output_Tokens__c);
            b.modelThought = num(c.Actual_Model_Thought_Tokens__c);
            b.voiceInput = num(c.Actual_Voice_Input_Tokens__c);
            b.voiceOutput = num(c.Actual_Voice_Output_Tokens__c);
            b.total = num(c.Actual_Total_Tokens__c);
            result.bars.add(b);
        }
        // newest were fetched first; the chart reads left (oldest) to right (newest)
        List<Bar> ordered = new List<Bar>();
        for (Integer i = result.bars.size() - 1; i >= 0; i--) {
            ordered.add(result.bars[i]);
        }
        result.bars = ordered;

        List<AggregateResult> groups = [
            SELECT Voice_Agent_Name__c agentName, COUNT(Id) calls, AVG(Actual_Total_Tokens__c) avgTotal,
                   AVG(Actual_Model_Input_Tokens__c) avgIn, AVG(Actual_Model_Output_Tokens__c) avgOut,
                   AVG(Actual_Model_Thought_Tokens__c) avgThought, AVG(Actual_Voice_Input_Tokens__c) avgVoiceIn,
                   AVG(Actual_Voice_Output_Tokens__c) avgVoiceOut
            FROM Chat_Conversation__c
            WHERE Actual_Tokens_Status__c = 'Done'
            WITH USER_MODE
            GROUP BY Voice_Agent_Name__c
        ];
        Decimal baseline;
        Decimal optimized;
        for (AggregateResult g : groups) {
            Summary s = new Summary();
            s.agent = label((String) g.get('agentName'));
            s.calls = Integer.valueOf(g.get('calls'));
            s.avgTotal = round(num((Decimal) g.get('avgTotal')));
            s.avgModelInput = round(num((Decimal) g.get('avgIn')));
            s.avgModelOutput = round(num((Decimal) g.get('avgOut')));
            s.avgModelThought = round(num((Decimal) g.get('avgThought')));
            s.avgVoice = round(num((Decimal) g.get('avgVoiceIn')) + num((Decimal) g.get('avgVoiceOut')));
            result.summaries.add(s);
            result.agents.add(s.agent);
            if (s.agent == 'Baseline') { baseline = s.avgTotal; }
            if (s.agent == 'Optimized') { optimized = s.avgTotal; }
        }
        result.agents.sort();
        if (baseline != null && optimized != null && baseline > 0) {
            result.percentFewer = ((baseline - optimized) * 100 / baseline).setScale(1);
        }
        return result;
    }

    @TestVisible
    static String label(String agentName) {
        return String.isBlank(agentName) ? UNLABELLED : agentName.trim();
    }

    private static Decimal num(Decimal v) {
        return v == null ? 0 : v;
    }

    private static Decimal round(Decimal v) {
        return v.setScale(0, RoundingMode.HALF_UP);
    }
}
