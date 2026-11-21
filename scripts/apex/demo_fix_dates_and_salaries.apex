// OPTIONAL. Changes data: only Contact.Expected_Salary__c (4 candidates) and Contact.Date_Available__c (demo candidates). Nothing is deleted.
// Run:  sf apex run --file scripts/apex/demo_fix_dates_and_salaries.apex -o demoOrg      (or paste it into Developer Console > Execute Anonymous)
// Safe to run again: it only fills dates that are empty.

// 1) Four strong-fit candidates ask for slightly MORE than their job pays. The screen starts with "max salary = the job's salary", so
//    they would be hidden until a recruiter raises the limit. Bring them just under the job's salary.
Map<String, Decimal> salary = new Map<String, Decimal>{
    'liam.fraser@demo-candidates.example'      => 340000,    // Chief Technology Officer job pays 350,000 (was 360,000)
    'daniel.macdonald@demo-candidates.example' => 270000,    // Chief Information Security Officer job pays 285,000 (was 290,000)
    'isabelle.bouchard@demo-candidates.example' => 285000,   // Chief Data Officer job pays 300,000 (was 310,000)
    'fatima.ahmed@demo-candidates.example'     => 225000 };  // Vice President of Operations job pays 240,000 (was 245,000)
List<Contact> people = [SELECT Id, Email FROM Contact WHERE Email IN :salary.keySet()];
for (Contact c : people) { c.Expected_Salary__c = salary.get(c.Email.toLowerCase()); }
update people;

// 2) Date Available is not filled by the loader or by the parser, so every "available within" tile would show 0.
//    Spread it so each window of the screen (now, 14, 31 and 62 days) has candidates, and some are later than that.
List<Integer> days = new List<Integer>{ 0, 0, 7, 14, 21, 31, 45, 62, 90 };
List<Contact> noDate = [SELECT Id, Email FROM Contact WHERE Email LIKE '%@demo-candidates.example' AND Date_Available__c = null];
for (Contact c : noDate) { c.Date_Available__c = Date.today().addDays(days[Math.mod(Math.abs(c.Email.hashCode()), days.size())]); }
update noDate;

System.debug('FIXED salaries: ' + people.size() + ', dates filled: ' + noDate.size());
