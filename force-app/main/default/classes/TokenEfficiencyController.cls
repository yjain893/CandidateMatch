// Feeds the Token Efficiency section (LWC tokenEfficiencyDashboard): how many tokens one call of each voice agent uses,
// and how much less the Optimized agent uses than the Baseline. Reads only transcripts whose real numbers are saved
// (Actual_Tokens_Status__c = Done). Read-only, runs as the viewing user.
public with sharing class TokenEfficiencyController {

    public static final String UNLABELLED = 'Unlabelled';
    @TestVisible static final Integer MAX_AGENTS = 6;

    public class Point {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String name;
        @AuraEnabled public Decimal total;
    }

    public class AgentStat {
        @AuraEnabled public String agent;
        @AuraEnabled public Integer calls = 0;
        @AuraEnabled public Decimal avgTotal = 0;
        @AuraEnabled public Decimal avgModelInput = 0;
        @AuraEnabled public Decimal avgModelOutput = 0;
        @AuraEnabled public Decimal avgModelThought = 0;
        @AuraEnabled public Decimal avgVoice = 0;
        @AuraEnabled public Decimal minTotal = 0;
        @AuraEnabled public Decimal maxTotal = 0;
        @AuraEnabled public Decimal avgTurns = 0;
        @AuraEnabled public List<Point> points = new List<Point>();
    }

    public class Result {
        @AuraEnabled public List<AgentStat> agents = new List<AgentStat>();
        // (Baseline average - Optimized average) / Baseline average * 100; null unless both agents have calls.
        @AuraEnabled public Decimal percentFewer;
        // Baseline average - Optimized average, tokens per call.
        @AuraEnabled public Decimal tokensSaved;
    }

    // perAgent: how many of the latest calls to take for EACH agent (1 to 200). includeUnlabelled: also show calls with no label.
    @AuraEnabled(cacheable=true)
    public static Result load(Integer perAgent, Boolean includeUnlabelled) {
        Integer lim = perAgent == null ? 20 : Math.max(1, Math.min(perAgent, 200));
        Result result = new Result();

        Set<String> names = new Set<String>();
        for (AggregateResult g : [
            SELECT Voice_Agent_Name__c agentName FROM Chat_Conversation__c
            WHERE Actual_Tokens_Status__c = 'Done' WITH USER_MODE GROUP BY Voice_Agent_Name__c
        ]) {
            String n = label((String) g.get('agentName'));
            if (n != UNLABELLED || includeUnlabelled == true) {
                names.add(n);
            }
        }
        List<String> ordered = orderAgents(names);
        for (Integer i = 0; i < ordered.size() && i < MAX_AGENTS; i++) {
            result.agents.add(statFor(ordered[i], lim));
        }
        AgentStat baseline;
        AgentStat optimized;
        for (AgentStat s : result.agents) {
            if (s.agent == 'Baseline') { baseline = s; }
            if (s.agent == 'Optimized') { optimized = s; }
        }
        if (baseline != null && optimized != null && baseline.avgTotal > 0) {
            result.tokensSaved = baseline.avgTotal - optimized.avgTotal;
            result.percentFewer = ((baseline.avgTotal - optimized.avgTotal) * 100 / baseline.avgTotal).setScale(1);
        }
        return result;
    }

    // Baseline first, Optimized second, other agents by name, Unlabelled last.
    @TestVisible
    static List<String> orderAgents(Set<String> names) {
        List<String> others = new List<String>();
        for (String n : names) {
            if (n != 'Baseline' && n != 'Optimized' && n != UNLABELLED) { others.add(n); }
        }
        others.sort();
        List<String> out = new List<String>();
        if (names.contains('Baseline')) { out.add('Baseline'); }
        if (names.contains('Optimized')) { out.add('Optimized'); }
        out.addAll(others);
        if (names.contains(UNLABELLED)) { out.add(UNLABELLED); }
        return out;
    }

    private static AgentStat statFor(String name, Integer lim) {
        AgentStat s = new AgentStat();
        s.agent = name;
        String soql = 'SELECT Id, Name, Actual_Model_Input_Tokens__c, Actual_Model_Output_Tokens__c, Actual_Model_Thought_Tokens__c, '
            + 'Actual_Voice_Input_Tokens__c, Actual_Voice_Output_Tokens__c, Actual_Total_Tokens__c, Message_Count__c '
            + 'FROM Chat_Conversation__c WHERE Actual_Tokens_Status__c = \'Done\'';
        Map<String, Object> binds = new Map<String, Object>{ 'lim' => lim };
        if (name == UNLABELLED) {
            soql += ' AND Voice_Agent_Name__c = null';
        } else {
            soql += ' AND Voice_Agent_Name__c = :agentName';
            binds.put('agentName', name);
        }
        soql += ' ORDER BY CreatedDate DESC LIMIT :lim';
        List<Chat_Conversation__c> rows = (List<Chat_Conversation__c>) Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);
        Decimal sumTotal = 0; Decimal sumIn = 0; Decimal sumOut = 0; Decimal sumTh = 0; Decimal sumVoice = 0; Decimal sumTurns = 0;
        for (Integer i = rows.size() - 1; i >= 0; i--) { // oldest first
            Chat_Conversation__c c = rows[i];
            Point p = new Point();
            p.recordId = c.Id;
            p.name = c.Name;
            p.total = num(c.Actual_Total_Tokens__c);
            s.points.add(p);
            sumTotal += p.total;
            sumIn += num(c.Actual_Model_Input_Tokens__c);
            sumOut += num(c.Actual_Model_Output_Tokens__c);
            sumTh += num(c.Actual_Model_Thought_Tokens__c);
            sumVoice += num(c.Actual_Voice_Input_Tokens__c) + num(c.Actual_Voice_Output_Tokens__c);
            sumTurns += num(c.Message_Count__c);
            s.minTotal = s.points.size() == 1 ? p.total : Math.min(s.minTotal, p.total);
            s.maxTotal = Math.max(s.maxTotal, p.total);
        }
        s.calls = s.points.size();
        if (s.calls > 0) {
            Decimal n = s.calls;
            s.avgTotal = (sumTotal / n).setScale(0, RoundingMode.HALF_UP);
            s.avgModelInput = (sumIn / n).setScale(0, RoundingMode.HALF_UP);
            s.avgModelOutput = (sumOut / n).setScale(0, RoundingMode.HALF_UP);
            s.avgModelThought = (sumTh / n).setScale(0, RoundingMode.HALF_UP);
            s.avgVoice = (sumVoice / n).setScale(0, RoundingMode.HALF_UP);
            s.avgTurns = (sumTurns / n).setScale(1, RoundingMode.HALF_UP);
        }
        return s;
    }

    @TestVisible
    static String label(String agentName) {
        return String.isBlank(agentName) ? UNLABELLED : agentName.trim();
    }

    private static Decimal num(Decimal v) {
        return v == null ? 0 : v;
    }
}