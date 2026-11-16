/**
 * DEMO DATA loader for the Candidate Matcher: 6 jobs and 12 hand-written candidates (11 with a PDF resume),
 * plus any number of extra generated candidates. Every resume is a designed, professional-looking PDF.
 *
 * Candidate_Profile__c is deliberately NEVER filled in here: the resume parser writes it, so after loading you run the
 * parse (e.g. ResumeParseScheduler.runNow()) and each profile appears by itself. Resume_Parse_Status__c stays empty so the
 * parser picks the contacts up.
 *
 * Deploy this class, then run in Developer Console > Execute Anonymous:
 *     DemoDataLoader.run();             // creates the 6 jobs and the 12 candidates (first removes an earlier demo run)
 *     DemoDataLoader.addBulk(100);      // ADDS 100 more candidates (max 100 per call), each with a designed PDF resume.
 *                                       // Does not delete anything. Call it again to add more.
 *     DemoDataLoader.addExtraJobs();    // ADDS the 3 extra jobs (Administrator, Business Analyst, Data Analyst) to an
 *                                       // existing demo data set without touching anything else
 *     DemoDataLoader.cleanup();         // removes ALL demo data (also the bulk candidates)
 *     Blob b = DemoDataLoader.previewResumePdf(0);   // builds hand-written resume 0..11 in memory (no records created)
 * All salaries are yearly US dollars (candidates about $35,000-$185,000, jobs $65,000-$125,000).
 * It only touches contacts whose email ends with @demo-candidates.example and jobs named "DEMO - ...".
 *
 * Resume design: colour header band with name, title and contact line; accent-coloured section headings; skills as pills;
 * job entries with bold title, right-aligned dates, italic employer and round bullets; education; certifications.
 * It is all real, selectable text in one reading order (so the resume parser reads it cleanly), set in the PDF standard fonts.
 */
public with sharing class DemoDataLoader {

    public static void cleanup() {
    List<Contact> oldContacts = [SELECT Id FROM Contact WHERE Email LIKE '%@demo-candidates.example'];
    Set<Id> oldIds = new Map<Id, Contact>(oldContacts).keySet();
    List<Job__c> oldJobs = [SELECT Id FROM Job__c WHERE Name LIKE 'DEMO - %'];
    Set<Id> oldJobIds = new Map<Id, Job__c>(oldJobs).keySet();
    delete [SELECT Id FROM Candidate_Match__c WHERE Contact__c IN :oldIds OR Job__c IN :oldJobIds];
    delete [SELECT Id FROM Skill__c WHERE Contact__c IN :oldIds];
    delete [SELECT Id FROM Education_History__c WHERE Contact__c IN :oldIds];
    delete [SELECT Id FROM Employment_History__c WHERE Contact__c IN :oldIds];
    // ContentDocumentLink must be filtered by a NON-EMPTY set of ids, so skip it when there is nothing to clean up
    if (!oldIds.isEmpty()) {
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink l : [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId IN :oldIds]) {
            docIds.add(l.ContentDocumentId);
        }
        if (!docIds.isEmpty()) { delete [SELECT Id FROM ContentDocument WHERE Id IN :docIds]; }
    }
    delete oldContacts;
    delete oldJobs;
    }

    public static void run() {
        cleanup();

        List<Job__c> jobs = buildJobs();
        insert jobs;

        List<Map<String, Object>> people = buildPeople();
        List<Contact> contacts = new List<Contact>();
        for (Map<String, Object> p : people) { contacts.add(contactFor(p)); }
        insert contacts;

        List<Contact> withResume = new List<Contact>();
        List<List<String>> resumeLines = new List<List<String>>();
        for (Integer idx = 0; idx < people.size(); idx++) {
            Map<String, Object> p = people.get(idx);
            if (!(Boolean) p.get('resume')) { continue; }
            withResume.add(contacts.get(idx));
            resumeLines.add((List<String>) p.get('lines'));
        }
        Integer fileCount = attachResumes(withResume, resumeLines);

        System.debug('DEMO DATA CREATED: ' + jobs.size() + ' jobs, ' + contacts.size() + ' contacts, ' + fileCount + ' PDF resumes.');
        System.debug('Contacts with Has_Resume__c = true: '
            + [SELECT COUNT() FROM Contact WHERE Email LIKE '%@demo-candidates.example' AND Has_Resume__c = true]);
    }

    private static Contact contactFor(Map<String, Object> p) {
        String f = (String) p.get('first');
        String l = (String) p.get('last');
        return new Contact(
            FirstName = f, LastName = l,
            Email = f.toLowerCase() + '.' + l.toLowerCase() + '@demo-candidates.example',
            City__c = (String) p.get('city'),
            Work_Modes__c = (String) p.get('modes'),
            Expected_Salary__c = (Integer) p.get('salary'),
            Role_Types__c = (String) p.get('roles'),
            Has_Resume__c = (Boolean) p.get('resume'));
    }

    /** Builds hand-written resume number 0..11 in memory only (nothing is inserted). Handy to look at the design. */
    public static Blob previewResumePdf(Integer personIndex) {
        List<Map<String, Object>> people = buildPeople();
        Map<String, Object> p = people[Math.mod(personIndex == null ? 0 : personIndex, people.size())];
        return buildPdf(parseResume(contactFor(p), (List<String>) p.get('lines')));
    }

    /** Adds the 3 extra jobs to an existing demo data set (skips any that already exist). Nothing is deleted. */
    public static void addExtraJobs() {
        Set<String> have = new Set<String>();
        for (Job__c j : [SELECT Name FROM Job__c WHERE Name LIKE 'DEMO - %']) { have.add(j.Name); }
        List<Job__c> toAdd = new List<Job__c>();
        for (Job__c j : extraJobs()) { if (!have.contains(j.Name)) { toAdd.add(j); } }
        insert toAdd;
        System.debug('DEMO JOBS ADDED: ' + toAdd.size());
    }

    private static List<Job__c> extraJobs() {
        return new List<Job__c>{
            new Job__c(
                Name = 'DEMO - Salesforce Administrator',
                Job_Description__c = '<p><b>Salesforce Administrator</b> (remote)</p>'
                    + '<p>Own day-to-day configuration of Sales Cloud and Service Cloud for about 400 users. At least 3 years of '
                    + 'administration experience.</p><ul><li>Salesforce Flow automation</li><li>Reports and dashboards</li>'
                    + '<li>Permission sets and security</li><li>Data migration and Data Loader</li><li>User training</li></ul>'
                    + '<p>Nice to have: Administrator or Advanced Administrator certification.</p>',
                Work_Modes__c = 'Remote', Expected_Salary__c = 65000,
                Role_Types__c = 'Administrator', Min_Experience_Years__c = 3),
            new Job__c(
                Name = 'DEMO - Business Analyst',
                Job_Description__c = '<p><b>Business Analyst</b> (Bengaluru, hybrid)</p>'
                    + '<p>Turn business goals into clear requirements for CRM releases. At least 4 years of experience.</p>'
                    + '<ul><li>Requirement gathering and user stories</li><li>UAT coordination</li><li>Process mapping</li>'
                    + '<li>Stakeholder management</li><li>JIRA and Confluence</li></ul><p>Nice to have: CBAP, Agile experience.</p>',
                City__c = 'Bengaluru', Work_Modes__c = 'Hybrid', Expected_Salary__c = 75000,
                Role_Types__c = 'Business Analyst', Min_Experience_Years__c = 4),
            new Job__c(
                Name = 'DEMO - Data Analyst',
                Job_Description__c = '<p><b>Data Analyst</b> (remote)</p>'
                    + '<p>Build dashboards and reports that help managers decide. At least 3 years of analytics experience.</p>'
                    + '<ul><li>SQL</li><li>Data visualization (Tableau or Power BI)</li><li>Excel</li><li>Python for automation</li></ul>'
                    + '<p>Nice to have: statistics background.</p>',
                Work_Modes__c = 'Remote', Expected_Salary__c = 85000,
                Role_Types__c = 'Data Analyst', Min_Experience_Years__c = 3)
        };
    }

    private static List<Job__c> buildJobs() {
        List<Job__c> jobs = new List<Job__c>{
            new Job__c(
                Name = 'DEMO - Senior Salesforce Developer',
                Job_Description__c = '<p><b>Senior Salesforce Developer</b> (Jaipur, hybrid)</p>'
                    + '<p>We are looking for a developer with at least 4 years of Salesforce experience to build Lightning Web Components, '
                    + 'Apex services and REST integrations for our finance customers.</p>'
                    + '<ul><li>Strong Apex and SOQL</li><li>Lightning Web Components</li><li>REST API integrations</li>'
                    + '<li>Salesforce Flow</li><li>Salesforce DX and Git</li></ul>'
                    + '<p>Nice to have: Platform Developer certification, Experience Cloud.</p>',
                City__c = 'Jaipur', Work_Modes__c = 'Hybrid', Expected_Salary__c = 100000,
                Role_Types__c = 'Developer', Min_Experience_Years__c = 4),
            new Job__c(
                Name = 'DEMO - Remote Salesforce Architect',
                Job_Description__c = '<p><b>Salesforce Technical Architect</b> (fully remote)</p>'
                    + '<p>Own the solution design for large Salesforce programmes. 8+ years of experience, strong integration '
                    + 'and data architecture skills, mentoring developers.</p>'
                    + '<ul><li>Solution architecture</li><li>Integration patterns (REST, MuleSoft)</li><li>Apex and Lightning Web Components</li>'
                    + '<li>Data modeling</li></ul><p>Application Architect certification is a plus.</p>',
                Work_Modes__c = 'Remote', Expected_Salary__c = 125000,
                Role_Types__c = 'Architect', Min_Experience_Years__c = 8),
            new Job__c(
                Name = 'DEMO - Salesforce QA Engineer',
                Job_Description__c = '<p><b>QA Engineer - Salesforce</b> (remote)</p>'
                    + '<p>Test Salesforce releases end to end. Experience with test automation (Selenium or Provar), API testing with Postman '
                    + 'and writing Apex test classes. JIRA for defect tracking.</p>',
                Work_Modes__c = 'Remote', Expected_Salary__c = 80000,
                Role_Types__c = 'QA Engineer', Min_Experience_Years__c = 3)
        };
        jobs.addAll(extraJobs());
        return jobs;
    }

    private static List<Map<String, Object>> buildPeople() {
        List<Map<String, Object>> people = new List<Map<String, Object>>();

        people.add(new Map<String, Object>{ 'first' => 'Aarav', 'last' => 'Sharma', 'city' => 'Jaipur', 'modes' => 'Hybrid;Remote',
            'salary' => 90000, 'roles' => 'Developer;Architect', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Salesforce developer with 7 years of experience building Lightning Web Components, Apex services and REST integrations for banking and retail clients.',
            '', 'SKILLS',
            'Apex, Lightning Web Components, SOQL, Salesforce Flow, REST API integration, Salesforce DX, Git, CI/CD, Solution design',
            '', 'EXPERIENCE',
            'Senior Salesforce Developer - Brightwave Technologies, Jaipur', 'Jan 2019 - Present',
            '- Led a team of 4 developers delivering LWC and Apex features for a banking client.',
            '- Designed REST integrations between Salesforce and core banking systems.',
            '- Introduced Salesforce DX and automated deployments with Git pipelines.',
            'Salesforce Developer - Cloudnine Solutions, Jaipur', 'Jun 2016 - Dec 2018',
            '- Built Apex triggers, batch jobs and Visualforce pages for a retail CRM.',
            '- Created reports and dashboards for sales leadership.',
            '', 'EDUCATION', 'B.Tech Computer Science - Rajasthan Technical University, 2012 - 2016',
            '', 'CERTIFICATIONS', 'Salesforce Platform Developer I, Salesforce Platform Developer II' }});

        people.add(new Map<String, Object>{ 'first' => 'Priya', 'last' => 'Nair', 'city' => 'Bengaluru', 'modes' => 'Remote',
            'salary' => 110000, 'roles' => 'Developer;Architect', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Salesforce technical architect with 12 years of experience designing integrations and data models for global enterprises.',
            '', 'SKILLS',
            'Solution architecture, Apex, Lightning Web Components, Aura, MuleSoft, Integration patterns, Data modeling, Java, Experience Cloud',
            '', 'EXPERIENCE',
            'Salesforce Technical Architect - Northstar Digital, Bengaluru', 'Jan 2018 - Present',
            '- Architected a multi-cloud Salesforce programme for a global manufacturer.',
            '- Defined integration patterns using MuleSoft and REST APIs.',
            '- Mentored 10 developers and ran architecture review boards.',
            'Senior Salesforce Developer - Pixel Labs, Bengaluru', 'Jul 2014 - Dec 2017',
            '- Built Apex frameworks and Lightning components for a telecom client.',
            'Software Engineer - Orbit Systems, Bengaluru', 'Jul 2011 - Jun 2014',
            '- Developed Java services and early Salesforce integrations.',
            '', 'EDUCATION', 'B.E. Information Science - Visvesvaraya Technological University, 2007 - 2011',
            '', 'CERTIFICATIONS', 'Salesforce Application Architect, Platform Developer II' }});

        people.add(new Map<String, Object>{ 'first' => 'Rohan', 'last' => 'Verma', 'city' => 'Jaipur', 'modes' => 'On-site;Hybrid',
            'salary' => 75000, 'roles' => 'Developer', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Salesforce developer with 5 years of experience in Apex, Visualforce and Lightning Web Components for services companies.',
            '', 'SKILLS',
            'Apex, Visualforce, SOQL, JavaScript, Lightning Web Components, Salesforce Flow, Data Loader',
            '', 'EXPERIENCE',
            'Salesforce Developer - Bluepeak Consulting, Jaipur', 'Aug 2021 - Present',
            '- Developed LWC screens and Apex services for insurance clients.',
            '- Wrote unit tests with over 90 percent coverage.',
            'Junior Salesforce Developer - Greenfield Infotech, Jaipur', 'Jun 2019 - Jul 2021',
            '- Built Visualforce pages and validation logic for a sales CRM.',
            '', 'EDUCATION', 'B.Tech Information Technology - Jaipur Institute of Engineering, 2015 - 2019',
            '', 'CERTIFICATIONS', 'Salesforce Platform Developer I' }});

        people.add(new Map<String, Object>{ 'first' => 'Sneha', 'last' => 'Iyer', 'city' => 'Pune', 'modes' => 'Hybrid',
            'salary' => 85000, 'roles' => 'Administrator;Consultant', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Salesforce administrator with 8 years of experience in Sales Cloud and Service Cloud configuration, automation and data migration.',
            '', 'SKILLS',
            'Salesforce Flow, Reports and Dashboards, Permission sets, Data migration, Sales Cloud, Service Cloud, Apex (basic), User training',
            '', 'EXPERIENCE',
            'Salesforce Administrator - Sunrise Retail, Pune', 'Feb 2018 - Present',
            '- Owns Sales Cloud and Service Cloud configuration for 600 users.',
            '- Automated approval processes with Flow, saving 20 hours a week.',
            'CRM Analyst - Sunrise Retail, Pune', 'Jun 2016 - Jan 2018',
            '- Built reports and dashboards for regional managers.',
            '', 'EDUCATION', 'B.Com - Savitribai Phule Pune University, 2013 - 2016',
            '', 'CERTIFICATIONS', 'Salesforce Administrator, Platform App Builder' }});

        people.add(new Map<String, Object>{ 'first' => 'Karan', 'last' => 'Singh', 'city' => 'Jaipur', 'modes' => 'Hybrid',
            'salary' => 130000, 'roles' => 'Architect;Consultant', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Salesforce solution architect with 14 years of experience in pre-sales, solution design and delivery governance.',
            '', 'SKILLS',
            'Solution architecture, Apex, Lightning Web Components, Integration, Data architecture, Pre-sales, Governance, Stakeholder management',
            '', 'EXPERIENCE',
            'Salesforce Solution Architect - Vertex Consulting, Jaipur', 'Mar 2016 - Present',
            '- Designed solutions for 20+ enterprise Salesforce programmes.',
            '- Leads pre-sales workshops and estimates multi-million projects.',
            'Senior Consultant - Altitude Partners, Gurugram', 'Jul 2012 - Feb 2016',
            '- Delivered Sales Cloud and CPQ implementations.',
            '', 'EDUCATION', 'B.Tech Electronics - Malaviya National Institute of Technology, 2006 - 2010',
            '', 'CERTIFICATIONS', 'Salesforce Application Architect, System Architect' }});

        people.add(new Map<String, Object>{ 'first' => 'Neha', 'last' => 'Gupta', 'city' => 'Hyderabad', 'modes' => 'Remote',
            'salary' => 70000, 'roles' => 'QA Engineer', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'QA engineer with 5 years of experience testing Salesforce releases with manual and automated tests.',
            '', 'SKILLS',
            'Selenium, Provar, Apex test classes, Postman, JIRA, Test automation, API testing, Regression testing',
            '', 'EXPERIENCE',
            'QA Engineer - Quantum Soft, Hyderabad', 'Jan 2020 - Present',
            '- Built a Provar regression suite covering 300 test cases.',
            '- Tested REST integrations with Postman collections.',
            'Test Analyst - Quantum Soft, Hyderabad', 'Jul 2018 - Dec 2019',
            '- Executed manual test plans for Sales Cloud releases.',
            '', 'EDUCATION', 'B.Sc Computer Science - Osmania University, 2015 - 2018',
            '', 'CERTIFICATIONS', 'Salesforce Administrator, ISTQB Foundation' }});

        people.add(new Map<String, Object>{ 'first' => 'Vikram', 'last' => 'Rao', 'city' => 'Jaipur', 'modes' => 'Hybrid;Remote',
            'salary' => 95000, 'roles' => 'Developer', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Java engineer with 6 years of experience who moved into Salesforce development 2 years ago.',
            '', 'SKILLS',
            'Java, Spring Boot, REST APIs, SQL, Git, Apex, SOQL, Salesforce Flow, Integration',
            '', 'EXPERIENCE',
            'Salesforce Developer - Metro Systems, Jaipur', 'Apr 2023 - Present',
            '- Builds Apex services and REST integrations between Salesforce and Java back ends.',
            'Software Engineer - Metro Systems, Jaipur', 'Jul 2018 - Mar 2023',
            '- Developed Java Spring Boot services and SQL reports for a logistics platform.',
            '', 'EDUCATION', 'B.Tech Computer Science - Poornima College of Engineering, 2014 - 2018',
            '', 'CERTIFICATIONS', 'Salesforce Platform Developer I' }});

        people.add(new Map<String, Object>{ 'first' => 'Ananya', 'last' => 'Das', 'city' => 'Bengaluru', 'modes' => 'Hybrid',
            'salary' => 80000, 'roles' => 'Business Analyst;Project Manager', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Business analyst with 8 years of experience gathering requirements and running UAT for CRM programmes.',
            '', 'SKILLS',
            'JIRA, Confluence, Requirement gathering, User stories, UAT, Process mapping, Stakeholder management',
            '', 'EXPERIENCE',
            'Business Analyst - Lumen Corp, Bengaluru', 'Jan 2017 - Present',
            '- Wrote user stories and acceptance criteria for Salesforce Sales Cloud releases.',
            '- Coordinated UAT with 40 business users.',
            '', 'EDUCATION', 'MBA - Christ University, 2015 - 2017', 'B.A. Economics - Delhi University, 2012 - 2015' }});

        people.add(new Map<String, Object>{ 'first' => 'Mohit', 'last' => 'Jain', 'city' => 'Jaipur', 'modes' => 'Hybrid',
            'salary' => 60000, 'roles' => 'Developer', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Junior Salesforce developer with 2 years of experience writing Apex and basic Lightning Web Components.',
            '', 'SKILLS',
            'Apex, SOQL, Lightning Web Components (basic), HTML, CSS, JavaScript, Salesforce Flow',
            '', 'EXPERIENCE',
            'Junior Salesforce Developer - Starlight IT, Jaipur', 'Sep 2023 - Present',
            '- Fixes defects and builds small Apex and Flow enhancements.',
            'Salesforce Intern - Starlight IT, Jaipur', 'Jan 2023 - Aug 2023',
            '- Supported the team with data loads and test classes.',
            '', 'EDUCATION', 'B.Tech Computer Science - Jaipur Institute of Engineering, 2019 - 2023',
            '', 'CERTIFICATIONS', 'Trailhead Ranger' }});

        people.add(new Map<String, Object>{ 'first' => 'Divya', 'last' => 'Kapoor', 'city' => 'Pune', 'modes' => 'Remote',
            'salary' => 100000, 'roles' => 'Data Analyst', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Data analyst with 6 years of experience building dashboards and statistical models.',
            '', 'SKILLS',
            'SQL, Tableau, Python, Excel, Power BI, Statistics, Data visualization',
            '', 'EXPERIENCE',
            'Data Analyst - Insight Analytics, Pune', 'Jun 2019 - Present',
            '- Built Tableau dashboards used by 200 managers.',
            '- Automated weekly reporting with Python and SQL.',
            '', 'EDUCATION', 'M.Sc Statistics - Savitribai Phule Pune University, 2017 - 2019' }});

        // This candidate has NO resume, so every filter excludes him ("must have a resume").
        people.add(new Map<String, Object>{ 'first' => 'Arjun', 'last' => 'Malhotra', 'city' => 'Jaipur', 'modes' => 'Hybrid',
            'salary' => 88000, 'roles' => 'Developer', 'resume' => false, 'lines' => new List<String>() });

        people.add(new Map<String, Object>{ 'first' => 'Isha', 'last' => 'Reddy', 'city' => 'Jaipur', 'modes' => 'Hybrid',
            'salary' => 93000, 'roles' => 'Developer;Consultant', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Salesforce consultant and developer with 8 years of experience in Experience Cloud, Apex and integrations.',
            '', 'SKILLS',
            'Apex, Lightning Web Components, Experience Cloud, REST API integration, Salesforce Flow, Sales Cloud, SOQL, Git',
            '', 'EXPERIENCE',
            'Salesforce Consultant and Developer - Orbit Digital, Jaipur', 'Apr 2019 - Present',
            '- Delivered 5 Experience Cloud portals with custom LWC components.',
            '- Built REST integrations to ERP and payment systems.',
            'Salesforce Developer - Kite Software, Jaipur', 'Jun 2017 - Mar 2019',
            '- Developed Apex classes, triggers and Flow automation for a sales CRM.',
            '', 'EDUCATION', 'B.Tech Computer Science - Rajasthan Technical University, 2013 - 2017',
            '', 'CERTIFICATIONS', 'Salesforce Platform Developer I, Experience Cloud Consultant' }});

        return people;
    }

    // =====================================================================================
    //  RESUME PDFs (designed layout)
    // =====================================================================================

    /**
     * Saves one designed PDF resume per contact and links every file to its contact in ONE insert.
     * (Attaching with FirstPublishLocationId fires the ContentDocumentLink trigger once per file and runs out of SOQL
     * queries after about 45 files; one bulk insert fires it once.) Returns the number of PDFs created.
     */
    private static Integer attachResumes(List<Contact> contacts, List<List<String>> resumeLines) {
        if (contacts.isEmpty()) { return 0; }
        List<ContentVersion> files = new List<ContentVersion>();
        for (Integer i = 0; i < contacts.size(); i++) {
            Contact c = contacts[i];
            String baseName = c.FirstName + '_' + c.LastName + '_Resume';
            files.add(new ContentVersion(Title = baseName, PathOnClient = baseName + '.pdf',
                VersionData = buildPdf(parseResume(c, resumeLines[i]))));
        }
        insert files;

        Map<Id, Id> docByVersion = new Map<Id, Id>();
        for (ContentVersion v : [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id IN :files]) { docByVersion.put(v.Id, v.ContentDocumentId); }
        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        for (Integer i = 0; i < contacts.size(); i++) {
            links.add(new ContentDocumentLink(ContentDocumentId = docByVersion.get(files[i].Id), LinkedEntityId = contacts[i].Id,
                ShareType = 'V', Visibility = 'AllUsers'));
        }
        insert links;
        return files.size();
    }

    /**
     * Turns the plain resume text used by this class (SUMMARY / SKILLS / EXPERIENCE / EDUCATION / CERTIFICATIONS; a job is
     * "Title - Employer, City" + a dates line + "- " bullets; an education line is "Degree - School, years") into the
     * structure the designed PDF prints.
     */
    private static ResumeDoc parseResume(Contact c, List<String> lines) {
        ResumeDoc r = new ResumeDoc();
        List<List<Decimal>> colors = palette();
        r.accent = colors[Math.mod(Math.abs(String.valueOf(c.Email).hashCode()), colors.size())];   // a steady colour per person
        r.name = c.FirstName + ' ' + c.LastName;

        List<String> summary = new List<String>();
        String section = '';
        ResumeJob job = null;
        for (String raw : lines) {
            String ln = raw == null ? '' : raw.trim();
            if (ln == '') { continue; }
            if (ln == 'SUMMARY' || ln == 'SKILLS' || ln == 'EXPERIENCE' || ln == 'EDUCATION' || ln == 'CERTIFICATIONS') {
                section = ln;
                job = null;
                continue;
            }
            if (section == 'SUMMARY') {
                summary.add(ln);
            } else if (section == 'SKILLS' || section == 'CERTIFICATIONS') {
                for (String s : ln.split(',')) {
                    if (String.isBlank(s)) { continue; }
                    if (section == 'SKILLS') { r.skills.add(s.trim()); } else { r.certs.add(s.trim()); }
                }
            } else if (section == 'EXPERIENCE') {
                if (ln.startsWith('- ')) {
                    if (job != null) { job.bullets.add(ln.substring(2)); }
                } else if (job == null || job.dates != null) {                      // a new job: "Title - Employer, City"
                    Integer d = ln.indexOf(' - ');
                    String rest = d > 0 ? ln.substring(d + 3) : '';
                    Integer comma = rest.lastIndexOf(', ');
                    job = new ResumeJob(d > 0 ? ln.substring(0, d) : ln, null, comma > 0 ? rest.substring(0, comma) : rest,
                        comma > 0 ? rest.substring(comma + 2) : '', new List<String>());
                    r.jobs.add(job);
                } else {
                    job.dates = ln;
                }
            } else if (section == 'EDUCATION') {                                     // "Degree - School, 2012 - 2016"
                Integer d = ln.indexOf(' - ');
                String rest = d > 0 ? ln.substring(d + 3) : '';
                Integer comma = rest.lastIndexOf(', ');
                r.eduDegree.add(d > 0 ? ln.substring(0, d) : ln);
                r.eduSchool.add(comma > 0 ? rest.substring(0, comma) : rest);
                r.eduYears.add(comma > 0 ? rest.substring(comma + 2) : '');
            }
        }
        r.summary = String.join(summary, ' ');
        r.title = r.jobs.isEmpty() ? '' : r.jobs[0].title;
        String city = String.isBlank(c.City__c) ? '' : c.City__c + ', India   |   ';
        r.contact = c.Email + '   |   ' + city + 'linkedin.com/in/' + c.FirstName.toLowerCase() + '-' + c.LastName.toLowerCase();
        return r;
    }

    /** One job on a resume. */
    private class ResumeJob {
        String title; String dates; String employer; String city; List<String> bullets;
        ResumeJob(String title, String dates, String employer, String city, List<String> bullets) {
            this.title = title; this.dates = dates; this.employer = employer; this.city = city; this.bullets = bullets;
        }
    }

    /** Everything printed on one resume. */
    private class ResumeDoc {
        String name; String title; String contact; String summary;
        List<String> skills = new List<String>();
        List<ResumeJob> jobs = new List<ResumeJob>();
        List<String> eduDegree = new List<String>();
        List<String> eduYears = new List<String>();
        List<String> eduSchool = new List<String>();
        List<String> certs = new List<String>();
        List<Decimal> accent;
    }

    /** Header colours (red, green, blue 0..1): navy, teal, indigo, burgundy, forest, plum. */
    private static List<List<Decimal>> palette() {
        return new List<List<Decimal>>{
            new List<Decimal>{ 0.10, 0.24, 0.45 }, new List<Decimal>{ 0.06, 0.46, 0.43 }, new List<Decimal>{ 0.29, 0.25, 0.72 },
            new List<Decimal>{ 0.60, 0.10, 0.25 }, new List<Decimal>{ 0.13, 0.43, 0.27 }, new List<Decimal>{ 0.36, 0.16, 0.45 }
        };
    }

    // Helvetica / Helvetica-Bold character widths (1/1000 em) for the characters 32..126, used to wrap and right-align text.
    private static final List<Integer> HELV = new List<Integer>{
        278,278,355,556,556,889,667,191,333,333,389,584,278,333,278,278,556,556,556,556,556,556,556,556,556,556,278,278,584,584,584,556,
        1015,667,667,722,722,667,611,778,722,278,500,667,556,833,722,778,667,778,722,667,611,722,667,944,667,667,611,278,278,278,469,556,
        333,556,556,500,556,556,278,556,556,222,222,500,222,833,556,556,556,556,333,500,278,556,500,722,500,500,500,334,260,334,584 };
    private static final List<Integer> BOLD = new List<Integer>{
        278,333,474,556,556,889,722,238,333,333,389,584,278,333,278,278,556,556,556,556,556,556,556,556,556,556,333,333,584,584,584,611,
        975,722,722,722,722,667,611,778,722,278,556,722,611,833,722,778,667,778,722,667,611,722,667,944,667,667,611,333,278,333,584,556,
        333,556,611,556,611,556,333,611,611,278,278,556,278,889,611,611,611,611,389,556,333,611,556,778,556,556,500,389,280,389,584 };

    private static Blob buildPdf(ResumeDoc r) {
        PdfDoc p = new PdfDoc(r.accent);
        p.header(r.name, r.title, r.contact);
        p.section('Professional Summary', true, 15);
        p.paragraph(r.summary, 10, 14.5, new List<Decimal>{ 0.22, 0.24, 0.27 });
        p.section('Skills', false, 26);
        p.chips(r.skills);
        p.section('Work Experience', false, 50);
        for (ResumeJob j : r.jobs) { p.entry(j.title, j.dates, j.employer + ', ' + j.city, j.bullets); }
        p.section('Education', false, 30);
        for (Integer k = 0; k < r.eduDegree.size(); k++) {
            p.entry(r.eduDegree[k], r.eduYears[k], r.eduSchool[k], new List<String>());
        }
        if (!r.certs.isEmpty()) {
            p.section('Certifications', false, 17);
            p.bullets(r.certs);
        }
        return p.build(r.name);
    }

    /** Minimal PDF page writer. Coordinates are PDF points (612 x 792 page, origin bottom-left). */
    private class PdfDoc {
        final Decimal PAGE_W = 612;
        final Decimal PAGE_H = 792;
        final Decimal LEFT = 48;
        final Decimal CONTENT_W = 516;
        final Decimal RIGHT_X = 564;
        final Decimal BOTTOM = 48;

        List<Decimal> accent;
        List<Decimal> dark;
        List<String> pages = new List<String>();
        String cur = '';
        Decimal y = 0;
        Integer pageNo = 0;

        PdfDoc(List<Decimal> accent) {
            this.accent = accent;
            this.dark = shade(accent, 0.72);
        }

        // ---- helpers -------------------------------------------------------------------------------------
        String n(Decimal d) { return d.setScale(2).toPlainString(); }
        String c3(List<Decimal> rgb) {
            return rgb[0].setScale(3).toPlainString() + ' ' + rgb[1].setScale(3).toPlainString() + ' ' + rgb[2].setScale(3).toPlainString();
        }
        List<Decimal> tint(List<Decimal> rgb, Decimal t) {
            return new List<Decimal>{ rgb[0] + (1 - rgb[0]) * t, rgb[1] + (1 - rgb[1]) * t, rgb[2] + (1 - rgb[2]) * t };
        }
        List<Decimal> shade(List<Decimal> rgb, Decimal f) {
            return new List<Decimal>{ rgb[0] * f, rgb[1] * f, rgb[2] * f };
        }
        String ascii(String s) { return s == null ? '' : s.replaceAll('[^\\x20-\\x7E]', ' '); }

        Decimal textWidth(String s, Boolean isBold, Decimal size) {
            List<Integer> t = isBold ? BOLD : HELV;
            Integer total = 0;
            for (Integer i = 0; i < s.length(); i++) {
                Integer o = s.charAt(i);
                total += (o >= 32 && o <= 126) ? t[o - 32] : 556;
            }
            return Decimal.valueOf(total) * size / 1000;
        }

        List<String> wrap(String s, Boolean isBold, Decimal size, Decimal maxWidth) {
            List<String> out = new List<String>();
            String line = '';
            for (String word : ascii(s).split(' ')) {
                if (word == '') { continue; }
                String trial = line == '' ? word : line + ' ' + word;
                if (line == '' || textWidth(trial, isBold, size) <= maxWidth) { line = trial; }
                else { out.add(line); line = word; }
            }
            if (line != '') { out.add(line); }
            return out;
        }

        // ---- drawing primitives --------------------------------------------------------------------------
        void newPage() {
            if (pageNo > 0) { pages.add(cur); }
            cur = '';
            pageNo++;
            if (pageNo > 1) {
                rect(0, PAGE_H - 10, PAGE_W, 10, accent);
                y = PAGE_H - 50;
            }
        }
        void ensure(Decimal need) { if (y - need < BOTTOM) { newPage(); } }

        void rect(Decimal x, Decimal yy, Decimal w, Decimal h, List<Decimal> rgb) {
            cur += c3(rgb) + ' rg ' + n(x) + ' ' + n(yy) + ' ' + n(w) + ' ' + n(h) + ' re f\n';
        }

        void roundedRect(Decimal x, Decimal yy, Decimal w, Decimal h, Decimal r, List<Decimal> rgb) {
            Decimal k = 0.5523 * r;
            cur += c3(rgb) + ' rg '
                + n(x + r) + ' ' + n(yy) + ' m '
                + n(x + w - r) + ' ' + n(yy) + ' l '
                + n(x + w - r + k) + ' ' + n(yy) + ' ' + n(x + w) + ' ' + n(yy + r - k) + ' ' + n(x + w) + ' ' + n(yy + r) + ' c '
                + n(x + w) + ' ' + n(yy + h - r) + ' l '
                + n(x + w) + ' ' + n(yy + h - r + k) + ' ' + n(x + w - r + k) + ' ' + n(yy + h) + ' ' + n(x + w - r) + ' ' + n(yy + h) + ' c '
                + n(x + r) + ' ' + n(yy + h) + ' l '
                + n(x + r - k) + ' ' + n(yy + h) + ' ' + n(x) + ' ' + n(yy + h - r + k) + ' ' + n(x) + ' ' + n(yy + h - r) + ' c '
                + n(x) + ' ' + n(yy + r) + ' l '
                + n(x) + ' ' + n(yy + r - k) + ' ' + n(x + r - k) + ' ' + n(yy) + ' ' + n(x + r) + ' ' + n(yy) + ' c h f\n';
        }

        void circle(Decimal cx, Decimal cy, Decimal r, List<Decimal> rgb) {
            Decimal k = 0.5523 * r;
            cur += c3(rgb) + ' rg '
                + n(cx + r) + ' ' + n(cy) + ' m '
                + n(cx + r) + ' ' + n(cy + k) + ' ' + n(cx + k) + ' ' + n(cy + r) + ' ' + n(cx) + ' ' + n(cy + r) + ' c '
                + n(cx - k) + ' ' + n(cy + r) + ' ' + n(cx - r) + ' ' + n(cy + k) + ' ' + n(cx - r) + ' ' + n(cy) + ' c '
                + n(cx - r) + ' ' + n(cy - k) + ' ' + n(cx - k) + ' ' + n(cy - r) + ' ' + n(cx) + ' ' + n(cy - r) + ' c '
                + n(cx + k) + ' ' + n(cy - r) + ' ' + n(cx + r) + ' ' + n(cy - k) + ' ' + n(cx + r) + ' ' + n(cy) + ' c h f\n';
        }

        void line(Decimal x1, Decimal y1, Decimal x2, Decimal y2, Decimal width, List<Decimal> rgb) {
            cur += c3(rgb) + ' RG ' + n(width) + ' w ' + n(x1) + ' ' + n(y1) + ' m ' + n(x2) + ' ' + n(y2) + ' l S\n';
        }

        /** font: F1 regular, F2 bold, F3 italic. spacing = extra space between letters. */
        void text(Decimal x, Decimal yy, String s, String font, Decimal size, List<Decimal> rgb, Decimal spacing) {
            String esc = ascii(s).replace('\\', '\\\\').replace('(', '\\(').replace(')', '\\)');
            String tc = spacing == 0 ? '' : n(spacing) + ' Tc ';
            String tc0 = spacing == 0 ? '' : ' 0 Tc';
            cur += 'BT /' + font + ' ' + n(size) + ' Tf ' + tc + c3(rgb) + ' rg ' + n(x) + ' ' + n(yy) + ' Td (' + esc + ') Tj' + tc0 + ' ET\n';
        }

        // ---- building blocks -----------------------------------------------------------------------------
        void header(String name, String title, String contact) {
            newPage();
            rect(0, PAGE_H - 124, PAGE_W, 124, accent);
            rect(0, PAGE_H - 128, PAGE_W, 4, dark);
            text(LEFT, PAGE_H - 56, name, 'F2', 28, new List<Decimal>{ 1, 1, 1 }, 0);
            text(LEFT, PAGE_H - 79, title, 'F1', 13, tint(accent, 0.82), 0);
            text(LEFT, PAGE_H - 103, contact, 'F1', 9, new List<Decimal>{ 1, 1, 1 }, 0);
            y = PAGE_H - 128 - 32;
        }

        void section(String title, Boolean first, Decimal bodyNeed) {
            if (!first) { y -= 14; }
            ensure(26 + bodyNeed);
            text(LEFT, y, title.toUpperCase(), 'F2', 10.5, accent, 1.6);
            line(LEFT, y - 7, RIGHT_X, y - 7, 0.6, new List<Decimal>{ 0.85, 0.86, 0.88 });
            rect(LEFT, y - 8.1, 38, 2.2, accent);
            y -= 26;
        }

        void paragraph(String s, Decimal size, Decimal leading, List<Decimal> rgb) {
            for (String ln : wrap(s, false, size, CONTENT_W)) {
                ensure(leading);
                text(LEFT, y, ln, 'F1', size, rgb, 0);
                y -= leading;
            }
        }

        void chips(List<String> items) {
            Decimal x = LEFT;
            ensure(26);
            for (String it : items) {
                Decimal w = textWidth(it, false, 9) + 20;
                if (x + w > RIGHT_X) {
                    x = LEFT;
                    y -= 26;
                    ensure(26);
                }
                roundedRect(x, y - 5, w, 19, 9.5, tint(accent, 0.90));
                text(x + 10, y + 1, it, 'F1', 9, dark, 0);
                x += w + 6;
            }
            y -= 26;
        }

        void bullets(List<String> items) {
            for (String it : items) {
                List<String> lines = wrap(it, false, 10, CONTENT_W - 16);
                ensure(13.5 * lines.size() + 3);
                circle(LEFT + 4, y + 3.4, 1.9, accent);
                for (String ln : lines) {
                    text(LEFT + 16, y, ln, 'F1', 10, new List<Decimal>{ 0.22, 0.24, 0.27 }, 0);
                    y -= 13.5;
                }
                y -= 3;
            }
        }

        void entry(String title, String right, String sub, List<String> items) {
            Decimal need = items.isEmpty() ? 29.0 : 59.5;
            ensure(need + 6);
            text(LEFT, y, title, 'F2', 11, new List<Decimal>{ 0.08, 0.10, 0.14 }, 0);
            if (String.isNotBlank(right)) {
                text(RIGHT_X - textWidth(right, false, 9.5), y, right, 'F1', 9.5, new List<Decimal>{ 0.42, 0.45, 0.50 }, 0);
            }
            y -= 14.5;
            if (String.isNotBlank(sub)) {
                text(LEFT, y, sub, 'F3', 10, dark, 0);
                y -= 16;
            }
            bullets(items);
            y -= 6;
        }

        // ---- output --------------------------------------------------------------------------------------
        Blob build(String footerName) {
            pages.add(cur);
            Integer total = pages.size();
            List<String> contents = new List<String>();
            for (Integer i = 0; i < total; i++) {
                String c = pages[i];
                if (total > 1) {
                    c += 'BT /F1 8 Tf 0.55 0.57 0.60 rg ' + n(LEFT) + ' 28.00 Td (' + ascii(footerName).replace('(', '').replace(')', '')
                        + '  -  Resume  -  Page ' + (i + 1) + ' of ' + total + ') Tj ET\n';
                }
                contents.add(c);
            }
            List<String> objs = new List<String>();
            objs.add('<< /Type /Catalog /Pages 2 0 R >>');
            List<String> kids = new List<String>();
            for (Integer i = 0; i < total; i++) { kids.add((6 + 2 * i) + ' 0 R'); }
            objs.add('<< /Type /Pages /Kids [' + String.join(kids, ' ') + '] /Count ' + total + ' >>');
            objs.add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>');
            objs.add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>');
            objs.add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Oblique /Encoding /WinAnsiEncoding >>');
            for (Integer i = 0; i < total; i++) {
                objs.add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents ' + (7 + 2 * i)
                    + ' 0 R /Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R >> >> >>');
                objs.add('<< /Length ' + contents[i].length() + ' >>\nstream\n' + contents[i] + '\nendstream');
            }
            String pdf = '%PDF-1.4\n';
            List<Integer> offsets = new List<Integer>();
            for (Integer o = 0; o < objs.size(); o++) {
                offsets.add(pdf.length());
                pdf += (o + 1) + ' 0 obj\n' + objs[o] + '\nendobj\n';
            }
            Integer xrefPos = pdf.length();
            pdf += 'xref\n0 ' + (objs.size() + 1) + '\n0000000000 65535 f \n';
            for (Integer off : offsets) { pdf += String.valueOf(off).leftPad(10, '0') + ' 00000 n \n'; }
            pdf += 'trailer\n<< /Size ' + (objs.size() + 1) + ' /Root 1 0 R >>\nstartxref\n' + xrefPos + '\n%%EOF';
            return Blob.valueOf(pdf);
        }
    }

    // =====================================================================================
    //  BULK ADD:  DemoDataLoader.addBulk(100);
    //  Adds N more candidates (default 100, max 100 per call) with varied roles, seniority, cities, work modes,
    //  salary and skills, each with a designed PDF resume attached. Existing data is not touched.
    //  Resume status is left empty so ResumeParseScheduler.runNow() will parse them.
    // =====================================================================================
    private class Archetype {
        String roles;                 // Role Types picklist value(s)
        String midExtra;              // extra role type for some mid-level people
        String seniorExtra;           // extra role type for some senior people
        List<String> titles;          // junior, mid, senior
        List<String> core;
        List<String> optional;
        List<String> bullets;
        List<String> degrees;
        List<String> certs;
        Integer salary;               // base yearly salary (US dollars) for a mid-level person

        Archetype(String roles, String midExtra, String seniorExtra, List<String> titles, List<String> core,
                  List<String> optional, List<String> bullets, List<String> degrees, List<String> certs, Integer salary) {
            this.roles = roles; this.midExtra = midExtra; this.seniorExtra = seniorExtra; this.titles = titles;
            this.core = core; this.optional = optional; this.bullets = bullets; this.degrees = degrees;
            this.certs = certs; this.salary = salary;
        }
    }

    private static List<Archetype> archetypes() {
        List<String> techDegrees = new List<String>{ 'B.Tech Computer Science', 'B.Tech Information Technology', 'BCA', 'MCA', 'B.Sc Computer Science', 'B.E. Electronics' };
        List<String> bizDegrees = new List<String>{ 'MBA', 'B.Com', 'B.A. Economics', 'BBA', 'B.Tech Information Technology' };
        List<Archetype> a = new List<Archetype>();
        // 0 Salesforce developer
        a.add(new Archetype('Developer', 'Consultant', 'Architect',
            new List<String>{ 'Junior Salesforce Developer', 'Salesforce Developer', 'Senior Salesforce Developer' },
            new List<String>{ 'Apex', 'SOQL', 'Salesforce Flow' },
            new List<String>{ 'Lightning Web Components', 'REST API integration', 'Salesforce DX', 'Git', 'Visualforce', 'JavaScript', 'Experience Cloud', 'CI/CD', 'Aura components' },
            new List<String>{ 'Delivered new features for enterprise customers in an Agile team.', 'Wrote unit tests and fixed production defects.', 'Reviewed code and mentored junior developers.', 'Automated manual business processes to save time.' },
            techDegrees,
            new List<String>{ 'Salesforce Platform Developer I', 'Salesforce Platform Developer II', 'Salesforce JavaScript Developer I' }, 75000));
        // 1 Java developer
        a.add(new Archetype('Developer', null, null,
            new List<String>{ 'Software Engineer', 'Senior Software Engineer', 'Lead Software Engineer' },
            new List<String>{ 'Java', 'Spring Boot', 'SQL' },
            new List<String>{ 'REST APIs', 'Git', 'Microservices', 'Docker', 'Kafka', 'AWS', 'Apex', 'SOQL' },
            new List<String>{ 'Built and maintained back-end services for a high-traffic platform.', 'Improved performance and reliability of critical services.', 'Wrote automated tests and reviewed code.', 'Worked with product teams to deliver releases on schedule.' },
            techDegrees, new List<String>{ 'Oracle Certified Java Programmer', 'AWS Cloud Practitioner' }, 80000));
        // 2 Administrator
        a.add(new Archetype('Administrator', 'Consultant', null,
            new List<String>{ 'Salesforce Support Analyst', 'Salesforce Administrator', 'Senior Salesforce Administrator' },
            new List<String>{ 'Salesforce Flow', 'Reports and Dashboards', 'Permission sets' },
            new List<String>{ 'Data migration', 'Sales Cloud', 'Service Cloud', 'User training', 'Apex (basic)', 'Data Loader', 'Validation rules' },
            new List<String>{ 'Configured the platform for business teams and managed user access.', 'Automated approvals and routine tasks to save hours each week.', 'Trained users and wrote simple guides.', 'Kept data clean and reports accurate for managers.' },
            bizDegrees, new List<String>{ 'Salesforce Administrator', 'Salesforce Platform App Builder', 'Salesforce Advanced Administrator' }, 60000));
        // 3 Architect
        a.add(new Archetype('Architect', 'Consultant', null,
            new List<String>{ 'Senior Consultant', 'Salesforce Solution Architect', 'Principal Architect' },
            new List<String>{ 'Solution architecture', 'Integration patterns', 'Data modeling' },
            new List<String>{ 'Apex', 'Lightning Web Components', 'MuleSoft', 'Pre-sales', 'Governance', 'REST APIs', 'Experience Cloud' },
            new List<String>{ 'Designed solutions for large programmes and led design reviews.', 'Set technical standards and mentored the delivery team.', 'Worked with stakeholders to turn goals into a roadmap.', 'Reduced technical risk through early prototypes.' },
            techDegrees, new List<String>{ 'Salesforce Application Architect', 'Salesforce System Architect' }, 130000));
        // 4 QA
        a.add(new Archetype('QA Engineer', null, null,
            new List<String>{ 'QA Analyst', 'QA Engineer', 'Senior QA Engineer' },
            new List<String>{ 'Test automation', 'JIRA', 'Regression testing' },
            new List<String>{ 'Selenium', 'Provar', 'Postman', 'API testing', 'Apex test classes', 'Cypress' },
            new List<String>{ 'Planned and ran test cycles for every release.', 'Logged and tracked defects until they were fixed.', 'Built reusable test suites to speed up regression testing.', 'Worked with developers to reproduce and fix issues.' },
            techDegrees, new List<String>{ 'ISTQB Foundation', 'Salesforce Administrator' }, 55000));
        // 5 Business analyst
        a.add(new Archetype('Business Analyst', 'Project Manager', null,
            new List<String>{ 'Associate Business Analyst', 'Business Analyst', 'Senior Business Analyst' },
            new List<String>{ 'Requirement gathering', 'User stories', 'UAT' },
            new List<String>{ 'JIRA', 'Confluence', 'Process mapping', 'Stakeholder management', 'SQL', 'Agile' },
            new List<String>{ 'Gathered requirements from business teams and wrote clear user stories.', 'Ran workshops and sign-offs with stakeholders.', 'Coordinated acceptance testing before each release.', 'Mapped current processes and found areas to improve.' },
            bizDegrees, new List<String>{ 'CBAP', 'Professional Scrum Master I' }, 70000));
        // 6 Project manager
        a.add(new Archetype('Project Manager', null, null,
            new List<String>{ 'Project Coordinator', 'Project Manager', 'Senior Project Manager' },
            new List<String>{ 'Project planning', 'Stakeholder management', 'Agile' },
            new List<String>{ 'JIRA', 'Risk management', 'Budgeting', 'Scrum', 'MS Project' },
            new List<String>{ 'Planned releases and tracked delivery against budget and schedule.', 'Managed risks, dependencies and stakeholder updates.', 'Ran regular reviews with the delivery team.', 'Delivered projects on time across several teams.' },
            bizDegrees, new List<String>{ 'PMP', 'Professional Scrum Master I' }, 95000));
        // 7 Data analyst
        a.add(new Archetype('Data Analyst', null, null,
            new List<String>{ 'Junior Data Analyst', 'Data Analyst', 'Senior Data Analyst' },
            new List<String>{ 'SQL', 'Excel', 'Data visualization' },
            new List<String>{ 'Tableau', 'Power BI', 'Python', 'Statistics', 'R', 'dbt' },
            new List<String>{ 'Built dashboards used by managers to make decisions.', 'Cleaned and combined data from several sources.', 'Automated weekly reporting to save analyst time.', 'Presented findings and recommendations to leadership.' },
            new List<String>{ 'M.Sc Statistics', 'B.Sc Mathematics', 'B.Tech Computer Science', 'MBA' }, new List<String>{ 'Tableau Desktop Specialist', 'Microsoft Power BI Data Analyst' }, 65000));
        // 8 Designer
        a.add(new Archetype('Designer', null, null,
            new List<String>{ 'Junior UI Designer', 'UI/UX Designer', 'Senior UI/UX Designer' },
            new List<String>{ 'Figma', 'Wireframing', 'Prototyping' },
            new List<String>{ 'User research', 'Design systems', 'Adobe XD', 'Accessibility', 'Usability testing' },
            new List<String>{ 'Designed screens and flows for web and mobile products.', 'Ran usability tests and improved designs from feedback.', 'Worked closely with developers to hand off designs.', 'Kept designs consistent across products.' },
            new List<String>{ 'B.Des', 'M.Des', 'B.A. Visual Communication' }, new List<String>(), 60000));
        // 9 Product manager
        a.add(new Archetype('Product Manager', null, null,
            new List<String>{ 'Associate Product Manager', 'Product Manager', 'Senior Product Manager' },
            new List<String>{ 'Roadmapping', 'Backlog management', 'Stakeholder management' },
            new List<String>{ 'JIRA', 'A/B testing', 'SQL', 'User research', 'Agile' },
            new List<String>{ 'Owned the product roadmap and prioritised the backlog.', 'Worked with design and engineering to ship features.', 'Used customer feedback and data to choose what to build.', 'Wrote clear requirements and acceptance criteria.' },
            bizDegrees, new List<String>{ 'Pragmatic Product Management' }, 100000));
        return a;
    }

    public static void addBulk(Integer count) {
        Integer n = (count == null || count < 1) ? 100 : Math.min(count, 100);
        Integer startIdx = [SELECT COUNT() FROM Contact WHERE Email LIKE 'bulk.%@demo-candidates.example'];

        List<Archetype> arcs = archetypes();
        // more developers than other roles, because the demo jobs are developer jobs
        List<Integer> mix = new List<Integer>{ 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
        List<String> firsts = new List<String>{ 'Aditya', 'Ananya', 'Arjun', 'Bhavna', 'Chirag', 'Deepak', 'Divya', 'Esha', 'Farhan', 'Gaurav',
            'Harsh', 'Ishaan', 'Jatin', 'Kavya', 'Lakshay', 'Meera', 'Naman', 'Ojas', 'Pooja', 'Qasim', 'Riya', 'Sahil', 'Tanvi', 'Utkarsh',
            'Varun', 'Yamini', 'Zoya', 'Abhishek', 'Bhuvan', 'Charu', 'Dhruv', 'Ekta', 'Falguni', 'Girish', 'Hemant', 'Ira', 'Jayant', 'Kriti',
            'Lokesh', 'Manya' };
        List<String> lasts = new List<String>{ 'Agarwal', 'Bansal', 'Chauhan', 'Deshmukh', 'Fernandes', 'Gill', 'Hegde', 'Joshi', 'Kulkarni',
            'Menon', 'Naidu', 'Oberoi', 'Pandey', 'Qureshi', 'Rathore', 'Saxena', 'Tiwari', 'Upadhyay', 'Vyas', 'Wadhwa', 'Yadav', 'Zaveri',
            'Bhatt', 'Chopra', 'Dutta' };
        List<String> cities = new List<String>{ 'Jaipur', 'Jaipur', 'Jaipur', 'Bengaluru', 'Pune', 'Hyderabad', 'Delhi', 'Mumbai', 'Chennai', 'Noida' };
        List<String> modeCombos = new List<String>{ 'Hybrid', 'Remote', 'On-site', 'Hybrid;Remote', 'On-site;Hybrid', 'Remote;Hybrid;On-site' };
        List<String> employers = new List<String>{ 'Brightwave Technologies', 'Cloudnine Solutions', 'Northstar Digital', 'Pixel Labs', 'Orbit Systems',
            'Bluepeak Consulting', 'Greenfield Infotech', 'Sunrise Retail', 'Vertex Consulting', 'Altitude Partners', 'Quantum Soft', 'Metro Systems',
            'Lumen Corp', 'Starlight IT', 'Insight Analytics', 'Orbit Digital', 'Kite Software', 'Zenith Labs', 'Harbor Technologies', 'Crescent Systems',
            'Maple Software', 'Redwood Consulting', 'Silverline Digital', 'Evergreen Tech' };
        List<String> months = new List<String>{ 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' };
        List<String> colleges = new List<String>{ 'Rajasthan Technical University', 'Jaipur Institute of Engineering', 'Poornima College of Engineering',
            'Visvesvaraya Technological University', 'Savitribai Phule Pune University', 'Osmania University', 'Delhi Technological University',
            'Anna University', 'University of Mumbai', 'Amity University' };

        List<Contact> contacts = new List<Contact>();
        List<List<String>> resumes = new List<List<String>>();
        Integer thisYear = Date.today().year();
        for (Integer i = 0; i < n; i++) {
            Integer idx = startIdx + i;
            Archetype arc = arcs[mix[Math.mod(idx, mix.size())]];
            Integer yrs = 1 + Math.mod(idx * 5, 14);                           // 1..14 years of experience
            Integer level = yrs < 3 ? 0 : (yrs < 7 ? 1 : 2);                  // junior / mid / senior
            String firstName = firsts[Math.mod(idx, firsts.size())];
            String lastName = lasts[Math.mod(idx * 7 + idx / firsts.size(), lasts.size())];
            String city = cities[Math.mod(idx * 3, cities.size())];
            String modes = modeCombos[Math.mod(idx * 5 + 1, modeCombos.size())];

            String roles = arc.roles;
            if (level == 2 && arc.seniorExtra != null && Math.mod(idx, 2) == 0) { roles += ';' + arc.seniorExtra; }
            if (level == 1 && arc.midExtra != null && Math.mod(idx, 3) == 0) { roles += ';' + arc.midExtra; }

            Integer mult = level == 0 ? 70 : (level == 1 ? 100 : 140);
            Integer salary = Math.max(20000, (arc.salary * mult / 100 / 2500) * 2500 + (Math.mod(idx * 13, 5) - 2) * 2500);   // US dollars, steps of 2,500

            // skills: all core skills plus a rotating subset of the optional ones (so some people lack some skills on purpose)
            List<String> skills = new List<String>(arc.core);
            Integer extra = Math.min(arc.optional.size(), 2 + level + Math.mod(idx, 3));
            Integer offset = Math.mod(idx * 5, arc.optional.size());
            for (Integer k = 0; k < extra; k++) { skills.add(arc.optional[Math.mod(offset + k, arc.optional.size())]); }

            // resume text
            List<String> lines = new List<String>();
            String title = arc.titles[level];
            lines.add('SUMMARY');
            lines.add(title + ' with ' + yrs + ' years of experience in ' + skills[0] + ', ' + skills[1] + ' and ' + skills[2] + '. Based in ' + city + '.');
            lines.add('');
            lines.add('SKILLS');
            lines.add(String.join(skills, ', '));
            lines.add('');
            lines.add('EXPERIENCE');
            Integer curYears = Math.max(1, yrs / 2);
            Integer curStart = thisYear - curYears;
            String prevTitle = arc.titles[Math.max(0, level - 1)];
            addJob(lines, title, employers[Math.mod(idx, employers.size())], city,
                months[Math.mod(idx, 12)] + ' ' + curStart, 'Present', arc.bullets, idx, 2);
            Integer remaining = yrs - curYears;
            if (remaining >= 1) {
                if (yrs >= 9 && remaining >= 4) {
                    Integer mid = curStart - remaining / 2;
                    addJob(lines, prevTitle, employers[Math.mod(idx + 5, employers.size())], cities[Math.mod(idx + 2, cities.size())],
                        'Jan ' + mid, 'Dec ' + (curStart - 1), arc.bullets, idx + 2, 1);
                    addJob(lines, arc.titles[0], employers[Math.mod(idx + 11, employers.size())], cities[Math.mod(idx + 4, cities.size())],
                        'Jul ' + (curStart - remaining), 'Dec ' + (mid - 1), arc.bullets, idx + 3, 1);
                } else {
                    addJob(lines, prevTitle, employers[Math.mod(idx + 5, employers.size())], cities[Math.mod(idx + 2, cities.size())],
                        'Jul ' + (curStart - remaining), 'Dec ' + (curStart - 1), arc.bullets, idx + 2, 2);
                }
            }
            Integer gradEnd = thisYear - yrs;
            lines.add('');
            lines.add('EDUCATION');
            lines.add(arc.degrees[Math.mod(idx, arc.degrees.size())] + ' - ' + colleges[Math.mod(idx * 3, colleges.size())]
                + ', ' + (gradEnd - 4) + ' - ' + gradEnd);
            if (!arc.certs.isEmpty() && Math.mod(idx, 4) != 0) {
                lines.add('');
                lines.add('CERTIFICATIONS');
                String certs = arc.certs[Math.mod(idx, arc.certs.size())];
                if (arc.certs.size() > 1 && Math.mod(idx, 3) == 0) { certs += ', ' + arc.certs[Math.mod(idx + 1, arc.certs.size())]; }
                lines.add(certs);
            }

            contacts.add(new Contact(
                FirstName = firstName, LastName = lastName,
                Email = 'bulk.' + firstName.toLowerCase() + '.' + lastName.toLowerCase() + '.' + (idx + 1) + '@demo-candidates.example',
                City__c = city, Work_Modes__c = modes, Expected_Salary__c = salary, Role_Types__c = roles, Has_Resume__c = true));
            resumes.add(lines);
        }
        insert contacts;

        Integer fileCount = attachResumes(contacts, resumes);

        System.debug('BULK DEMO DATA ADDED: ' + contacts.size() + ' contacts and ' + fileCount + ' PDF resumes (numbers '
            + (startIdx + 1) + ' to ' + (startIdx + n) + ').');
        System.debug('Total demo contacts with Has_Resume__c = true: '
            + [SELECT COUNT() FROM Contact WHERE Email LIKE '%@demo-candidates.example' AND Has_Resume__c = true]);
    }

    private static void addJob(List<String> lines, String title, String employer, String city, String startText, String endText,
                               List<String> bullets, Integer seed, Integer count) {
        lines.add(title + ' - ' + employer + ', ' + city);
        lines.add(startText + ' - ' + endText);
        for (Integer k = 0; k < count; k++) { lines.add('- ' + bullets[Math.mod(seed + k, bullets.size())]); }
    }
}
