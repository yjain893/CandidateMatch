// Recalculates the overall Score__c of every scored match from its stored component scores, rounding halves UP. The old code rounded
// half-even (98.5 -> 98, 97.5 -> 98), so a candidate who scored a point higher could show the same score as one below.
// Makes NO AI calls and changes only Score__c, and only where the recalculated score differs. Matches whose score was capped
// ("no matched skill could be verified") are left alone. Safe to run again.
// Run:  sf apex run --file scripts/apex/refresh_scores_half_up.apex -o demoOrg | grep REFRESH

List<Candidate_Match__c> changed = new List<Candidate_Match__c>();
List<String> lines = new List<String>();
for (Candidate_Match__c m : [SELECT Id, Contact__r.Name, Job__r.Name, Score__c, Skills_Score__c, Experience_Score__c, Fit_Score__c, Education_Score__c, Reasoning__c
                             FROM Candidate_Match__c WHERE Status__c = 'Scored' AND Score__c != null AND Skills_Score__c != null
                             AND Experience_Score__c != null AND Education_Score__c != null LIMIT 5000]) {
    if (m.Reasoning__c != null && m.Reasoning__c.contains('[Score capped')) { continue; }
    Decimal sk = m.Skills_Score__c; Decimal ex = m.Experience_Score__c; Decimal ed = m.Education_Score__c;
    Decimal total = m.Fit_Score__c != null
        ? (sk * CandidateMatchService.W_SKILLS + ex * CandidateMatchService.W_EXPERIENCE + m.Fit_Score__c * CandidateMatchService.W_FIT + ed * CandidateMatchService.W_EDUCATION)
          / (CandidateMatchService.W_SKILLS + CandidateMatchService.W_EXPERIENCE + CandidateMatchService.W_FIT + CandidateMatchService.W_EDUCATION)
        : (sk * CandidateMatchService.W_SKILLS + ex * CandidateMatchService.W_EXPERIENCE + ed * CandidateMatchService.W_EDUCATION)
          / (CandidateMatchService.W_SKILLS + CandidateMatchService.W_EXPERIENCE + CandidateMatchService.W_EDUCATION);
    Decimal fresh = total.round(System.RoundingMode.HALF_UP);
    if (fresh != m.Score__c) {
        lines.add(m.Job__r.Name + ' | ' + m.Contact__r.Name + ': ' + m.Score__c + ' -> ' + fresh + ' (exact ' + total.setScale(2) + ')');
        m.Score__c = fresh;
        changed.add(m);
    }
}
update changed;
System.debug('REFRESH scores changed: ' + changed.size());
for (String line : lines) { System.debug('REFRESH ' + line); }
