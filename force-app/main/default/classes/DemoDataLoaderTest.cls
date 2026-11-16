@IsTest
private class DemoDataLoaderTest {

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
            if (c.LastName == 'Malhotra') { System.assertEquals(false, c.Has_Resume__c, 'this candidate has no resume on purpose'); }
        }
        System.assertEquals(11, withResume);
        Map<Id, String> pdfs = pdfsOf(cs);
        System.assertEquals(11, pdfs.size());
        for (Id cid : pdfs.keySet()) { assertValidPdf(pdfs.get(cid), 'demo resume ' + cid); }
    }

    @IsTest static void handWrittenResumesKeepTheirWordingInTheDesignedLayout() {
        String aarav = DemoDataLoader.previewResumePdf(0).toString();       // Aarav Sharma, 2 jobs
        assertValidPdf(aarav, 'Aarav');
        System.assert(aarav.contains('(Aarav Sharma)'));
        System.assert(aarav.contains('Senior Salesforce Developer'));
        System.assert(aarav.contains('Brightwave Technologies, Jaipur'));
        System.assert(aarav.contains('Jan 2019 - Present'));
        System.assert(aarav.contains('Led a team of 4 developers'));
        System.assert(aarav.contains('(Lightning Web Components)'), 'every skill is its own pill');
        System.assert(aarav.contains('B.Tech Computer Science'));
        System.assert(aarav.contains('2012 - 2016'));
        System.assert(aarav.contains('Salesforce Platform Developer II'));

        String ananya = DemoDataLoader.previewResumePdf(7).toString();      // Ananya Das: two degrees, no certifications
        System.assert(ananya.contains('(MBA)') && ananya.contains('B.A. Economics'));
        System.assert(!ananya.contains('CERTIFICATIONS'));
    }

    @IsTest static void previewBuildsEveryHandWrittenResumeWithoutCreatingRecords() {
        for (Integer i = 0; i < 12; i++) { assertValidPdf(DemoDataLoader.previewResumePdf(i).toString(), 'preview ' + i); }
        System.assertEquals(0, demoContacts().size());
        System.assertEquals(0, [SELECT COUNT() FROM Job__c WHERE Name LIKE 'DEMO - %']);
    }

    @IsTest static void addBulkAddsCandidatesWithDesignedResumesAndKeepsExistingOnes() {
        DemoDataLoader.run();
        Set<Id> before = new Map<Id, Contact>(demoContacts()).keySet();

        DemoDataLoader.addBulk(30);

        List<Contact> all = demoContacts();
        System.assertEquals(42, all.size());
        System.assert(new Map<Id, Contact>(all).keySet().containsAll(before), 'the original 12 are untouched');
        Set<String> emails = new Set<String>();
        List<Contact> added = new List<Contact>();
        for (Contact c : all) {
            emails.add(c.Email);
            System.assertEquals(null, c.Candidate_Profile__c);
            if (!before.contains(c.Id)) { added.add(c); System.assertEquals(true, c.Has_Resume__c); }
        }
        System.assertEquals(30, added.size());
        System.assertEquals(42, emails.size(), 'every email is unique');
        Map<Id, String> pdfs = pdfsOf(added);
        System.assertEquals(30, pdfs.size());
        for (Id cid : pdfs.keySet()) {
            String pdf = pdfs.get(cid);
            assertValidPdf(pdf, 'bulk resume');
            // no achievement is printed twice on the same resume
            Set<String> seen = new Set<String>();
            Matcher m = Pattern.compile('\\(([^)]{40,})\\) Tj').matcher(pdf);
            while (m.find()) { System.assert(seen.add(m.group(1)), 'repeated line: ' + m.group(1)); }
        }
    }

    @IsTest static void addBulkIsCappedAt100PerCallAndStaysInsideTheLimits() {
        DemoDataLoader.addBulk(500);
        System.assertEquals(100, [SELECT COUNT() FROM Contact WHERE Email LIKE 'bulk.%@demo-candidates.example']);
        System.assertEquals(100, [SELECT COUNT() FROM ContentVersion WHERE Title LIKE '%_Resume']);
        System.assert(Limits.getQueries() < 20, 'files are linked in bulk, so the trigger runs once: ' + Limits.getQueries() + ' queries');
        System.assert(Limits.getHeapSize() < Limits.getLimitHeapSize() / 2, 'heap ' + Limits.getHeapSize());
        System.assert(Limits.getCpuTime() < Limits.getLimitCpuTime() / 2, 'CPU ' + Limits.getCpuTime());
    }

    @IsTest static void runningTwiceDoesNotDuplicate() {
        DemoDataLoader.run();
        DemoDataLoader.run();
        System.assertEquals(6, [SELECT COUNT() FROM Job__c WHERE Name LIKE 'DEMO - %']);
        System.assertEquals(12, demoContacts().size());
    }

    @IsTest static void addExtraJobsAddsOnlyTheMissingOnesAndTouchesNothingElse() {
        DemoDataLoader.run();
        delete [SELECT Id FROM Job__c WHERE Name IN ('DEMO - Business Analyst', 'DEMO - Data Analyst')];
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

    @IsTest static void salariesAreRealisticYearlyUsDollarAmounts() {
        DemoDataLoader.run();
        DemoDataLoader.addBulk(40);
        Integer checked = 0;
        for (Contact c : [SELECT Expected_Salary__c FROM Contact WHERE Email LIKE '%@demo-candidates.example']) {
            System.assert(c.Expected_Salary__c >= 20000 && c.Expected_Salary__c <= 250000, 'candidate salary ' + c.Expected_Salary__c);
            checked++;
        }
        System.assertEquals(52, checked);
        for (Job__c j : [SELECT Expected_Salary__c FROM Job__c WHERE Name LIKE 'DEMO - %']) {
            System.assert(j.Expected_Salary__c >= 50000 && j.Expected_Salary__c <= 200000, 'job salary ' + j.Expected_Salary__c);
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
