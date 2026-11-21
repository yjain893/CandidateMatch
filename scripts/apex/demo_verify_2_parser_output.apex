// READ-ONLY check 2 of 4 of the demo data (what the resume parser saved: skills, employment, education): creates, changes and deletes nothing.
// Run:  sf apex run --file scripts/apex/demo_verify_2_parser_output.apex -o demoOrg | grep VERIFY
// Or paste it into Developer Console > Debug > Open Execute Anonymous Apex, run it, then in the log tick "Debug Only" and filter by VERIFY.
// Every line starts with PASS, WARN or FAIL (INFO is just a number).

String demo = '%@demo-candidates.example';
List<String> out = new List<String>();
Set<Id> demoIds = new Map<Id, Contact>([SELECT Id FROM Contact WHERE Email LIKE :demo]).keySet();
Integer total = demoIds.size();
Integer okParsed = [SELECT COUNT() FROM Contact WHERE Email LIKE :demo AND Resume_Parse_Status__c IN ('Parsed', 'Review')];
String pass = okParsed > 0 ? 'PASS ' : 'WARN ';        // a check on parsed candidates cannot pass before any is parsed

// ------------------------------------------------------------------------------------------------ 3. what the parser saved
out.add('===== 3. SKILLS, EMPLOYMENT, EDUCATION SAVED BY THE PARSER =====');
Integer skillRows = [SELECT COUNT() FROM Skill__c WHERE Contact__c IN :demoIds];
Integer withSkills = (Integer) [SELECT COUNT_DISTINCT(Contact__c) c FROM Skill__c WHERE Contact__c IN :demoIds][0].get('c');
Integer withJobs = (Integer) [SELECT COUNT_DISTINCT(Contact__c) c FROM Employment_History__c WHERE Contact__c IN :demoIds][0].get('c');
Integer withSchool = (Integer) [SELECT COUNT_DISTINCT(Contact__c) c FROM Education_History__c WHERE Contact__c IN :demoIds][0].get('c');
out.add((withSkills >= okParsed ? pass : 'FAIL ') + 'candidates with skills saved: ' + withSkills + ' of ' + okParsed + ' parsed (' + skillRows + ' skill rows' + (withSkills == 0 ? '' : ', about ' + (skillRows / withSkills) + ' each') + ')');
out.add((withJobs >= okParsed ? pass : 'WARN ') + 'candidates with employment history: ' + withJobs + ' of ' + okParsed);
out.add((withSchool >= okParsed ? pass : 'WARN ') + 'candidates with education history: ' + withSchool + ' of ' + okParsed);
Integer noKey = [SELECT COUNT() FROM Skill__c WHERE Contact__c IN :demoIds AND Name_Key__c = null];
Integer noStandard = [SELECT COUNT() FROM Skill__c WHERE Contact__c IN :demoIds AND Canonical_Key__c = null];
out.add((noKey == 0 ? pass : 'FAIL ') + 'skill rows without Name Key: ' + noKey);
out.add((noStandard == 0 ? pass : 'FAIL ') + 'skill rows without the standard name (Canonical Key): ' + noStandard + (noStandard == 0 ? '' : ' - parsed before the field existed, or the old Parse_Resume prompt is active'));
Integer shown = 0;
for (Skill__c s : [SELECT Name, Name_Key__c, Canonical_Key__c FROM Skill__c WHERE Contact__c IN :demoIds AND Canonical_Key__c != null LIMIT 2000]) {
    if (shown < 6 && s.Name_Key__c != s.Canonical_Key__c) { out.add('     standard name example: "' + s.Name + '" -> "' + s.Canonical_Key__c + '"'); shown++; }
}
Integer withDate = [SELECT COUNT() FROM Contact WHERE Email LIKE :demo AND Date_Available__c != null];
out.add((withDate > 0 ? 'PASS ' : 'WARN ') + 'candidates with Date Available filled: ' + withDate + ' of ' + total + (withDate > 0 ? '' : ' - the loader and the parser do not fill it, so every "available within" tile will show 0'));

for (String line : out) { System.debug('VERIFY ' + line); }
