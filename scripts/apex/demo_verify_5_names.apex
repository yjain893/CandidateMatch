// READ-ONLY: lists, for each demo job, the candidates the matcher screen shows when it opens: the job's own filters (city, work mode, salary,
// role type) plus ALL of the job's required skills selected. Creates, changes and deletes nothing.
// Run:  sf apex run --file scripts/apex/demo_verify_5_names.apex -o demoOrg | grep VERIFY
// Or paste it into Developer Console > Debug > Open Execute Anonymous Apex, run it, then in the log tick "Debug Only" and filter by VERIFY.

List<String> out = new List<String>();
for (Job__c j : [SELECT Id, Name, City__c, Work_Modes__c, Expected_Salary__c, Role_Types__c FROM Job__c WHERE Name LIKE 'DEMO - %' ORDER BY Name]) {
    CandidateMatcherV2Controller.JobSkills js = CandidateMatcherV2Controller.getJobSkills(j.Id);
    CandidateMatchOrchestrator.Filters f = CandidateMatchOrchestrator.fromJob(j);      // the filters the screen starts with
    f.jobId = j.Id;
    f.skills = js.required;                                                              // the job's required skills start selected
    try {
        List<Contact> hits = CandidateMatchOrchestrator.findCandidates(f, 200);
        out.add((hits.isEmpty() ? 'FAIL ' : 'PASS ') + j.Name + ': ' + hits.size() + ' candidates (' + (j.City__c == null ? 'any city' : j.City__c) + ', '
            + j.Work_Modes__c + ', up to $' + j.Expected_Salary__c + ', ' + js.required.size() + ' required skills)');
        for (Contact c : [SELECT Name, City__c, Work_Modes__c, Expected_Salary__c, Total_Experience_Years__c, Date_Available__c FROM Contact
                          WHERE Id IN :hits ORDER BY Name]) {
            out.add('     ' + c.Name + ' | ' + c.City__c + ' | ' + c.Work_Modes__c + ' | $' + c.Expected_Salary__c + ' | ' + c.Total_Experience_Years__c
                + ' years | available ' + (Date.today().daysBetween(c.Date_Available__c) <= 0 ? 'now' : 'in ' + Date.today().daysBetween(c.Date_Available__c) + ' days'));
        }
    } catch (Exception e) {
        out.add('FAIL ' + j.Name + ': ' + e.getMessage());
    }
}
for (String line : out) { System.debug('VERIFY ' + line); }
