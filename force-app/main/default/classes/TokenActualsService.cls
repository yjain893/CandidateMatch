// Reads the REAL token counts of a voice call from Google Cloud Logging and adds them up.
//
// How: Google writes one log entry per turn in the log ces.googleapis.com/responses, labelled with the
// session id. Each entry has a tree of "spans". Spans named LLM carry the model's token counts, spans
// named TTS carry the voice's. We add them over all turns. The Guardrail span has no token counts in
// Google's log, so the guardrail model is NOT included.
//
// Login to Google: Named Credential Google_Logging_API (service account, read-only Logs Viewer).
// The Google project id is read from the Custom Metadata record Token_Log_Config__mdt.Default.
// This class never stores or returns any call text; it only reads numbers.
public with sharing class TokenActualsService {

    public class TokenActualsException extends Exception {}

    public class Totals {
        public Long modelIn = 0;
        public Long modelOut = 0;
        public Long modelThought = 0;
        public Long voiceIn = 0;
        public Long voiceOut = 0;
        public Integer entries = 0;
        public Integer llmSpans = 0;
        public Integer ttsSpans = 0;
        public Boolean truncated = false;
        public Long total() {
            return modelIn + modelOut + modelThought + voiceIn + voiceOut;
        }
    }

    @TestVisible static final String ENDPOINT = 'callout:Google_Logging_API/v2/entries:list';
    @TestVisible static final Integer PAGE_SIZE = 100;
    @TestVisible static final Integer MAX_PAGES = 10;
    static final Integer MAX_DEPTH = 20;
    static final Pattern SESSION_ID = Pattern.compile('^[A-Za-z0-9_\\-]{1,100}$');

    // Tests cannot create custom metadata records, so they set this instead.
    @TestVisible static String projectIdOverride;

    public static String projectId() {
        if (String.isNotBlank(projectIdOverride)) {
            return projectIdOverride;
        }
        Token_Log_Config__mdt cfg = Token_Log_Config__mdt.getInstance('Default');
        if (cfg == null || String.isBlank(cfg.Project_Id__c)) {
            throw new TokenActualsException('Token_Log_Config__mdt record "Default" with Project_Id__c is missing.');
        }
        return cfg.Project_Id__c.trim();
    }

    // Asks Google for every log entry of one session (all pages) and adds up the token counts.
    // anchor = when the transcript was saved (the end of the call). Only log entries from 3 hours before
    // to 3 hours after are searched: without a time window Google scans a huge range and answers slowly
    // with empty pages (about 36 s per call instead of about 1 s).
    public static Totals fetchTotals(String sessionId, Datetime anchor) {
        if (String.isBlank(sessionId) || !SESSION_ID.matcher(sessionId).matches()) {
            throw new TokenActualsException('The conversation identifier is not a valid session id.');
        }
        String project = projectId();
        if (anchor == null) {
            throw new TokenActualsException('No time given for the log search.');
        }
        String fmt = 'yyyy-MM-dd\'T\'HH:mm:ss\'Z\'';
        String filter = 'logName="projects/' + project + '/logs/ces.googleapis.com%2Fresponses"'
            + ' AND labels.session_id="' + sessionId + '"'
            + ' AND timestamp>="' + anchor.addHours(-3).formatGmt(fmt) + '"'
            + ' AND timestamp<="' + anchor.addHours(3).formatGmt(fmt) + '"';
        Totals totals = new Totals();
        Set<String> seen = new Set<String>();
        String pageToken = null;
        Integer pages = 0;
        do {
            Map<String, Object> body = new Map<String, Object>{
                'resourceNames' => new List<String>{ 'projects/' + project },
                'filter' => filter,
                'orderBy' => 'timestamp asc',
                'pageSize' => PAGE_SIZE
            };
            if (pageToken != null) {
                body.put('pageToken', pageToken);
            }
            HttpRequest req = new HttpRequest();
            req.setEndpoint(ENDPOINT);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(30000);
            req.setBody(JSON.serialize(body));
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) {
                throw new TokenActualsException('Google returned status ' + res.getStatusCode() + errorSummary(res.getBody()));
            }
            Object parsed = JSON.deserializeUntyped(res.getBody());
            Map<String, Object> top = parsed instanceof Map<String, Object> ? (Map<String, Object>) parsed : new Map<String, Object>();
            Object entryList = top.get('entries');
            if (entryList instanceof List<Object>) {
                absorbEntries((List<Object>) entryList, totals, seen);
            }
            Object next = top.get('nextPageToken');
            pageToken = next == null ? null : String.valueOf(next);
            pages++;
        } while (pageToken != null && pages < MAX_PAGES);
        if (pageToken != null) {
            totals.truncated = true;
        }
        return totals;
    }

    // Adds the token counts of the given log entries. Entries seen before (same insertId) are skipped.
    @TestVisible
    static void absorbEntries(List<Object> entries, Totals totals, Set<String> seen) {
        for (Object item : entries) {
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> entry = (Map<String, Object>) item;
            Object insertId = entry.get('insertId');
            if (insertId != null && !seen.add(String.valueOf(insertId))) {
                continue;
            }
            totals.entries++;
            Object payload = entry.get('jsonPayload');
            if (!(payload instanceof Map<String, Object>)) {
                continue;
            }
            Object info = ((Map<String, Object>) payload).get('diagnosticInfo');
            if (!(info instanceof Map<String, Object>)) {
                continue;
            }
            absorbSpan(((Map<String, Object>) info).get('rootSpan'), totals, 0);
        }
    }

    // Walks one span and all spans inside it (Tool spans can hold other spans).
    static void absorbSpan(Object span, Totals totals, Integer depth) {
        if (!(span instanceof Map<String, Object>) || depth > MAX_DEPTH) {
            return;
        }
        Map<String, Object> s = (Map<String, Object>) span;
        String name = s.get('name') == null ? '' : String.valueOf(s.get('name'));
        Object attrObj = s.get('attributes');
        Map<String, Object> attrs = attrObj instanceof Map<String, Object> ? (Map<String, Object>) attrObj : new Map<String, Object>();
        if (name == 'LLM') {
            totals.llmSpans++;
            totals.modelIn += num(attrs.get('input token count'));
            totals.modelOut += num(attrs.get('output token count'));
            totals.modelThought += num(attrs.get('thought token count'));
        } else if (name == 'TTS') {
            // The TTS span lists the same numbers twice ("input token count" and "tts input token count").
            // We take only the "tts ..." pair so nothing is counted double.
            totals.ttsSpans++;
            totals.voiceIn += num(attrs.get('tts input token count'));
            totals.voiceOut += num(attrs.get('tts output token count'));
        }
        Object kids = s.get('childSpans');
        if (kids instanceof List<Object>) {
            for (Object kid : (List<Object>) kids) {
                absorbSpan(kid, totals, depth + 1);
            }
        }
    }

    static Long num(Object value) {
        if (value == null) {
            return 0;
        }
        try {
            return Decimal.valueOf(String.valueOf(value)).longValue();
        } catch (Exception e) {
            return 0;
        }
    }

    // Short, safe description of a Google error: only the error message, never more than 150 letters.
    static String errorSummary(String body) {
        try {
            Object parsed = JSON.deserializeUntyped(body);
            if (parsed instanceof Map<String, Object>) {
                Object err = ((Map<String, Object>) parsed).get('error');
                if (err instanceof Map<String, Object>) {
                    Object msg = ((Map<String, Object>) err).get('message');
                    if (msg != null) {
                        return ': ' + String.valueOf(msg).left(150);
                    }
                }
            }
        } catch (Exception e) {
            // not JSON: say nothing more
        }
        return '';
    }

    // Puts the totals and a status on the record. Does not save it.
    public static void apply(Chat_Conversation__c record, Totals totals) {
        record.Actual_Tokens_Checked_At__c = System.now();
        if (totals.entries == 0) {
            record.Actual_Tokens_Status__c = 'No log entries';
            return;
        }
        if (totals.llmSpans == 0 && totals.ttsSpans == 0) {
            record.Actual_Tokens_Status__c = 'No token counts found';
            return;
        }
        record.Actual_Model_Input_Tokens__c = totals.modelIn;
        record.Actual_Model_Output_Tokens__c = totals.modelOut;
        record.Actual_Model_Thought_Tokens__c = totals.modelThought;
        record.Actual_Voice_Input_Tokens__c = totals.voiceIn;
        record.Actual_Voice_Output_Tokens__c = totals.voiceOut;
        record.Actual_Total_Tokens__c = totals.total();
        record.Actual_Tokens_Status__c = totals.truncated ? 'Partial: more than ' + (PAGE_SIZE * MAX_PAGES) + ' log entries' : 'Done';
    }

    public static void applyError(Chat_Conversation__c record, Exception e) {
        record.Actual_Tokens_Checked_At__c = System.now();
        record.Actual_Tokens_Status__c = ('Error: ' + e.getMessage()).left(255);
    }
}
