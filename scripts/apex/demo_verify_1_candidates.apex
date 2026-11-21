// READ-ONLY check 1 of 4 of the demo data (candidates, resume files and resume parsing): creates, changes and deletes nothing.
// Run:  sf apex run --file scripts/apex/demo_verify_1_candidates.apex -o demoOrg | grep VERIFY
// Or paste it into Developer Console > Debug > Open Execute Anonymous Apex, run it, then in the log tick "Debug Only" and filter by VERIFY.
// Every line starts with PASS, WARN or FAIL (INFO is just a number).

String demo = '%@demo-candidates.example';
List<String> out = new List<String>();
Set<Id> demoIds = new Map<Id, Contact>([SELECT Id FROM Contact WHERE Email LIKE :demo]).keySet();

// ------------------------------------------------------------------------------------------------ 1. candidates and resumes
out.add('===== 1. CANDIDATES =====');
Integer total = demoIds.size();
Integer withResume = [SELECT COUNT() FROM Contact WHERE Email LIKE :demo AND Has_Resume__c = true];
out.add((total >= 12 ? 'PASS ' : 'FAIL ') + 'demo candidates: ' + total + ' (12 hand-written + the bulk ones), with Has Resume: ' + withResume + ', without: ' + (total - withResume) + ' (1 without is expected: Nathan Roy)');

Set<Id> withFile = new Set<Id>();
for (ContentDocumentLink l : [SELECT LinkedEntityId FROM ContentDocumentLink WHERE LinkedEntityId IN :demoIds]) { withFile.add(l.LinkedEntityId); }
out.add((withFile.size() == withResume ? 'PASS ' : 'FAIL ') + 'candidates with a PDF resume file attached: ' + withFile.size() + ' of ' + withResume);

Integer noCity = [SELECT COUNT() FROM Contact WHERE Email LIKE :demo AND City__c = null];
Integer noMode = [SELECT COUNT() FROM Contact WHERE Email LIKE :demo AND Work_Modes__c = null];
Integer noSalary = [SELECT COUNT() FROM Contact WHERE Email LIKE :demo AND Expected_Salary__c = null];
out.add((noCity + noMode + noSalary == 0 ? 'PASS ' : 'FAIL ') + 'city / work mode / expected salary missing on: ' + noCity + ' / ' + noMode + ' / ' + noSalary);
Integer noRole = [SELECT COUNT() FROM Contact WHERE Email LIKE :demo AND Role_Types__c = null];
out.add((noRole == 0 ? 'PASS ' : 'WARN ') + 'candidates without a Role Types value: ' + noRole + (noRole == 0 ? '' : ' (are the executive Role Types values deployed?)'));

// ------------------------------------------------------------------------------------------------ 2. resume parsing
out.add('===== 2. RESUME PARSING =====');
Map<String, Integer> byStatus = new Map<String, Integer>();
for (AggregateResult r : [SELECT Resume_Parse_Status__c s, COUNT(Id) n FROM Contact WHERE Email LIKE :demo AND Has_Resume__c = true GROUP BY Resume_Parse_Status__c]) {
    byStatus.put(String.valueOf(r.get('s')), (Integer) r.get('n'));
}
out.add('INFO parse status of the candidates with a resume: ' + byStatus + '   (null = not parsed yet)');
Integer parsed = (byStatus.containsKey('Parsed') ? byStatus.get('Parsed') : 0);
Integer review = (byStatus.containsKey('Review') ? byStatus.get('Review') : 0);
Integer failed = (byStatus.containsKey('Failed') ? byStatus.get('Failed') : 0);
Integer waiting = withResume - parsed - review - failed;
out.add((waiting == 0 ? 'PASS ' : 'WARN ') + 'still to parse (empty or Pending): ' + waiting + (waiting == 0 ? '' : ' - the parse batch is not finished or was not started'));
out.add((failed == 0 ? 'PASS ' : 'FAIL ') + 'parse FAILED: ' + failed);
out.add((review == 0 ? 'PASS ' : 'WARN ') + 'parsed but NEEDS REVIEW (they do not show in the matcher results): ' + review);
for (Contact c : [SELECT Name, Resume_Parse_Status__c, Resume_Parse_Error__c FROM Contact WHERE Email LIKE :demo AND Resume_Parse_Status__c IN ('Failed', 'Review') ORDER BY Resume_Parse_Status__c, Name LIMIT 10]) {
    out.add('     ' + c.Resume_Parse_Status__c + ': ' + c.Name + ' - ' + c.Resume_Parse_Error__c);
}
String pass = parsed + review > 0 ? 'PASS ' : 'WARN ';        // a check on parsed candidates cannot pass before any is parsed
Integer noStamp = [SELECT COUNT() FROM Contact WHERE Email LIKE :demo AND Resume_Parse_Status__c IN ('Parsed', 'Review') AND (Resume_Parsed_On__c = null OR Total_Experience_Years__c = null)];
out.add((noStamp == 0 ? pass : 'FAIL ') + 'parsed candidates without Resume Parsed On or Total Experience Years: ' + noStamp);
Integer blankProfile = 0; Integer sampled = 0;
for (Contact c : [SELECT Candidate_Profile__c FROM Contact WHERE Email LIKE :demo AND Resume_Parse_Status__c IN ('Parsed', 'Review') LIMIT 40]) {
    sampled++;
    if (String.isBlank(c.Candidate_Profile__c) || !c.Candidate_Profile__c.contains('Skills:')) { blankProfile++; }
}
out.add((blankProfile == 0 ? pass : 'FAIL ') + 'Candidate Profile filled with skills, checked on ' + sampled + ' parsed candidates: ' + blankProfile + ' empty');

for (String line : out) { System.debug('VERIFY ' + line); }
