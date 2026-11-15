/** Applies finished AiJobRunItem results to Salesforce records. Safe to call twice: items are marked Processed__c. */
public without sharing class AiJobResultService {

    /** Returns how many items were handled. Items still running are left untouched for a later pass. */
    public static Integer apply(List<AI_Item_Map__c> maps, Map<String, AiJobGateway.ItemResult> results) {
        List<AI_Item_Map__c> resumeMaps = new List<AI_Item_Map__c>();
        List<AI_Item_Map__c> matchMaps = new List<AI_Item_Map__c>();
        for (AI_Item_Map__c m : maps) {
            AiJobGateway.ItemResult r = results.get(m.Item_Id__c);
            if (r == null || (r.status != 'Completed' && r.status != 'Failed')) { continue; }
            if (m.Kind__c == 'RESUME') { resumeMaps.add(m); }
            else if (m.Kind__c == 'MATCH') { matchMaps.add(m); }
        }
        applyResumes(resumeMaps, results);
        applyMatches(matchMaps, results);

        List<AI_Item_Map__c> done = new List<AI_Item_Map__c>();
        for (AI_Item_Map__c m : resumeMaps) { m.Processed__c = true; done.add(m); }
        for (AI_Item_Map__c m : matchMaps) { m.Processed__c = true; done.add(m); }
        if (!done.isEmpty()) { update done; }
        return done.size();
    }

    private static void applyResumes(List<AI_Item_Map__c> maps, Map<String, AiJobGateway.ItemResult> results) {
        if (maps.isEmpty()) { return; }
        List<Id> contactIds = new List<Id>();
        Map<Id, ResumeParserService.ParsedResume> parsed = new Map<Id, ResumeParserService.ParsedResume>();
        Map<Id, String> errors = new Map<Id, String>();
        for (AI_Item_Map__c m : maps) {
            AiJobGateway.ItemResult r = results.get(m.Item_Id__c);
            contactIds.add(m.Contact__c);
            if (r.status == 'Failed') {
                errors.put(m.Contact__c, r.errorMessage == null ? 'AI item failed' : r.errorMessage);
                continue;
            }
            try {
                parsed.put(m.Contact__c, ResumeParserService.parseText(AiJobGateway.unwrap(r.response)));
            } catch (Exception e) {
                errors.put(m.Contact__c, 'Bad AI response: ' + e.getMessage());
            }
        }
        ResumeParserService.persist(contactIds, parsed, errors);
        // Candidates that were waiting for this resume move on to scoring (or get a clear status).
        CandidateMatchService.onResumesParsed(contactIds);
    }

    private static void applyMatches(List<AI_Item_Map__c> maps, Map<String, AiJobGateway.ItemResult> results) {
        if (maps.isEmpty()) { return; }
        Set<Id> jobIds = new Set<Id>();
        Set<Id> contactIds = new Set<Id>();
        for (AI_Item_Map__c m : maps) { jobIds.add(m.Job__c); contactIds.add(m.Contact__c); }

        Map<Id, Contact> contacts = new Map<Id, Contact>(
            [SELECT Id, Candidate_Profile__c FROM Contact WHERE Id IN :contactIds]);
        Map<Id, Job__c> jobs = new Map<Id, Job__c>(
            [SELECT Id, City__c, Work_Modes__c, Role_Types__c, Expected_Salary__c FROM Job__c WHERE Id IN :jobIds]);
        Map<String, Candidate_Match__c> existing = new Map<String, Candidate_Match__c>();
        for (Candidate_Match__c cm : [
            SELECT Id, Job__c, Contact__c FROM Candidate_Match__c WHERE Job__c IN :jobIds AND Contact__c IN :contactIds
        ]) { existing.put(cm.Job__c + '|' + cm.Contact__c, cm); }

        List<Candidate_Match__c> toSave = new List<Candidate_Match__c>();
        for (AI_Item_Map__c m : maps) {
            AiJobGateway.ItemResult r = results.get(m.Item_Id__c);
            Candidate_Match__c prior = existing.get(m.Job__c + '|' + m.Contact__c);
            if (r.status != 'Completed') { markFailed(prior, toSave, 'Failed: AI scoring'); continue; }
            try {
                CandidateMatchService.ScoreResult sr = (CandidateMatchService.ScoreResult) JSON.deserialize(
                    PromptRunner.clean(AiJobGateway.unwrap(r.response)), CandidateMatchService.ScoreResult.class);
                Contact c = contacts.get(m.Contact__c);
                Job__c j = jobs.get(m.Job__c);
                toSave.add(CandidateMatchService.buildMatch(m.Job__c, m.Contact__c, sr,
                    c == null ? '' : c.Candidate_Profile__c, prior, j != null && CandidateMatchService.useFit(j)));
            } catch (Exception e) {
                markFailed(prior, toSave, 'Failed: bad AI response');
            }
        }
        if (!toSave.isEmpty()) { upsert toSave; }
    }

    private static void markFailed(Candidate_Match__c row, List<Candidate_Match__c> out, String status) {
        if (row == null) { return; }
        row.Status__c = status;
        out.add(row);
    }
}
