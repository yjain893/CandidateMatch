// READ-ONLY check 3 of 4 of the demo data (job requirements extracted from the job descriptions): creates, changes and deletes nothing.
// Run:  sf apex run --file scripts/apex/demo_verify_3_jobs.apex -o demoOrg | grep VERIFY
// Or paste it into Developer Console > Debug > Open Execute Anonymous Apex, run it, then in the log tick "Debug Only" and filter by VERIFY.
// Every line starts with PASS, WARN or FAIL (INFO is just a number).

List<String> out = new List<String>();

// ------------------------------------------------------------------------------------------------ 4. jobs
out.add('===== 4. JOB REQUIREMENTS =====');
Set<String> bareVendors = new Set<String>{ 'salesforce', 'aws', 'microsoft', 'google', 'oracle', 'sap' };
List<Job__c> jobs = [SELECT Id, Name, City__c, Work_Modes__c, Expected_Salary__c, Role_Types__c, Min_Experience_Years__c, Required_Skills__c,
                            Nice_To_Have_Skills__c, Skill_Map__c, Requirements_Hash__c, Requirements_Extracted_On__c
                     FROM Job__c WHERE Name LIKE 'DEMO - %' ORDER BY Name];
out.add((jobs.size() == 6 ? 'PASS ' : 'WARN ') + 'demo jobs: ' + jobs.size() + ' (6 expected)');
Map<Id, CandidateMatcherV2Controller.JobSkills> skillsOfJob = new Map<Id, CandidateMatcherV2Controller.JobSkills>();
for (Job__c j : jobs) {
    Boolean extracted = j.Requirements_Hash__c != null && j.Requirements_Extracted_On__c != null;
    if (!extracted) { out.add('FAIL ' + j.Name + ': requirements NOT extracted yet'); continue; }
    CandidateMatcherV2Controller.JobSkills js = CandidateMatcherV2Controller.getJobSkills(j.Id);
    skillsOfJob.put(j.Id, js);
    Integer listed = js.required.size() + js.niceToHave.size();
    Integer mapKeys = 0; Integer aliases = 0; Integer noAlias = 0; Boolean mapOk = true;
    try {
        Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(j.Skill_Map__c);
        mapKeys = m.size();
        for (String k : m.keySet()) { Integer n = ((List<Object>) m.get(k)).size(); aliases += n; if (n == 0) { noAlias++; } }
    } catch (Exception e) { mapOk = false; }
    List<String> vendor = new List<String>();
    for (String s : js.required) { if (bareVendors.contains(s.toLowerCase().trim())) { vendor.add(s); } }
    for (String s : js.niceToHave) { if (bareVendors.contains(s.toLowerCase().trim())) { vendor.add(s); } }
    out.add((js.required.size() >= 3 && mapOk && mapKeys >= listed && vendor.isEmpty() ? 'PASS ' : 'FAIL ') + j.Name + ': ' + js.required.size() + ' required + ' + js.niceToHave.size()
        + ' nice-to-have skills, skill map ' + (mapOk ? mapKeys + ' entries / ' + aliases + ' aliases (' + noAlias + ' skills with none)' : 'NOT valid JSON')
        + (vendor.isEmpty() ? '' : ', bare vendor name listed as a skill: ' + vendor));
    out.add('     ' + (j.City__c == null ? 'no city' : j.City__c) + ' | ' + j.Work_Modes__c + ' | min ' + j.Min_Experience_Years__c + ' years | $' + j.Expected_Salary__c + ' | role ' + j.Role_Types__c);
    out.add('     required: ' + String.join(js.required, ', '));
}

for (String line : out) { System.debug('VERIFY ' + line); }
