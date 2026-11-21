@IsTest
private class DemoDataLoaderTest {

    static final Set<String> EXECUTIVE_ROLES = new Set<String>{ 'Technology Executive', 'IT Executive', 'Finance Executive',
        'Operations Executive', 'Revenue Executive', 'Security Executive', 'Data Executive', 'HR Executive', 'Product Executive' };
    static final Map<String, String> JOB_ROLE = new Map<String, String>{
        'DEMO - Chief Technology Officer' => 'Technology Executive', 'DEMO - Chief Financial Officer' => 'Finance Executive',
        'DEMO - Chief Information Security Officer' => 'Security Executive', 'DEMO - Chief Revenue Officer' => 'Revenue Executive',
        'DEMO - Vice President of Operations' => 'Operations Executive', 'DEMO - Chief Data Officer' => 'Data Executive' };

    /** The active values of a Role Types picklist in the org the test runs in (the executive values only exist once they are deployed). */
    static Set<String> validRoles(Schema.SObjectField field) {
        Set<String> out = new Set<String>();
        for (Schema.PicklistEntry e : field.getDescribe().getPicklistValues()) { if (e.isActive()) { out.add(e.getValue()); } }
        return out;
    }

    /** Role Types of the contacts are executive values; they are empty only when the picklist does not have those values. */
    static void assertExecutiveRoles(List<Contact> contacts) {
        Boolean deployed = validRoles(Contact.Role_Types__c).containsAll(EXECUTIVE_ROLES);
        for (Contact c : contacts) {
            if (c.Role_Types__c == null) {
                System.assert(!deployed, c.LastName + ': Role Types is empty although the picklist has the executive values');
                continue;
            }
            for (String r : c.Role_Types__c.split(';')) { System.assert(EXECUTIVE_ROLES.contains(r), c.LastName + ': role type ' + r); }
        }
    }

    static List<Contact> demoContacts() {
        return [SELECT Id, FirstName, LastName, Email, Has_Resume__c, Candidate_Profile__c, Resume_Parse_Status__c
                FROM Contact WHERE Email LIKE '%@demo-candidates.example'];
    }

    /** PDF texts of the resumes attached to the given contacts, keyed by contact. */
    static Map<Id, String> pdfsOf(List<Contact> contacts) {
        Set<Id> ids = new Map<Id, Contact>(contacts).keySet();
        Map<Id, Id> docToContact = new Map<Id, Id>();
        for (ContentDocumentLink l : [SELECT ContentDocumentId, LinkedEntityId FROM ContentDocumentLink WHERE LinkedEntityId IN :ids]) {
            docToContact.put(l.ContentDocumentId, l.LinkedEntityId);
        }
        Map<Id, String> out = new Map<Id, String>();
        for (ContentVersion v : [SELECT ContentDocumentId, VersionData FROM ContentVersion
                                 WHERE ContentDocumentId IN :docToContact.keySet() AND IsLatest = true]) {
            out.put(docToContact.get(v.ContentDocumentId), v.VersionData.toString());
        }
        return out;
    }

    @IsTest static void runCreatesSixJobsAndTwelveCandidatesWithoutAProfile() {
        DemoDataLoader.run();

        System.assertEquals(6, [SELECT COUNT() FROM Job__c WHERE Name LIKE 'DEMO - %']);
        List<Contact> cs = demoContacts();
        System.assertEquals(12, cs.size());
        Integer withResume = 0;
        for (Contact c : cs) {
            System.assertEquals(null, c.Candidate_Profile__c, 'the parser must be the one to fill the profile');
            System.assertEquals(null, c.Resume_Parse_Status__c, 'left empty so the parser picks the contact up');
            if (c.Has_Resume__c) { withResume++; }
            if (c.LastName == 'Roy') { System.assertEquals(false, c.Has_Resume__c, 'this candidate has no resume on purpose'); }
        }
        System.assertEquals(11, withResume);
        Map<Id, String> pdfs = pdfsOf(cs);
        System.assertEquals(11, pdfs.size());
        for (Id cid : pdfs.keySet()) { assertValidPdf(pdfs.get(cid), 'demo resume ' + cid); }
    }

    @IsTest static void everyJobIsAnExecutiveLeadershipRole() {
        DemoDataLoader.run();

        Set<String> names = new Set<String>();
        Set<String> valid = validRoles(Job__c.Role_Types__c);
        for (Job__c j : [SELECT Name, Role_Types__c, Min_Experience_Years__c, Job_Description__c FROM Job__c WHERE Name LIKE 'DEMO - %']) {
            names.add(j.Name);
            String wanted = JOB_ROLE.get(j.Name);
            System.assertEquals(valid.contains(wanted) ? wanted : null, j.Role_Types__c, j.Name + ': its executive role type, when the picklist has it');
            System.assert(j.Min_Experience_Years__c >= 12, j.Name + ': an executive job asks for many years of experience');
            System.assert(j.Name.contains('Chief') || j.Name.contains('Vice President'), j.Name + ': a C-level or vice president job');
            System.assert(!j.Job_Description__c.contains('Apex') && !j.Job_Description__c.contains('Selenium'),
                j.Name + ': no hands-on developer or tester skills');
        }
        System.assertEquals(new Set<String>{ 'DEMO - Chief Technology Officer', 'DEMO - Chief Financial Officer',
            'DEMO - Chief Information Security Officer', 'DEMO - Chief Revenue Officer', 'DEMO - Vice President of Operations',
            'DEMO - Chief Data Officer' }, names);
    }

    @IsTest static void handWrittenResumesKeepTheirWordingInTheDesignedLayout() {
        String liam = DemoDataLoader.previewResumePdf(0).toString();        // Liam Fraser, Chief Technology Officer, 4 jobs
        assertValidPdf(liam, 'Liam');
        System.assert(liam.contains('(Liam Fraser)'));
        System.assert(liam.contains('Chief Technology Officer'));
        System.assert(liam.contains('Bayview Financial Group, Toronto, ON'));
        System.assert(liam.contains('Mar 2020 - Present'));
        System.assert(liam.contains('Leads a 420-person technology organization'));
        System.assert(liam.contains('(Enterprise architecture)'), 'every skill is its own pill');
        System.assert(liam.contains('B.Eng. Computer Engineering'));
        System.assert(liam.contains('2000 - 2004'));
        System.assert(liam.contains('TOGAF Certified'));

        String sophie = DemoDataLoader.previewResumePdf(7).toString();      // Sophie Tremblay: two degrees, no certifications
        System.assert(sophie.contains('(MBA)') && sophie.contains('B.A. Economics'));
        System.assert(!sophie.contains('CERTIFICATIONS'));
    }

    @IsTest static void previewBuildsEveryHandWrittenResumeWithoutCreatingRecords() {
        for (Integer i = 0; i < 12; i++) { assertValidPdf(DemoDataLoader.previewResumePdf(i).toString(), 'preview ' + i); }
        System.assertEquals(0, demoContacts().size());
        System.assertEquals(0, [SELECT COUNT() FROM Job__c WHERE Name LIKE 'DEMO - %']);
    }

    @IsTest static void handWrittenCandidatesAreExecutiveLeaders() {
        DemoDataLoader.run();
        assertExecutiveRoles([SELECT LastName, Role_Types__c FROM Contact WHERE Email LIKE '%@demo-candidates.example']);
        for (Integer i = 0; i < 12; i++) {
            String pdf = DemoDataLoader.previewResumePdf(i).toString();
            if (i != 10) {                                                  // number 10 (Nathan Roy) has no resume on purpose
                System.assert(pdf.contains('Chief') || pdf.contains('Vice President') || pdf.contains('Director'), 'resume ' + i + ': a leadership title');
            }
            System.assert(!pdf.contains('Developer') && !pdf.contains('QA Engineer') && !pdf.contains('(Apex)'),
                'resume ' + i + ' is about leadership, not hands-on delivery');
        }
    }

    @IsTest static void addBulkAddsCandidatesWithDesignedResumesAndKeepsExistingOnes() {
        DemoDataLoader.run();
        Set<Id> before = new Map<Id, Contact>(demoContacts()).keySet();

        DemoDataLoader.addBulk(20);

        List<Contact> all = demoContacts();
        System.assertEquals(32, all.size());
        System.assert(new Map<Id, Contact>(all).keySet().containsAll(before), 'the original 12 are untouched');
        Set<String> emails = new Set<String>();
        List<Contact> added = new List<Contact>();
        for (Contact c : all) {
            emails.add(c.Email);
            System.assertEquals(null, c.Candidate_Profile__c);
            if (!before.contains(c.Id)) { added.add(c); System.assertEquals(true, c.Has_Resume__c); }
        }
        System.assertEquals(20, added.size());
        System.assertEquals(32, emails.size(), 'every email is unique');
        assertExecutiveRoles([SELECT LastName, Role_Types__c FROM Contact WHERE Id IN :added]);
        Map<Id, String> pdfs = pdfsOf(added);
        System.assertEquals(20, pdfs.size());
        for (Id cid : pdfs.keySet()) {
            String pdf = pdfs.get(cid);
            assertValidPdf(pdf, 'bulk resume');
            System.assert(pdf.contains('Chief') || pdf.contains('Vice President') || pdf.contains('Director'), 'an executive title');
            System.assert(!pdf.contains('Junior') && !pdf.contains('Developer') && !pdf.contains('(Apex)'), 'no hands-on delivery roles or skills');
            // no achievement is printed twice on the same resume
            Set<String> seen = new Set<String>();
            Matcher m = Pattern.compile('\\(([^)]{40,})\\) Tj').matcher(pdf);
            while (m.find()) { System.assert(seen.add(m.group(1)), 'repeated line: ' + m.group(1)); }
        }
    }

    @IsTest static void bulkCareersClimbToDirectorVicePresidentAndCLevel() {
        DemoDataLoader.addBulk(25);                // 25 in a row cover every length of career, 8 to 26 years

        // salary follows the level: directors up to about $205,000, vice presidents about $225,000-$290,000, C-level from about $320,000
        Integer directors = 0; Integer vicePresidents = 0; Integer cLevel = 0;
        for (Contact c : [SELECT Expected_Salary__c FROM Contact WHERE Email LIKE '%@demo-candidates.example']) {
            if (c.Expected_Salary__c <= 205000) { directors++; }
            else if (c.Expected_Salary__c >= 320000) { cLevel++; }
            else { vicePresidents++; }
        }
        System.assert(directors > 0 && vicePresidents > 0 && cLevel > 0,
            'all three levels come up: ' + directors + ' / ' + vicePresidents + ' / ' + cLevel);
        System.assertEquals(25, directors + vicePresidents + cLevel);
    }

    @IsTest static void theBulkBatchSplitsAnyTotalIntoChunksOfAtMostTwentyFive() {
        System.assertEquals(25, DemoDataLoader.CHUNK_SIZE);
        System.assertEquals(new List<Integer>{ 25, 25, 10 }, new DemoDataBulkBatch(60).chunks);
        System.assertEquals(new List<Integer>{ 25 }, new DemoDataBulkBatch(25).chunks);
        System.assertEquals(new List<Integer>{ 1 }, new DemoDataBulkBatch(1).chunks);
        System.assertEquals(new List<Integer>(), new DemoDataBulkBatch(0).chunks);
        System.assertEquals(new List<Integer>(), new DemoDataBulkBatch(null).chunks);
        System.assertEquals(new List<Integer>{ 15, 15, 15 }, new DemoDataBulkBatch(45, 15).chunks);
        System.assertEquals(new List<Integer>{ 25, 25, 25, 5 }, new DemoDataBulkBatch(80, 5000).chunks, 'never more than one transaction can add');
        System.assertEquals(new List<Integer>{ 1, 1, 1 }, new DemoDataBulkBatch(3, 0).chunks, 'a chunk is at least 1');
        System.assertEquals(200, new DemoDataBulkBatch(5000).chunks.size(), '5,000 candidates are 200 runs of 25');
    }

    @IsTest static void theBulkBatchAddsEveryChunkAndEveryCandidateIsDifferent() {
        Test.startTest();
        Database.executeBatch(new DemoDataBulkBatch(45, 15), 3);             // 3 chunks of 15, all in the one test run
        Test.stopTest();

        List<Contact> all = demoContacts();
        System.assertEquals(45, all.size());
        Set<String> emails = new Set<String>();
        for (Contact c : all) { emails.add(c.Email); }
        System.assertEquals(45, emails.size(), 'each chunk continues the numbering of the one before');
        System.assertEquals(45, pdfsOf(all).size(), 'every candidate has a resume');
    }

    @IsTest static void addBulkAsyncStartsTheBatchJob() {
        Test.startTest();
        Id jobId = DemoDataLoader.addBulkAsync(20);
        Test.stopTest();

        System.assertNotEquals(null, jobId);
        System.assertEquals(20, demoContacts().size());
        System.assertEquals('Completed', [SELECT Status FROM AsyncApexJob WHERE Id = :jobId].Status);
    }

    @IsTest static void addBulkWithinOneChunkAddsRightAwayAndStartsNoBackgroundJob() {
        DemoDataLoader.addBulk(5);
        System.assertEquals(5, demoContacts().size());
        System.assertEquals(0, [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'DemoDataBulkBatch']);
    }

    // The batch is only queued here, not run: a test may not run a batch with several chunks of 25 (it allows one execute per test), and
    // the chunks themselves are covered by the tests of addNow and of the batch with a scope that fits.
    @IsTest static void addBulkOfMoreThanOneChunkHandsOverToTheBackgroundJob() {
        DemoDataLoader.addBulk(60);
        System.assertEquals(0, demoContacts().size(), 'nothing is added in this transaction: the background job does it');
        System.assertEquals(1, [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'DemoDataBulkBatch']);
    }

    @IsTest static void addNowAddsTheRequestedCandidatesInThisTransaction() {
        System.assertEquals(12, DemoDataLoader.addNow(12));
        System.assertEquals(12, demoContacts().size());
        System.assertEquals(12, DemoDataLoader.addNow(12));
        System.assertEquals(24, demoContacts().size());
        Set<String> emails = new Set<String>();
        for (Contact c : demoContacts()) { emails.add(c.Email); }
        System.assertEquals(24, emails.size(), 'the second call continues the numbering of the first');
    }

    /** The skills each job asks for, written the way the candidates' resumes list them. */
    static final Map<String, List<String>> JOB_SKILLS = new Map<String, List<String>>{
        'DEMO - Chief Technology Officer' => new List<String>{ 'Technology strategy', 'Enterprise architecture', 'Digital transformation', 'Cloud strategy', 'Engineering leadership' },
        'DEMO - Chief Financial Officer' => new List<String>{ 'Financial strategy', 'Financial reporting', 'Budgeting and forecasting', 'Capital markets', 'M&A and due diligence' },
        'DEMO - Chief Information Security Officer' => new List<String>{ 'Cybersecurity strategy', 'Security governance', 'Risk management', 'Incident response', 'Regulatory compliance' },
        'DEMO - Chief Revenue Officer' => new List<String>{ 'Revenue growth strategy', 'Go-to-market strategy', 'Sales leadership', 'Enterprise sales', 'Pipeline forecasting' },
        'DEMO - Vice President of Operations' => new List<String>{ 'Operations strategy', 'P&L management', 'Process improvement', 'Supply chain management', 'Change management' },
        'DEMO - Chief Data Officer' => new List<String>{ 'Data strategy', 'Data governance', 'Advanced analytics', 'AI strategy', 'Data privacy', 'English (fluent)', 'French (fluent)' } };

    @IsTest static void matchingCandidatesFitEveryFilterOfTheirJobAndListEverySkillItAsksFor() {
        DemoDataLoader.run();
        Set<Id> before = new Map<Id, Contact>(demoContacts()).keySet();

        System.assertEquals(12, DemoDataLoader.addMatchingCandidates(2), '2 for each of the 6 jobs');

        List<Contact> added = [SELECT Id, City__c, Work_Modes__c, Expected_Salary__c, Role_Types__c FROM Contact
                               WHERE Email LIKE '%@demo-candidates.example' AND Id NOT IN :before];
        System.assertEquals(12, added.size());
        Map<Id, String> pdfs = pdfsOf(added);
        System.assertEquals(12, pdfs.size());
        for (Job__c j : [SELECT Name, City__c, Work_Modes__c, Expected_Salary__c, Role_Types__c FROM Job__c WHERE Name LIKE 'DEMO - %']) {
            Integer fit = 0;
            for (Contact c : added) {
                Boolean cityOk = String.isBlank(j.City__c) || c.City__c == j.City__c;
                Boolean modeOk = new Set<String>(c.Work_Modes__c.split(';')).containsAll(j.Work_Modes__c.split(';'));
                Boolean salaryOk = c.Expected_Salary__c <= j.Expected_Salary__c;
                Boolean roleOk = j.Role_Types__c == null || (c.Role_Types__c != null && new Set<String>(c.Role_Types__c.split(';')).containsAll(j.Role_Types__c.split(';')));
                Boolean skillsOk = true;
                for (String skill : JOB_SKILLS.get(j.Name)) {
                    String inPdf = '(' + skill.replace('(', '\\(').replace(')', '\\)') + ')';      // the PDF writer escapes brackets inside its text
                    if (!pdfs.get(c.Id).contains(inPdf)) { skillsOk = false; }
                }
                if (cityOk && modeOk && salaryOk && roleOk && skillsOk) { fit++; }
            }
            System.assertEquals(2, fit, j.Name + ': candidates that fit its city, work mode, salary, role type and skills');
        }
    }

    @IsTest static void addMatchingCandidatesCanBeRunAgainForMorePeople() {
        DemoDataLoader.run();
        System.assertEquals(6, DemoDataLoader.addMatchingCandidates(1));
        System.assertEquals(6, DemoDataLoader.addMatchingCandidates(1));
        Set<String> emails = new Set<String>();
        for (Contact c : demoContacts()) { emails.add(c.Email); }
        System.assertEquals(24, emails.size(), '12 hand-written + 12 matching, every email different');
    }

    @IsTest static void everyDemoCandidateHasADateAvailableWithinThreeMonths() {
        DemoDataLoader.run();
        DemoDataLoader.addBulk(10);
        Set<Integer> windows = new Set<Integer>();
        for (Contact c : [SELECT Date_Available__c FROM Contact WHERE Email LIKE '%@demo-candidates.example']) {
            System.assertNotEquals(null, c.Date_Available__c, 'Date Available is filled');
            Integer days = Date.today().daysBetween(c.Date_Available__c);
            System.assert(days >= 0 && days <= 90, 'available in ' + days + ' days');
            windows.add(days <= 0 ? 0 : (days <= 14 ? 14 : (days <= 31 ? 31 : (days <= 62 ? 62 : 90))));
        }
        System.assert(windows.size() >= 4, 'candidates fall in the different windows of the screen: ' + windows);
    }

    @IsTest static void runningTwiceDoesNotDuplicate() {
        DemoDataLoader.run();
        DemoDataLoader.run();
        System.assertEquals(6, [SELECT COUNT() FROM Job__c WHERE Name LIKE 'DEMO - %']);
        System.assertEquals(12, demoContacts().size());
    }

    @IsTest static void addExtraJobsAddsOnlyTheMissingOnesAndTouchesNothingElse() {
        DemoDataLoader.run();
        delete [SELECT Id FROM Job__c WHERE Name IN ('DEMO - Chief Revenue Officer', 'DEMO - Chief Data Officer')];
        System.assertEquals(4, [SELECT COUNT() FROM Job__c WHERE Name LIKE 'DEMO - %']);

        DemoDataLoader.addExtraJobs();
        System.assertEquals(6, [SELECT COUNT() FROM Job__c WHERE Name LIKE 'DEMO - %']);
        DemoDataLoader.addExtraJobs();                                       // nothing missing: nothing added
        System.assertEquals(6, [SELECT COUNT() FROM Job__c WHERE Name LIKE 'DEMO - %']);
        System.assertEquals(12, demoContacts().size());
    }

    @IsTest static void cleanupRemovesDemoDataButNotOtherRecords() {
        insert new Job__c(Name = 'Real job', Job_Description__c = 'x');
        insert new Contact(LastName = 'Real', Email = 'real@example.com');
        DemoDataLoader.run();
        DemoDataLoader.addBulk(5);
        DemoDataLoader.cleanup();
        System.assertEquals(0, [SELECT COUNT() FROM Job__c WHERE Name LIKE 'DEMO - %']);
        System.assertEquals(0, demoContacts().size());
        System.assertEquals(1, [SELECT COUNT() FROM Job__c WHERE Name = 'Real job']);
        System.assertEquals(1, [SELECT COUNT() FROM Contact WHERE Email = 'real@example.com']);
    }

    @IsTest static void salariesAreRealisticYearlyCanadianDollarAmountsForExecutives() {
        DemoDataLoader.run();
        DemoDataLoader.addBulk(20);
        Integer checked = 0;
        for (Contact c : [SELECT Expected_Salary__c FROM Contact WHERE Email LIKE '%@demo-candidates.example']) {
            System.assert(c.Expected_Salary__c >= 150000 && c.Expected_Salary__c <= 400000, 'candidate salary ' + c.Expected_Salary__c);
            checked++;
        }
        System.assertEquals(32, checked);
        for (Job__c j : [SELECT Expected_Salary__c FROM Job__c WHERE Name LIKE 'DEMO - %']) {
            System.assert(j.Expected_Salary__c >= 200000 && j.Expected_Salary__c <= 400000, 'job salary ' + j.Expected_Salary__c);
        }
    }

    /** Checks the file structure a PDF reader relies on: header, trailer, a cross-reference table that points at every object. */
    private static void assertValidPdf(String pdf, String label) {
        System.assert(pdf.startsWith('%PDF-1.4'), label + ': header');
        System.assert(pdf.endsWith('%%EOF'), label + ': trailer');
        Integer sx = pdf.lastIndexOf('startxref\n');
        System.assert(sx > 0, label + ': startxref');
        Integer xrefPos = Integer.valueOf(pdf.substring(sx + 10, pdf.indexOf('\n', sx + 10)));
        System.assertEquals('xref', pdf.substring(xrefPos, xrefPos + 4), label + ': xref offset');
        List<String> rows = pdf.substring(xrefPos, sx).split('\n');         // every cross-reference entry must point at "<n> 0 obj"
        Integer objCount = Integer.valueOf(rows[1].split(' ')[1]);
        for (Integer i = 1; i < objCount; i++) {
            Integer off = Integer.valueOf(rows[2 + i].substring(0, 10));
            System.assert(pdf.substring(off).startsWith(i + ' 0 obj'), label + ': object ' + i + ' offset');
        }
        System.assert(pdf.contains('/Helvetica-Bold'), label + ': fonts');
        System.assert(pdf.contains('PROFESSIONAL SUMMARY') && pdf.contains('WORK EXPERIENCE'), label + ': sections');
        System.assert(!Pattern.compile('\\d{4}\\.\\d').matcher(pdf).find(), label + ': a year printed with decimals');
    }
}
