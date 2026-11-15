/**
 * The only class that touches AiJobRun / AiJobRunItem (Prompt Template Batch Processing).
 * 1 AiJobRun = one prompt template + many AiJobRunItems (one per contact / candidate).
 */
public with sharing class AiJobGateway {
    public static final Integer MAX_ITEMS_PER_RUN = 1000; // standard models; 10,000 for native-batch models

    public class RunInfo {
        public String runId;
        public List<String> itemIds = new List<String>(); // same order as the payloads
    }
    public class ItemResult {
        public String itemId;
        public String status;       // Completed | Failed | other (still running)
        public String response;     // {"promptResponse":"<text>"}
        public String errorMessage;
    }

    @TestVisible private static Boolean testMode = false;
    private static Integer testSeq = 0;
    @TestVisible private static Map<String, ItemResult> testResults;

    /** Creates the run (New), inserts one item per payload (Ready), then flips the run to ReadyToStart. */
    public static RunInfo start(String templateDevName, List<Map<String, Object>> payloads) {
        if (payloads.isEmpty()) { throw new PromptRunner.PromptException('Nothing to submit'); }
        if (payloads.size() > MAX_ITEMS_PER_RUN) {
            throw new PromptRunner.PromptException('Too many items for one AiJobRun: ' + payloads.size());
        }
        RunInfo info = new RunInfo();
        if (Test.isRunningTest() && testMode) {
            info.runId = 'TESTRUN' + (testSeq++);
            for (Integer i = 0; i < payloads.size(); i++) { info.itemIds.add('TESTITEM-' + (testSeq++)); }
            return info;
        }
        AiJobRun jobRun = new AiJobRun(JobType = 'PromptTemplate', Target = templateDevName, Status = 'New');
        insert as user jobRun;

        List<AiJobRunItem> items = new List<AiJobRunItem>();
        for (Map<String, Object> p : payloads) {
            items.add(new AiJobRunItem(AiJobRunId = jobRun.Id, Status = 'Ready', Input = JSON.serialize(p)));
        }
        insert as user items;

        jobRun.Status = 'ReadyToStart';
        update as user jobRun;

        info.runId = String.valueOf(jobRun.Id);
        for (AiJobRunItem it : items) { info.itemIds.add(String.valueOf(it.Id)); }
        return info;
    }

    /** Reads results of finished items. */
    public static Map<String, ItemResult> fetch(Set<String> itemIds) {
        if (Test.isRunningTest() && testResults != null) { return testResults; }
        Set<Id> ids = new Set<Id>();
        for (String s : itemIds) { ids.add((Id) s); }
        Map<String, ItemResult> out = new Map<String, ItemResult>();
        for (AiJobRunItem i : [
            SELECT Id, Status, Response, ErrorMessage FROM AiJobRunItem WHERE Id IN :ids WITH SYSTEM_MODE
        ]) {
            ItemResult r = new ItemResult();
            r.itemId = String.valueOf(i.Id);
            r.status = i.Status;
            r.response = i.Response;
            r.errorMessage = i.ErrorMessage;
            out.put(r.itemId, r);
        }
        return out;
    }

    /** Response comes wrapped as {"promptResponse":"<LLM text>"}; unwrap it. */
    public static String unwrap(String responseJson) {
        if (String.isBlank(responseJson)) { throw new PromptRunner.PromptException('Empty AI response'); }
        try {
            Object o = JSON.deserializeUntyped(responseJson);
            if (o instanceof Map<String, Object>) {
                Object t = ((Map<String, Object>) o).get('promptResponse');
                if (t != null) { return String.valueOf(t); }
            }
        } catch (Exception e) { /* not an envelope: fall through */ }
        return responseJson;
    }
}
