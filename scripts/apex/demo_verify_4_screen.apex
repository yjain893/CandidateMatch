// READ-ONLY check 4 of 4 of the demo data (what the matcher screen shows for ONE job): creates, changes and deletes nothing.
// Change jobName to check another job, one at a time (each run counts candidates three times, which uses many queries).
// Run:  sf apex run --file scripts/apex/demo_verify_4_screen.apex -o demoOrg | grep VERIFY
// Or paste it into Developer Console > Debug > Open Execute Anonymous Apex, run it, then in the log tick "Debug Only" and filter by VERIFY.
// Jobs: Chief Technology Officer | Chief Financial Officer | Chief Information Security Officer | Chief Revenue Officer | Vice President of Operations | Chief Data Officer

String jobName = 'Chief Technology Officer';
List<String> out = new List<String>();
Job__c j = [SELECT Id, Name, City__c, Work_Modes__c, Expected_Salary__c, Role_Types__c FROM Job__c WHERE Name = :('DEMO - ' + jobName) LIMIT 1];
CandidateMatcherV2Controller.JobSkills js = CandidateMatcherV2Controller.getJobSkills(j.Id);
List<String> options = new List<String>(js.required);
options.addAll(js.niceToHave);
out.add('===== ' + j.Name + ': what the screen shows =====');
try {
    CandidateMatchOrchestrator.Filters f = CandidateMatchOrchestrator.fromJob(j);      // the filters the screen starts with
    f.jobId = j.Id;
    f.skillOptions = options;
    f.skills = new List<String>();
    CandidateMatcherV2Controller.MatchCount none = CandidateMatcherV2Controller.countMatches(JSON.serialize(f));
    f.skills = js.required;
    CandidateMatcherV2Controller.MatchCount all = CandidateMatcherV2Controller.countMatches(JSON.serialize(f));
    f.skills = new List<String>();
    f.maxSalary = null;
    CandidateMatcherV2Controller.MatchCount noSal = CandidateMatcherV2Controller.countMatches(JSON.serialize(f));
    out.add((all.matched != null && all.matched > 0 ? 'PASS ' : 'WARN ') + 'pool ' + none.pool + ' (work mode, city, salary, role) -> ' + all.matched
        + ' have ALL ' + js.required.size() + ' required skills; not parsed yet: ' + all.notParsed + '; pool without the salary limit: ' + noSal.pool);
    out.add('     filters: ' + (j.City__c == null ? 'any city' : j.City__c) + ' | ' + j.Work_Modes__c + ' | up to $' + j.Expected_Salary__c + ' | role ' + j.Role_Types__c);
    List<String> counts = new List<String>();
    for (CandidateMatcherV2Controller.SkillCount sc : none.skills) { counts.add(sc.name + ' ' + sc.count); }
    if (!counts.isEmpty()) { out.add('     per skill, of the pool: ' + String.join(counts, ' | ')); }
    List<String> days = new List<String>();
    for (CandidateMatcherV2Controller.DateCount dc : all.dates) { days.add('within ' + dc.days + ' days ' + dc.count); }
    if (!days.isEmpty()) { out.add('     of those with all required skills, available: ' + String.join(days, ' | ')); }
} catch (Exception e) {
    out.add('FAIL the screen would show an error: ' + e.getMessage());
}
for (String line : out) { System.debug('VERIFY ' + line); }
