/**
 * DEMO DATA loader for the Candidate Matcher. Everything here is EXECUTIVE LEADERSHIP: 6 executive jobs (Chief Technology Officer,
 * Chief Financial Officer, Chief Information Security Officer, Chief Revenue Officer, Vice President of Operations, Chief Data Officer)
 * and 12 hand-written executive candidates (11 with a PDF resume), plus any number of extra generated candidates: directors, vice
 * presidents and C-level leaders from nine functions (technology, IT, finance, operations, revenue, security, data, people, product).
 * Every resume is a designed, professional-looking PDF. The skills on the jobs and on the resumes are leadership skills (strategy,
 * governance, P&L management, board reporting, M&A, transformation), not hands-on developer, tester or analyst skills, and every
 * career climbs from manager to director, vice president and C-level, with 8 to 26 years of experience.
 * Everything is set in Canada: candidates live in Canadian cities (Contact City__c holds the plain city name, e.g. "Toronto"),
 * each resume prints the province ("Toronto, ON"), employers are fictional Canadian companies and education is from Canadian
 * universities. A few candidates are bilingual (English and French) or list Canadian designations such as CPA, CPHR or ICD.D.
 * All text is plain ASCII on purpose: the PDF writer below prints only ASCII, so accented letters are not used (the city is
 * written "Montreal", not the accented French spelling).
 *
 * Role Types (Role_Types__c): jobs and candidates get executive role types by function (Technology Executive, IT Executive, Finance
 * Executive, Operations Executive, Revenue Executive, Security Executive, Data Executive, HR Executive, Product Executive). Those values
 * are in the restricted Role_Types__c picklist on Contact and on Job (deploy the two Role_Types__c field files, or add the same values by
 * hand in Setup). The loader only sets values the picklist really has, so without them Role Types simply stays empty and nothing fails.
 *
 * Candidate_Profile__c is deliberately NEVER filled in here: the resume parser writes it, so after loading you run the
 * parse (e.g. ResumeParseScheduler.runNow()) and each profile appears by itself. Resume_Parse_Status__c stays empty so the
 * parser picks the contacts up.
 *
 * Deploy this class, then run in Developer Console > Execute Anonymous:
 *     DemoDataLoader.run();             // creates the 6 jobs and the 12 candidates (first removes an earlier demo run)
 *     DemoDataLoader.addBulk(100);      // ADDS 100 more candidates, each with a designed PDF resume. Up to 25 are added right away;
 *                                       // more than that runs in the background, 25 at a time (a designed PDF costs about 0.1 second
 *                                       // of CPU and one call has 10 seconds). Watch it in Setup > Apex Jobs. Deletes nothing.
 *     DemoDataLoader.addBulkAsync(500); // the same in the background for any number (up to 5,000 per call); addBulk(500) does this too
 *     DemoDataLoader.addMatchingCandidates(4); // ADDS up to 4 candidates for EACH job (24 in all) made to fit that job: its city, work
 *                                       // mode, salary, role type, minimum experience and every skill it asks for. Run it after run().
 *     DemoDataLoader.addExtraJobs();    // ADDS the 3 extra jobs (Chief Revenue Officer, Vice President of Operations, Chief Data
 *                                       // Officer) to an existing demo data set without touching anything else
 *     DemoDataLoader.cleanup();         // removes ALL demo data (also the bulk candidates)
 *     Blob b = DemoDataLoader.previewResumePdf(0);   // builds hand-written resume 0..11 in memory (no records created)
 * All salaries are yearly Canadian dollars, CAD (candidates about $155,000-$395,000, jobs $240,000-$350,000). The Currency fields
 * show the org's currency, so set the org currency to CAD if you want the symbol and code to read CAD.
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
            Role_Types__c = knownRoles(false, (String) p.get('roles')),
            Date_Available__c = Date.today().addDays(AVAILABLE_IN_DAYS[Math.mod(Math.abs((f + l).hashCode()), AVAILABLE_IN_DAYS.size())]),
            Has_Resume__c = (Boolean) p.get('resume'));
    }

    /** Builds hand-written resume number 0..11 in memory only (nothing is inserted). Handy to look at the design. */
    public static Blob previewResumePdf(Integer personIndex) {
        List<Map<String, Object>> people = buildPeople();
        Map<String, Object> p = people[Math.mod(personIndex == null ? 0 : personIndex, people.size())];
        return buildPdf(parseResume(contactFor(p), (List<String>) p.get('lines')));
    }

    /** Adds the 3 extra executive jobs to an existing demo data set (skips any that already exist). Nothing is deleted. */
    public static void addExtraJobs() {
        Set<String> have = new Set<String>();
        for (Job__c j : [SELECT Name FROM Job__c WHERE Name LIKE 'DEMO - %']) { have.add(j.Name); }
        List<Job__c> toAdd = new List<Job__c>();
        for (Job__c j : extraJobs()) { if (!have.contains(j.Name)) { toAdd.add(j); } }
        insert toAdd;
        System.debug('DEMO JOBS ADDED: ' + toAdd.size());
    }

    private static List<Job__c> extraJobs() {
        return withKnownRoles(new List<Job__c>{
            new Job__c(
                Name = 'DEMO - Chief Revenue Officer',
                Job_Description__c = '<p><b>Chief Revenue Officer</b> (remote)</p>'
                    + '<p>Reporting to the CEO, you will own revenue growth across sales, partnerships and customer success for a Canadian '
                    + 'software company. At least 12 years of experience, including 5 years leading a sales organization of 100 people or more.</p>'
                    + '<ul><li>Revenue growth strategy</li><li>Go-to-market strategy</li><li>Sales leadership</li><li>Enterprise sales</li>'
                    + '<li>Pipeline forecasting</li></ul>'
                    + '<p>Nice to have: Channel partnerships, CRM platform strategy, Customer success.</p>',
                Work_Modes__c = 'Remote', Expected_Salary__c = 330000,
                Role_Types__c = 'Revenue Executive', Min_Experience_Years__c = 12),
            new Job__c(
                Name = 'DEMO - Vice President of Operations',
                Job_Description__c = '<p><b>Vice President of Operations</b> (Mississauga, on-site)</p>'
                    + '<p>Run plant and distribution operations for a Canadian manufacturer with about 1,500 employees. At least 12 years of '
                    + 'operations experience, including 4 years as a director or above, with full P&amp;L responsibility.</p>'
                    + '<ul><li>Operations strategy</li><li>P&amp;L management</li><li>Process improvement</li><li>Supply chain management</li>'
                    + '<li>Change management</li></ul>'
                    + '<p>Nice to have: Lean Six Sigma Black Belt, Cost optimization.</p>',
                City__c = 'Mississauga', Work_Modes__c = 'On-site', Expected_Salary__c = 240000,
                Role_Types__c = 'Operations Executive', Min_Experience_Years__c = 12),
            new Job__c(
                Name = 'DEMO - Chief Data Officer',
                Job_Description__c = '<p><b>Chief Data Officer</b> (Montreal, hybrid)</p>'
                    + '<p>Build the enterprise data office of a Quebec retailer: data governance, analytics and AI. At least 12 years of experience, '
                    + 'including 4 years leading a data or analytics organization. Fluent English and French are required.</p>'
                    + '<ul><li>Data strategy</li><li>Data governance</li><li>Advanced analytics</li><li>AI strategy</li><li>Data privacy</li></ul>'
                    + '<p>Nice to have: Machine learning oversight, Master data management, Data platform architecture.</p>',
                City__c = 'Montreal', Work_Modes__c = 'Hybrid', Expected_Salary__c = 300000,
                Role_Types__c = 'Data Executive', Min_Experience_Years__c = 12)
        });
    }

    private static List<Job__c> buildJobs() {
        List<Job__c> jobs = new List<Job__c>{
            new Job__c(
                Name = 'DEMO - Chief Technology Officer',
                Job_Description__c = '<p><b>Chief Technology Officer</b> (Toronto, hybrid)</p>'
                    + '<p>Reporting to the CEO, you will own the technology strategy, enterprise architecture and engineering organization of a '
                    + 'Canadian financial services group. At least 15 years of experience, including 5 years in a senior technology leadership role '
                    + 'and a record of leading large digital transformation programs.</p>'
                    + '<ul><li>Technology strategy</li><li>Enterprise architecture</li><li>Digital transformation</li><li>Cloud strategy</li>'
                    + '<li>Engineering leadership</li></ul>'
                    + '<p>Nice to have: Board reporting, M&amp;A technology integration, AI strategy, ICD.D designation.</p>',
                City__c = 'Toronto', Work_Modes__c = 'Hybrid', Expected_Salary__c = 350000,
                Role_Types__c = 'Technology Executive', Min_Experience_Years__c = 15),
            new Job__c(
                Name = 'DEMO - Chief Financial Officer',
                Job_Description__c = '<p><b>Chief Financial Officer</b> (Calgary, hybrid)</p>'
                    + '<p>Own financial strategy, reporting and capital allocation for a Canadian energy company. At least 15 years of experience, '
                    + 'including 5 years as a finance executive. CPA designation required.</p>'
                    + '<ul><li>Financial strategy</li><li>Financial reporting</li><li>Budgeting and forecasting</li><li>Capital markets</li>'
                    + '<li>M&amp;A and due diligence</li></ul>'
                    + '<p>Nice to have: Investor relations, IFRS, ICD.D designation.</p>',
                City__c = 'Calgary', Work_Modes__c = 'Hybrid', Expected_Salary__c = 340000,
                Role_Types__c = 'Finance Executive', Min_Experience_Years__c = 15),
            new Job__c(
                Name = 'DEMO - Chief Information Security Officer',
                Job_Description__c = '<p><b>Chief Information Security Officer</b> (Ottawa, hybrid)</p>'
                    + '<p>Own cyber security strategy, risk and regulatory compliance for a Canadian crown corporation and report to the board audit '
                    + 'committee. At least 12 years of security experience, including 4 years leading a security organization.</p>'
                    + '<ul><li>Cybersecurity strategy</li><li>Security governance</li><li>Risk management</li><li>Incident response</li>'
                    + '<li>Regulatory compliance</li></ul>'
                    + '<p>Nice to have: Zero trust architecture, Identity and access management, CISSP or CISM, Enhanced Reliability Status.</p>',
                City__c = 'Ottawa', Work_Modes__c = 'Hybrid', Expected_Salary__c = 285000,
                Role_Types__c = 'Security Executive', Min_Experience_Years__c = 12)
        };
        jobs.addAll(extraJobs());
        return withKnownRoles(jobs);
    }

    private static List<Map<String, Object>> buildPeople() {
        List<Map<String, Object>> people = new List<Map<String, Object>>();

        // 0 - a strong fit for the Chief Technology Officer job
        people.add(new Map<String, Object>{ 'first' => 'Liam', 'last' => 'Fraser', 'city' => 'Toronto', 'modes' => 'Hybrid;Remote',
            'salary' => 360000, 'roles' => 'Technology Executive', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Chief technology officer with 22 years of experience leading engineering, enterprise architecture and digital transformation programs for banking and insurance companies.',
            '', 'SKILLS',
            'Technology strategy, Enterprise architecture, Digital transformation, Cloud strategy, Engineering leadership, Board reporting, M&A technology integration, Vendor management, AI strategy, Budgeting and forecasting, Talent development',
            '', 'EXPERIENCE',
            'Chief Technology Officer - Bayview Financial Group, Toronto, ON', 'Mar 2020 - Present',
            '- Leads a 420-person technology organization with a yearly budget of $95 million.',
            '- Moved 70 percent of workloads to the cloud and closed two data centres, saving $18 million a year.',
            '- Presents the technology roadmap and cyber risk to the board every quarter.',
            'Vice President, Engineering - Lakeshore Capital, Toronto, ON', 'Jan 2015 - Feb 2020',
            '- Rebuilt the digital banking platform and cut the release cycle from 3 months to 2 weeks.',
            '- Integrated the technology of two acquired wealth managers within 14 months.',
            'Director of Architecture - Harbourfront Bank, Toronto, ON', 'Jul 2010 - Dec 2014',
            '- Defined the enterprise architecture and API standards for 12 business lines.',
            'Software Development Manager - Maple Systems, Mississauga, ON', 'Jul 2004 - Jun 2010',
            '- Built and led three agile teams delivering trading and payments software.',
            '', 'EDUCATION', 'MBA - University of Toronto, 2011 - 2013', 'B.Eng. Computer Engineering - McMaster University, 2000 - 2004',
            '', 'CERTIFICATIONS', 'ICD.D, TOGAF Certified' }});

        // 1 - a Chief Information Officer in Vancouver who only wants remote work (the city filter removes her for a Toronto job)
        people.add(new Map<String, Object>{ 'first' => 'Mei', 'last' => 'Chen', 'city' => 'Vancouver', 'modes' => 'Remote',
            'salary' => 330000, 'roles' => 'IT Executive;Technology Executive', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Chief information officer with 20 years of experience running IT and enterprise architecture for energy and logistics companies. Open to interim and advisory mandates.',
            '', 'SKILLS',
            'IT strategy, Enterprise architecture, Digital transformation, Cloud strategy, IT governance, Vendor management, CRM platform strategy, Cybersecurity oversight, ERP implementation, Budgeting and forecasting, Change management',
            '', 'EXPERIENCE',
            'Chief Information Officer - Cascadia Energy, Vancouver, BC', 'Jun 2019 - Present',
            '- Owns the IT strategy and a $60 million budget for 6,000 employees across Western Canada.',
            '- Delivered a 3-year ERP and CRM replacement on time and 8 percent under budget.',
            '- Cut vendor spend by 22 percent by moving 40 contracts to 9 strategic partners.',
            'Vice President, Technology - Pacific Rim Logistics, Vancouver, BC', 'Jan 2014 - May 2019',
            '- Led enterprise architecture, infrastructure and applications for a national logistics network.',
            '- Introduced IT governance and a portfolio office that raised on-time project delivery from 60 to 90 percent.',
            'Director of Enterprise Architecture - Fraser Valley Health Network, Burnaby, BC', 'Jul 2008 - Dec 2013',
            '- Designed the integration architecture connecting 14 hospitals and community clinics.',
            'IT Project Manager - Granite Peak Mining, Vancouver, BC', 'Jul 2006 - Jun 2008',
            '- Delivered the first company-wide ERP rollout across 5 mine sites.',
            '', 'EDUCATION', 'MBA - Simon Fraser University, 2012 - 2014', 'B.A.Sc. Computer Engineering - University of British Columbia, 2002 - 2006',
            '', 'CERTIFICATIONS', 'TOGAF Certified, ITIL 4 Foundation' }});

        // 2 - a Vice President of Engineering, a near miss for the CTO job (not C-level yet, fewer years)
        people.add(new Map<String, Object>{ 'first' => 'Harpreet', 'last' => 'Dhillon', 'city' => 'Toronto', 'modes' => 'On-site;Hybrid',
            'salary' => 215000, 'roles' => 'Technology Executive', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Vice president of engineering with 14 years of experience scaling software teams and cloud platforms for insurance and fintech companies. Ready for a first CTO role.',
            '', 'SKILLS',
            'Engineering leadership, Cloud strategy, Technology strategy, Agile at scale, Talent development, Budgeting and forecasting, Vendor management, DevOps',
            '', 'EXPERIENCE',
            'Vice President, Engineering - Bluewater Insurance Group, Toronto, ON', 'Aug 2021 - Present',
            '- Leads 9 managers and 120 engineers building the claims and policy platforms.',
            '- Moved the platform to the cloud and reduced production incidents by 45 percent.',
            'Director of Engineering - Timberline Technologies, Mississauga, ON', 'Jun 2017 - Jul 2021',
            '- Grew the engineering team from 25 to 70 people and introduced one shared delivery process.',
            'Senior Engineering Manager - Skyline Fintech, Toronto, ON', 'Jul 2012 - May 2017',
            '- Managed two product teams delivering a mobile payments app used by 300,000 customers.',
            '', 'EDUCATION', 'B.Sc. Computer Science - York University, 2008 - 2012',
            '', 'CERTIFICATIONS', 'AWS Certified Solutions Architect' }});

        // 3 - a bilingual Chief Data Officer in Montreal, a strong fit for the Chief Data Officer job
        people.add(new Map<String, Object>{ 'first' => 'Isabelle', 'last' => 'Bouchard', 'city' => 'Montreal', 'modes' => 'Hybrid',
            'salary' => 310000, 'roles' => 'Data Executive', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Bilingual (English and French) chief data officer with 18 years of experience building data governance, analytics and AI programs for retail and insurance companies.',
            '', 'SKILLS',
            'Data strategy, Data governance, Advanced analytics, AI strategy, Machine learning oversight, Data platform architecture, Data privacy, Master data management, Stakeholder management, English (fluent), French (fluent)',
            '', 'EXPERIENCE',
            'Chief Data Officer - Laurentian Retail Group, Montreal, QC', 'Feb 2021 - Present',
            '- Built the enterprise data office from scratch with a team of 85 data and AI specialists.',
            '- Launched demand forecasting models that cut stock write-offs by $12 million a year.',
            '- Leads data privacy compliance under Quebec Law 25 and PIPEDA.',
            'Vice President, Data and Analytics - Maple Harbour Insurance, Montreal, QC', 'Mar 2016 - Jan 2021',
            '- Set up data governance and a self-service analytics platform used by 2,500 employees.',
            '- Created the pricing analytics team that improved the loss ratio by 3 points.',
            'Director of Business Intelligence - Redwood Financial, Montreal, QC', 'Jul 2011 - Feb 2016',
            '- Led reporting and analytics for the retail banking division.',
            'Senior Analyst - Great Lakes Analytics, Toronto, ON', 'Jul 2008 - Jun 2011',
            '- Built statistical models for credit risk and customer churn.',
            '', 'EDUCATION', 'M.Sc. Statistics - McGill University, 2006 - 2008', 'B.Sc. Mathematics - Concordia University, 2003 - 2006',
            '', 'CERTIFICATIONS', 'DAMA CDMP, ICD.D' }});

        // 4 - a Chief Information Security Officer in Ottawa, a strong fit for the Chief Information Security Officer job
        people.add(new Map<String, Object>{ 'first' => 'Daniel', 'last' => 'MacDonald', 'city' => 'Ottawa', 'modes' => 'Hybrid',
            'salary' => 290000, 'roles' => 'Security Executive', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Chief information security officer with 24 years of experience in cyber security strategy, risk management and regulatory compliance, including federal government programs.',
            '', 'SKILLS',
            'Cybersecurity strategy, Security governance, Risk management, Incident response, Regulatory compliance, Identity and access management, Zero trust architecture, Privacy compliance, Vendor risk management, Board reporting, Stakeholder management',
            '', 'EXPERIENCE',
            'Chief Information Security Officer - Rideau Holdings, Ottawa, ON', 'Mar 2018 - Present',
            '- Runs security for 9,000 employees and cut critical incidents by 60 percent in three years.',
            '- Introduced zero trust access and a 24 hour security operations centre.',
            '- Reports cyber risk to the audit committee and the board every quarter.',
            'Director of Information Security - Capital Region Utilities, Ottawa, ON', 'Jan 2011 - Feb 2018',
            '- Built the security program for critical infrastructure and passed every regulator audit.',
            'Senior Security Consultant - Altitude Partners, Gatineau, QC', 'Jul 2005 - Dec 2010',
            '- Delivered security assessments for federal departments and crown corporations.',
            'Network Engineer - Kanata Networks, Ottawa, ON', 'Jul 2002 - Jun 2005',
            '- Designed and secured networks for a telecom equipment maker.',
            '', 'EDUCATION', 'B.Eng. Electrical Engineering - Carleton University, 1998 - 2002',
            '', 'CERTIFICATIONS', 'CISSP, CISM, Enhanced Reliability Status' }});

        // 5 - a Vice President of Operations in Mississauga, a strong fit for the Vice President of Operations job
        people.add(new Map<String, Object>{ 'first' => 'Fatima', 'last' => 'Ahmed', 'city' => 'Mississauga', 'modes' => 'On-site;Hybrid',
            'salary' => 245000, 'roles' => 'Operations Executive', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Vice president of operations with 16 years of experience improving cost, quality and delivery in manufacturing and distribution businesses.',
            '', 'SKILLS',
            'Operations strategy, P&L management, Process improvement, Lean Six Sigma, Supply chain management, Cost optimization, Change management, Vendor management, Organizational design, Health and safety',
            '', 'EXPERIENCE',
            'Vice President, Operations - Great Lakes Manufacturing, Mississauga, ON', 'Jan 2020 - Present',
            '- Runs 6 plants and 1,800 employees with a $420 million revenue base.',
            '- Cut the cost per unit by 11 percent through Lean programs and supplier consolidation.',
            '- Improved on-time delivery from 87 to 97 percent.',
            'Director of Operations - Kingsway Retail Group, Brampton, ON', 'Jun 2015 - Dec 2019',
            '- Ran the national distribution network of 5 centres and 600 staff.',
            'Operations Manager - Pinnacle Packaging, Mississauga, ON', 'Jul 2010 - May 2015',
            '- Led plant operations and a continuous improvement team of 15 people.',
            '', 'EDUCATION', 'MBA - York University, 2013 - 2015', 'B.A.Sc. Industrial Engineering - University of Toronto, 2006 - 2010',
            '', 'CERTIFICATIONS', 'Lean Six Sigma Black Belt, PMP' }});

        // 6 - a Chief Financial Officer in Calgary, a strong fit for the Chief Financial Officer job
        people.add(new Map<String, Object>{ 'first' => 'Jason', 'last' => 'Nguyen', 'city' => 'Calgary', 'modes' => 'Hybrid',
            'salary' => 335000, 'roles' => 'Finance Executive', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Chief financial officer with 21 years of experience in financial strategy, capital markets and M&A for energy and infrastructure companies.',
            '', 'SKILLS',
            'Financial strategy, Financial reporting, Budgeting and forecasting, Capital markets, M&A and due diligence, Treasury, Investor relations, Audit and controls, IFRS, Board reporting',
            '', 'EXPERIENCE',
            'Chief Financial Officer - Prairie Energy Corporation, Calgary, AB', 'Apr 2019 - Present',
            '- Leads finance, treasury, tax and investor relations for a company with $2.8 billion in revenue.',
            '- Raised $900 million in debt and equity and lowered the cost of capital by 0.8 points.',
            '- Completed three acquisitions worth $650 million and merged each finance team within a year.',
            'Vice President, Finance - Northern Lights Energy, Calgary, AB', 'Jan 2013 - Mar 2019',
            '- Ran financial planning, reporting and the yearly audit for four business units.',
            '- Led the move to IFRS reporting across all subsidiaries.',
            'Director of Corporate Finance - Granite Peak Resources, Calgary, AB', 'Jul 2008 - Dec 2012',
            '- Managed capital planning and investor presentations.',
            'Senior Financial Analyst - Redwood Financial, Toronto, ON', 'Jul 2005 - Jun 2008',
            '- Built valuation models for corporate lending and M&A advice.',
            '', 'EDUCATION', 'MBA - University of Alberta, 2009 - 2011', 'B.Comm. - University of Calgary, 2001 - 2005',
            '', 'CERTIFICATIONS', 'CPA, CFA, ICD.D' }});

        // 7 - a bilingual Chief Human Resources Officer, no job here asks for HR (shows the filters shrinking the list); two degrees, no certifications
        people.add(new Map<String, Object>{ 'first' => 'Sophie', 'last' => 'Tremblay', 'city' => 'Ottawa', 'modes' => 'Hybrid',
            'salary' => 255000, 'roles' => 'HR Executive', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Bilingual (English and French) chief human resources officer with 17 years of experience in talent strategy, organizational design and labour relations.',
            '', 'SKILLS',
            'Talent strategy, Organizational development, Employee relations, Succession planning, Executive compensation, Labour relations, Change management, Workforce planning, Diversity and inclusion, English (fluent), French (fluent)',
            '', 'EXPERIENCE',
            'Chief Human Resources Officer - Evergreen Health Partners, Ottawa, ON', 'Jan 2022 - Present',
            '- Leads HR, learning and total rewards for 7,500 employees in Ontario and Quebec.',
            '- Lowered voluntary turnover from 18 to 11 percent in two years.',
            'Vice President, People - Silverline Communications, Ottawa, ON', 'Jan 2017 - Dec 2021',
            '- Built the succession plan for the top 60 leaders and redesigned executive compensation.',
            '- Led a 1,200 person reorganization after a merger and kept regretted attrition under 5 percent.',
            'Director of Human Resources - Rideau Holdings, Ottawa, ON', 'Jul 2009 - Dec 2016',
            '- Negotiated three collective agreements without a work stoppage.',
            '', 'EDUCATION', 'MBA - Carleton University, 2015 - 2017', 'B.A. Economics - University of Ottawa, 2005 - 2009' }});

        // 8 - a Director of Technology, a near miss for the senior jobs (not yet a vice president, 10 years)
        people.add(new Map<String, Object>{ 'first' => 'Kevin', 'last' => 'Santos', 'city' => 'Toronto', 'modes' => 'Hybrid',
            'salary' => 185000, 'roles' => 'Technology Executive', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Director of technology with 10 years of experience leading software and infrastructure teams. Looking for a step up to vice president.',
            '', 'SKILLS',
            'Engineering leadership, Technology strategy, Cloud strategy, Agile at scale, Budgeting and forecasting, Vendor management, Talent development',
            '', 'EXPERIENCE',
            'Director of Technology - Skyline Digital, Toronto, ON', 'Sep 2022 - Present',
            '- Leads 35 engineers and a $9 million budget for the customer platform.',
            '- Moved the main product to a cloud-native design and cut hosting cost by 25 percent.',
            'Senior Manager, Engineering - Skyline Digital, Toronto, ON', 'Jan 2020 - Aug 2022',
            '- Grew two teams from 8 to 22 engineers and set up code review and release standards.',
            'Engineering Manager - Harbourfront Systems, Toronto, ON', 'Jul 2016 - Dec 2019',
            '- Managed a team of 8 engineers delivering internal tools.',
            '', 'EDUCATION', 'B.Sc. Computer Science - Toronto Metropolitan University, 2012 - 2016',
            '', 'CERTIFICATIONS', 'Certified ScrumMaster' }});

        // 9 - a remote Chief Revenue Officer, a strong fit for the Chief Revenue Officer job
        people.add(new Map<String, Object>{ 'first' => 'Jessica', 'last' => 'Li', 'city' => 'Markham', 'modes' => 'Remote',
            'salary' => 320000, 'roles' => 'Revenue Executive', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Chief revenue officer with 19 years of experience growing enterprise software revenue through sales, partnerships and customer success.',
            '', 'SKILLS',
            'Revenue growth strategy, Go-to-market strategy, Sales leadership, Enterprise sales, Pipeline forecasting, Channel partnerships, Customer success, Pricing strategy, CRM platform strategy, Sales operations',
            '', 'EXPERIENCE',
            'Chief Revenue Officer - Great Lakes Analytics, Markham, ON', 'Jun 2021 - Present',
            '- Grew revenue from $40 million to $110 million in five years and tripled the enterprise customer base.',
            '- Rebuilt the go-to-market model and the CRM forecast so that forecast error fell below 5 percent.',
            '- Leads 180 people across sales, partnerships and customer success.',
            'Vice President, Sales - Pinnacle Software, Mississauga, ON', 'Jan 2015 - May 2021',
            '- Led a 60 person enterprise sales team and beat quota six years in a row.',
            '- Launched a channel partner program with 25 partners that brought in 30 percent of new revenue.',
            'Director of Sales - Maple Software, Toronto, ON', 'Jul 2010 - Dec 2014',
            '- Built the mid-market sales team from 6 to 24 sellers.',
            'Account Executive - Harbourfront Systems, Toronto, ON', 'Jul 2007 - Jun 2010',
            '- Closed the largest new enterprise accounts three years in a row.',
            '', 'EDUCATION', 'MBA - York University, 2012 - 2014', 'B.Comm. - McMaster University, 2003 - 2007' }});

        // This candidate has NO resume, so every filter excludes them ("must have a resume").
        people.add(new Map<String, Object>{ 'first' => 'Nathan', 'last' => 'Roy', 'city' => 'Edmonton', 'modes' => 'Hybrid',
            'salary' => 300000, 'roles' => 'Operations Executive', 'resume' => false, 'lines' => new List<String>() });

        // 11 - a Vice President of Sales and Customer Success, a partial fit for the Chief Revenue Officer job (not C-level)
        people.add(new Map<String, Object>{ 'first' => 'Olivia', 'last' => 'Thompson', 'city' => 'Toronto', 'modes' => 'Hybrid',
            'salary' => 295000, 'roles' => 'Revenue Executive', 'resume' => true, 'lines' => new List<String>{
            'SUMMARY',
            'Vice president of sales and customer success with 15 years of experience in enterprise sales leadership and customer retention for software companies.',
            '', 'SKILLS',
            'Sales leadership, Enterprise sales, Customer success, Revenue growth strategy, Pipeline forecasting, CRM platform strategy, Account-based marketing, Sales operations, Pricing strategy',
            '', 'EXPERIENCE',
            'Vice President, Sales and Customer Success - Northern Lights Digital, Toronto, ON', 'Apr 2019 - Present',
            '- Leads 90 people and a $75 million new and renewal revenue target.',
            '- Raised net revenue retention from 98 to 112 percent.',
            'Director of Enterprise Sales - Kingsway Software, Mississauga, ON', 'Jun 2014 - Mar 2019',
            '- Built the enterprise team from 5 to 30 sellers and doubled the average deal size.',
            'Senior Account Manager - Evergreen Tech, Toronto, ON', 'Jul 2011 - May 2014',
            '- Managed 40 enterprise accounts worth $14 million a year.',
            '', 'EDUCATION', 'B.Comm. - Western University, 2007 - 2011' }});

        return people;
    }

    // =====================================================================================
    //  RESUME PDFs (designed layout)
    // =====================================================================================

    /** Builds and saves one designed PDF resume for each of these (already saved) contacts. Returns the number of PDFs created. */
    private static Integer attachResumes(List<Contact> contacts, List<List<String>> resumeLines) {
        return attachFiles(contacts, buildResumeFiles(contacts, resumeLines, false));
    }

    /**
     * Builds one designed PDF per contact (the expensive part: about 0.1 second of CPU each). With stopBeforeCpuLimit it stops, in good
     * time before the CPU limit, at the last resume it has time for and returns fewer files than contacts: file i belongs to contact i.
     * The contacts do not need to be saved yet.
     */
    private static List<ContentVersion> buildResumeFiles(List<Contact> contacts, List<List<String>> resumeLines, Boolean stopBeforeCpuLimit) {
        List<ContentVersion> files = new List<ContentVersion>();
        Integer budget = Limits.getLimitCpuTime() * 6 / 10;        // the rest is for saving the contacts, the files and their links
        for (Integer i = 0; i < contacts.size(); i++) {
            if (stopBeforeCpuLimit && i > 0 && Limits.getCpuTime() > budget) { break; }
            Contact c = contacts[i];
            String baseName = c.FirstName + '_' + c.LastName + '_Resume';
            files.add(new ContentVersion(Title = baseName, PathOnClient = baseName + '.pdf',
                VersionData = buildPdf(parseResume(c, resumeLines[i]))));
        }
        return files;
    }

    /**
     * Saves the PDFs and links every file to its (already saved) contact in ONE insert; file i belongs to contact i.
     * (Attaching with FirstPublishLocationId fires the ContentDocumentLink trigger once per file and runs out of SOQL
     * queries after about 45 files; one bulk insert fires it once.) Returns the number of PDFs created.
     */
    private static Integer attachFiles(List<Contact> contacts, List<ContentVersion> files) {
        if (files.isEmpty()) { return 0; }
        insert files;

        Map<Id, Id> docByVersion = new Map<Id, Id>();
        for (ContentVersion v : [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id IN :files]) { docByVersion.put(v.Id, v.ContentDocumentId); }
        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        for (Integer i = 0; i < files.size(); i++) {
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
                    List<String> loc = employerAndCity(d > 0 ? ln.substring(d + 3) : '');
                    job = new ResumeJob(d > 0 ? ln.substring(0, d) : ln, null, loc[0], loc[1], new List<String>());
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
        String city = String.isBlank(c.City__c) ? '' : place(c.City__c) + '   |   ';
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

        /** Width of the text in 1/1000 em, a whole number (every character has a whole width in the tables above). */
        Integer rawWidth(String s, Boolean isBold) {
            List<Integer> t = isBold ? BOLD : HELV;
            Integer total = 0;
            for (Integer i = 0; i < s.length(); i++) {
                Integer o = s.charAt(i);
                total += (o >= 32 && o <= 126) ? t[o - 32] : 556;
            }
            return total;
        }

        Decimal textWidth(String s, Boolean isBold, Decimal size) {
            return Decimal.valueOf(rawWidth(s, isBold)) * size / 1000;
        }

        /**
         * Greedy word wrap. Every word is measured once and the width of the line is kept as words are added; measuring the whole line
         * again for each word made the CPU time of a resume grow with the square of the length of each paragraph.
         */
        List<String> wrap(String s, Boolean isBold, Decimal size, Decimal maxWidth) {
            List<String> out = new List<String>();
            String line = '';
            Integer lineWidth = 0;
            Integer spaceWidth = rawWidth(' ', isBold);
            Decimal widest = maxWidth * 1000;
            for (String word : ascii(s).split(' ')) {
                if (word == '') { continue; }
                Integer w = rawWidth(word, isBold);
                if (line == '') { line = word; lineWidth = w; }
                else if ((lineWidth + spaceWidth + w) * size <= widest) { line += ' ' + word; lineWidth += spaceWidth + w; }
                else { out.add(line); line = word; lineWidth = w; }
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
    //  BULK ADD:  DemoDataLoader.addBulk(100);   (up to 25 right away, more in the background; or DemoDataLoader.addBulkAsync(500))
    //  Adds N more executive candidates (default 25): directors, vice presidents and C-level leaders from nine
    //  functions, with varied seniority, cities, work modes, salary and skills, each with a designed PDF resume attached.
    //  Existing data is not touched. Resume status is left empty so ResumeParseScheduler.runNow() will parse them.
    // =====================================================================================
    private class Archetype {
        String role;                  // the Role Types value of this function
        String alsoRole;              // a second role type that some people of this function also have (or null)
        List<String> titles;          // five career steps: manager, senior manager, director, vice president, C-level
        List<String> core;            // every candidate of this function has these skills
        List<String> optional;        // a rotating subset of these is added (so some people lack some skills on purpose)
        List<String> bullets;         // exactly 8: a resume has up to 4 jobs x 2 bullets, so no achievement repeats on one resume
        List<String> degrees;
        List<String> certs;
        Integer salary;               // base yearly salary (Canadian dollars) for a vice president

        Archetype(String role, String alsoRole, List<String> titles, List<String> core, List<String> optional, List<String> bullets,
                  List<String> degrees, List<String> certs, Integer salary) {
            this.role = role; this.alsoRole = alsoRole;
            this.titles = titles; this.core = core; this.optional = optional; this.bullets = bullets;
            this.degrees = degrees; this.certs = certs; this.salary = salary;
        }
    }

    private static List<Archetype> archetypes() {
        List<String> techDegrees = new List<String>{ 'B.Sc. Computer Science', 'B.Eng. Software Engineering', 'B.Eng. Computer Engineering',
            'B.Sc. Information Technology', 'M.Sc. Computer Science', 'MBA' };
        List<String> bizDegrees = new List<String>{ 'B.Comm.', 'BBA', 'B.A. Economics', 'MBA', 'B.Comm. Accounting' };
        List<Archetype> a = new List<Archetype>();
        // 0 Technology: Chief Technology Officer
        a.add(new Archetype('Technology Executive', 'IT Executive',
            new List<String>{ 'Engineering Manager', 'Senior Manager, Engineering', 'Director of Engineering', 'Vice President, Engineering', 'Chief Technology Officer' },
            new List<String>{ 'Technology strategy', 'Enterprise architecture', 'Digital transformation' },
            new List<String>{ 'Cloud strategy', 'Engineering leadership', 'Board reporting', 'M&A technology integration', 'Vendor management', 'AI strategy', 'Budgeting and forecasting', 'Talent development', 'Agile at scale' },
            new List<String>{ 'Owned the technology roadmap and aligned it with the business strategy.', 'Led a multi-year cloud migration that lowered infrastructure cost and improved reliability.', 'Built and led engineering teams of more than 100 people across several locations.', 'Set architecture standards and cut the number of core platforms from twelve to five.', 'Delivered a large digital transformation program on time and within budget.', 'Presented technology investments and cyber risk to the executive team and the board.', 'Integrated the technology of two acquired companies within a year.', 'Negotiated strategic vendor contracts and lowered technology spend every year.' },
            techDegrees, new List<String>{ 'ICD.D', 'TOGAF Certified', 'AWS Certified Solutions Architect' }, 270000));
        // 1 IT: Chief Information Officer
        a.add(new Archetype('IT Executive', 'Technology Executive',
            new List<String>{ 'IT Manager', 'Senior Manager, IT', 'Director of IT', 'Vice President, IT', 'Chief Information Officer' },
            new List<String>{ 'IT strategy', 'IT governance', 'Digital transformation' },
            new List<String>{ 'Enterprise architecture', 'ERP implementation', 'CRM platform strategy', 'Vendor management', 'Cloud strategy', 'Cybersecurity oversight', 'Budgeting and forecasting', 'Change management', 'Business partnering' },
            new List<String>{ 'Set the IT strategy with the executive team and tied every project to a business outcome.', 'Replaced the ERP and CRM platforms with no disruption to customers.', 'Introduced IT governance and a project portfolio office that improved on-time delivery.', 'Consolidated vendors and contracts to lower IT spend while improving service levels.', 'Led the move of core applications and data to the cloud.', 'Strengthened cyber security controls and passed every external audit.', 'Raised user satisfaction with IT services through a new service desk model.', 'Managed an IT budget of tens of millions of dollars and a team of several hundred people.' },
            techDegrees, new List<String>{ 'ITIL 4 Foundation', 'TOGAF Certified', 'ICD.D' }, 250000));
        // 2 Finance: Chief Financial Officer
        a.add(new Archetype('Finance Executive', null,
            new List<String>{ 'Finance Manager', 'Senior Manager, Finance', 'Director of Finance', 'Vice President, Finance', 'Chief Financial Officer' },
            new List<String>{ 'Financial strategy', 'Financial reporting', 'Budgeting and forecasting' },
            new List<String>{ 'Capital markets', 'M&A and due diligence', 'Treasury', 'Investor relations', 'Audit and controls', 'IFRS', 'Tax strategy', 'Board reporting', 'ERP implementation' },
            new List<String>{ 'Led the yearly budget and the long-range plan and tracked results against targets every month.', 'Raised debt and equity financing on favourable terms.', 'Led due diligence and the integration of acquisitions.', 'Strengthened internal controls and delivered clean external audits.', 'Introduced a new reporting model that gave leaders results in days instead of weeks.', 'Managed the relationship with lenders, investors and rating agencies.', 'Led a finance transformation that automated routine reporting and shortened the monthly close.', 'Presented financial results and risks to the audit committee and the board.' },
            bizDegrees, new List<String>{ 'CPA', 'CFA', 'ICD.D' }, 280000));
        // 3 Operations: Chief Operating Officer
        a.add(new Archetype('Operations Executive', null,
            new List<String>{ 'Operations Manager', 'Senior Manager, Operations', 'Director of Operations', 'Vice President, Operations', 'Chief Operating Officer' },
            new List<String>{ 'Operations strategy', 'P&L management', 'Process improvement' },
            new List<String>{ 'Supply chain management', 'Lean Six Sigma', 'Change management', 'Vendor management', 'Cost optimization', 'Organizational design', 'Customer experience', 'Health and safety' },
            new List<String>{ 'Ran day-to-day operations across several sites with full P&L responsibility.', 'Cut the cost per unit through Lean programs and supplier consolidation.', 'Improved on-time delivery and customer satisfaction at the same time.', 'Redesigned the operating model and clarified roles across the organization.', 'Led the safe start-up of a new facility on schedule.', 'Built a continuous improvement program owned by front-line managers.', 'Renegotiated key supplier contracts and strengthened supply chain resilience.', 'Developed the next layer of operations leaders and a clear succession plan.' },
            new List<String>{ 'B.A.Sc. Industrial Engineering', 'B.Eng. Mechanical Engineering', 'B.Comm.', 'MBA', 'BBA' },
            new List<String>{ 'Lean Six Sigma Black Belt', 'PMP', 'ICD.D' }, 270000));
        // 4 Revenue: Chief Revenue Officer
        a.add(new Archetype('Revenue Executive', null,
            new List<String>{ 'Sales Manager', 'Senior Manager, Sales', 'Director of Sales', 'Vice President, Sales', 'Chief Revenue Officer' },
            new List<String>{ 'Revenue growth strategy', 'Go-to-market strategy', 'Sales leadership' },
            new List<String>{ 'Enterprise sales', 'Pipeline forecasting', 'Channel partnerships', 'Customer success', 'Pricing strategy', 'CRM platform strategy', 'Sales operations', 'Account-based marketing' },
            new List<String>{ 'Grew annual revenue every year and beat the sales target for several years in a row.', 'Rebuilt the go-to-market model and entered two new regions.', 'Led a sales organization of more than 100 people across several teams.', 'Improved forecast accuracy by tightening the pipeline process and the CRM data.', 'Launched a channel partner program that became a major source of new revenue.', 'Raised net revenue retention by joining sales and customer success.', 'Introduced a new pricing and packaging model that lifted the average deal size.', 'Hired and developed sales leaders and cut regretted turnover.' },
            bizDegrees, new List<String>(), 260000));
        // 5 Security: Chief Information Security Officer
        a.add(new Archetype('Security Executive', 'IT Executive',
            new List<String>{ 'Security Manager', 'Senior Manager, Security', 'Director of Information Security', 'Vice President, Security', 'Chief Information Security Officer' },
            new List<String>{ 'Cybersecurity strategy', 'Security governance', 'Risk management' },
            new List<String>{ 'Incident response', 'Regulatory compliance', 'Identity and access management', 'Zero trust architecture', 'Privacy compliance', 'Vendor risk management', 'Security audits', 'Board reporting' },
            new List<String>{ 'Built the enterprise security strategy and a multi-year program to deliver it.', 'Cut critical security incidents through better detection and faster response.', 'Introduced zero trust access for employees, partners and cloud workloads.', 'Passed regulator and external audits without major findings.', 'Reported cyber risk to the audit committee and the board each quarter.', 'Set up a security operations centre that runs around the clock.', 'Reduced third-party risk by assessing and tiering every key vendor.', 'Ran executive crisis exercises and strengthened the incident playbooks.' },
            techDegrees, new List<String>{ 'CISSP', 'CISM', 'CISA' }, 240000));
        // 6 Data: Chief Data Officer
        a.add(new Archetype('Data Executive', 'Technology Executive',
            new List<String>{ 'Analytics Manager', 'Senior Manager, Data', 'Director of Data and Analytics', 'Vice President, Data and Analytics', 'Chief Data Officer' },
            new List<String>{ 'Data strategy', 'Data governance', 'Advanced analytics' },
            new List<String>{ 'AI strategy', 'Machine learning oversight', 'Data platform architecture', 'Master data management', 'Data privacy', 'Analytics operating model', 'Self-service BI', 'Data monetization' },
            new List<String>{ 'Built the enterprise data office and a team of data and AI specialists.', 'Set up data governance and clear data ownership across business units.', 'Launched machine learning models that delivered measurable savings.', 'Moved analytics to a modern cloud data platform used by thousands of employees.', 'Led data privacy compliance across Canadian regulations.', 'Created a self-service analytics program that cut report requests to IT.', 'Defined the AI strategy and the rules for responsible use of AI.', 'Reported the value of data programs to the executive team each quarter.' },
            new List<String>{ 'M.Sc. Statistics', 'B.Sc. Mathematics', 'B.Sc. Computer Science', 'MBA', 'M.Sc. Computer Science' },
            new List<String>{ 'DAMA CDMP', 'ICD.D' }, 245000));
        // 7 People: Chief Human Resources Officer
        a.add(new Archetype('HR Executive', null,
            new List<String>{ 'HR Manager', 'Senior Manager, HR', 'Director of Human Resources', 'Vice President, People', 'Chief Human Resources Officer' },
            new List<String>{ 'Talent strategy', 'Organizational development', 'Employee relations' },
            new List<String>{ 'Succession planning', 'Executive compensation', 'Labour relations', 'Change management', 'Workforce planning', 'Diversity and inclusion', 'Total rewards', 'HR analytics' },
            new List<String>{ 'Built the talent strategy and tied it to the business plan.', 'Lowered voluntary turnover through better career paths and manager training.', 'Designed the succession plan for the top leadership roles.', 'Redesigned executive compensation and the total rewards program.', 'Led the people side of a merger and kept key talent.', 'Negotiated collective agreements without a work stoppage.', 'Introduced workforce planning and people analytics for the executive team.', 'Raised employee engagement scores year over year.' },
            new List<String>{ 'B.A. Psychology', 'B.Comm.', 'MBA', 'B.A. Economics', 'BBA' },
            new List<String>{ 'CPHR', 'SHRM-SCP', 'ICD.D' }, 235000));
        // 8 Product: Chief Product Officer
        a.add(new Archetype('Product Executive', 'Technology Executive',
            new List<String>{ 'Product Manager', 'Senior Product Manager', 'Director of Product', 'Vice President, Product', 'Chief Product Officer' },
            new List<String>{ 'Product strategy', 'Roadmapping', 'P&L management' },
            new List<String>{ 'Portfolio management', 'Customer research', 'Pricing strategy', 'Go-to-market strategy', 'A/B testing', 'Stakeholder management', 'Agile at scale', 'Talent development' },
            new List<String>{ 'Owned the product strategy and the roadmap for a portfolio of products.', 'Grew revenue from new products and retired products that did not perform.', 'Built and led a product organization of managers, designers and analysts.', 'Used customer research and data to decide what to build next.', 'Launched a new product line in two new markets.', 'Aligned product, engineering and sales on one yearly plan.', 'Introduced a product operating model with clear goals for every team.', 'Reported product results and risks to the executive team and the board.' },
            techDegrees, new List<String>{ 'Pragmatic Product Management' }, 255000));
        return a;
    }

    /**
     * How many candidates one transaction adds. Every candidate gets a designed PDF built in Apex, about 0.1 second of CPU each, and a
     * call has 10 seconds of CPU (60 in the background), so a call that asks for more is handed to the background job instead.
     */
    public static final Integer CHUNK_SIZE = 25;
    /** Days from today until a candidate is available, spread so every window of the matcher screen (now, 14, 31, 62 days) has candidates. */
    private static final List<Integer> AVAILABLE_IN_DAYS = new List<Integer>{ 0, 7, 14, 21, 31, 45, 62, 90 };
    /** The most addBulkAsync adds in one call (a guard against a mistyped number). */
    private static final Integer MAX_ASYNC_TOTAL = 5000;

    /**
     * Adds any number of candidates (up to 5,000 per call) in the background: a batch job (DemoDataBulkBatch) adds 25 candidates at a
     * time, each time in its own transaction. Returns the batch job id; watch it in Setup > Apex Jobs.
     */
    public static Id addBulkAsync(Integer total) {
        Integer n = (total == null || total < 1) ? CHUNK_SIZE : Math.min(total, MAX_ASYNC_TOTAL);
        DemoDataBulkBatch job = new DemoDataBulkBatch(n, CHUNK_SIZE);
        // One chunk per batch run. (A test may only start a batch whose chunks all fit in one run, so tests use one run for all of them.)
        return Database.executeBatch(job, Test.isRunningTest() ? Math.max(1, job.runs()) : 1);
    }

    /** Adds n candidates: up to 25 right away, more than that in the background (see addBulkAsync). */
    public static void addBulk(Integer count) {
        Integer n = (count == null || count < 1) ? CHUNK_SIZE : count;
        if (n > CHUNK_SIZE) {
            Id jobId = addBulkAsync(n);
            System.debug('BULK DEMO DATA: ' + Math.min(n, MAX_ASYNC_TOTAL) + ' candidates are being added in the background, ' + CHUNK_SIZE
                + ' at a time (batch job ' + jobId + '). Watch it in Setup > Apex Jobs.');
            return;
        }
        addNow(n);
    }

    /** Adds up to 25 candidates in THIS transaction (the batch job calls it for every chunk). Returns how many were added. */
    public static Integer addNow(Integer n) {
        return addCandidates(n, null);
    }

    /** What one job-matching candidate is made to be (see addMatchingCandidates). */
    private class Plan {
        Integer arch; Integer years; String city; String modes; Integer salary; List<String> extras; Boolean bilingual;
        Plan(Integer arch, Integer years, String city, String modes, Integer salary, List<String> extras, Boolean bilingual) {
            this.arch = arch; this.years = years; this.city = city; this.modes = modes; this.salary = salary;
            this.extras = extras; this.bilingual = bilingual;
        }
    }

    /** Per demo job: its function (an index into archetypes()), the skills besides the three core ones that its description lists, and whether it asks for English and French. */
    private class JobKind {
        Integer arch; List<String> extras; Boolean bilingual;
        JobKind(Integer arch, List<String> extras, Boolean bilingual) { this.arch = arch; this.extras = extras; this.bilingual = bilingual; }
    }

    private static Map<String, JobKind> jobKinds() {
        return new Map<String, JobKind>{
            'DEMO - Chief Technology Officer' => new JobKind(0, new List<String>{ 'Cloud strategy', 'Engineering leadership' }, false),
            'DEMO - Chief Financial Officer' => new JobKind(2, new List<String>{ 'Capital markets', 'M&A and due diligence' }, false),
            'DEMO - Chief Information Security Officer' => new JobKind(5, new List<String>{ 'Incident response', 'Regulatory compliance' }, false),
            'DEMO - Chief Revenue Officer' => new JobKind(4, new List<String>{ 'Enterprise sales', 'Pipeline forecasting' }, false),
            'DEMO - Vice President of Operations' => new JobKind(3, new List<String>{ 'Supply chain management', 'Change management' }, false),
            'DEMO - Chief Data Officer' => new JobKind(6, new List<String>{ 'AI strategy', 'Data privacy' }, true) };
    }

    /**
     * Adds candidates made to FIT each demo job (default 4 per job, at most 4 so that one call stays within its CPU limit). Each lives in the
     * job's city (a major city for a remote job), takes the job's work mode, asks for no more than the job pays, has more years of experience
     * than the job's minimum, has the job's role type, and lists every skill the job asks for (and English and French for the Chief Data
     * Officer). The random bulk candidates fit some of a job's filters but seldom all of them, so a narrow job (one city, one role) would
     * otherwise have only one or two candidates. Run it after run() or addExtraJobs(), then parse the new resumes. Returns how many were added.
     */
    public static Integer addMatchingCandidates(Integer perJob) {
        Integer howMany = (perJob == null || perJob < 1) ? 4 : Math.min(perJob, 4);
        Map<String, JobKind> kinds = jobKinds();
        List<String> remoteCities = new List<String>{ 'Toronto', 'Vancouver', 'Calgary', 'Ottawa' };
        List<Plan> plans = new List<Plan>();
        for (Job__c j : [SELECT Name, City__c, Work_Modes__c, Expected_Salary__c, Min_Experience_Years__c
                         FROM Job__c WHERE Name LIKE 'DEMO - %' ORDER BY Name]) {
            JobKind kind = kinds.get(j.Name);
            if (kind == null) { continue; }
            String mode = String.isBlank(j.Work_Modes__c) ? 'Hybrid' : j.Work_Modes__c.split(';')[0];
            Integer minYears = j.Min_Experience_Years__c == null ? 12 : j.Min_Experience_Years__c.intValue();
            Integer pay = j.Expected_Salary__c == null ? 250000 : j.Expected_Salary__c.intValue();
            for (Integer k = 0; k < howMany; k++) {
                String city = String.isBlank(j.City__c) ? remoteCities[Math.mod(k, remoteCities.size())] : j.City__c;
                String modes = Math.mod(k, 2) == 0 ? mode : mode + ';' + (mode == 'Hybrid' ? 'Remote' : 'Hybrid');
                plans.add(new Plan(kind.arch, minYears + 1 + Math.mod(k * 3, 7), city, modes, pay - 5000 * Math.mod(k, 4), kind.extras, kind.bilingual));
            }
        }
        return plans.isEmpty() ? 0 : addCandidates(plans.size(), plans);
    }

    /** Builds n candidates with a designed PDF resume each: random ones (plans = null) or made to fit the demo jobs (one plan per candidate). */
    private static Integer addCandidates(Integer n, List<Plan> plans) {
        Integer startIdx = [SELECT COUNT() FROM Contact WHERE Email LIKE 'bulk.%@demo-candidates.example'];

        List<Archetype> arcs = archetypes();
        // the demo jobs are CTO, CFO, CISO, CRO, VP Operations and CDO, so those functions come up more often than the others
        List<Integer> mix = new List<Integer>{ 0, 0, 1, 2, 2, 3, 3, 4, 5, 6, 7, 8 };
        List<String> firsts = new List<String>{ 'Liam', 'Olivia', 'Noah', 'Emma', 'Ethan', 'Chloe', 'Lucas', 'Sophie', 'Mathieu', 'Isabelle',
            'Jacob', 'Hannah', 'Nathan', 'Camille', 'Simon', 'Amelia', 'Ryan', 'Priya', 'Arjun', 'Harpreet',
            'Gurpreet', 'Aisha', 'Omar', 'Wei', 'Mei', 'Jason', 'Kevin', 'Grace', 'Daniel', 'Sarah',
            'Michael', 'Jessica', 'Andre', 'Maya', 'Tariq', 'Fatima', 'Jin', 'Carlos', 'Elena', 'Marc' };
        List<String> lasts = new List<String>{ 'Tremblay', 'Gagnon', 'Roy', 'Bouchard', 'Gauthier', 'Patel', 'Singh', 'Kaur', 'Chen', 'Wang',
            'Li', 'Nguyen', 'Kim', 'Santos', 'Ahmed', 'Khan', 'Smith', 'Brown', 'Wilson', 'Campbell',
            'Anderson', 'Martin', 'Taylor', 'Gill', 'Sandhu' };
        // 20 entries (not a multiple of 3), so the idx * 3 step below still visits every city. Weighted towards the big hubs.
        List<String> cities = new List<String>{ 'Toronto', 'Toronto', 'Toronto', 'Mississauga', 'Brampton', 'Markham', 'Ottawa', 'Ottawa',
            'Montreal', 'Montreal', 'Quebec City', 'Vancouver', 'Vancouver', 'Burnaby', 'Calgary', 'Calgary', 'Edmonton', 'Waterloo',
            'Halifax', 'Winnipeg' };
        List<String> modeCombos = new List<String>{ 'Hybrid', 'Remote', 'On-site', 'Hybrid;Remote', 'On-site;Hybrid', 'Remote;Hybrid;On-site' };
        List<String> employers = new List<String>{ 'Bayview Financial Group', 'Lakeshore Capital', 'Cascadia Energy', 'Fraser Valley Health Network',
            'Pacific Rim Logistics', 'Bluewater Insurance Group', 'Timberline Resources', 'Laurentian Retail Group', 'Rideau Holdings', 'Altitude Aerospace',
            'Pinnacle Wealth Partners', 'Harbourfront Bank', 'Capital Region Utilities', 'Skyline Telecom', 'Great Lakes Manufacturing', 'Northern Lights Energy',
            'Kingsway Retail Group', 'Prairie Agri Foods', 'Granite Peak Mining', 'Tidewater Shipping', 'Maple Harbour Insurance', 'Redwood Financial',
            'Silverline Communications', 'Evergreen Health Partners' };
        List<String> months = new List<String>{ 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' };
        // 17 universities (not a multiple of 3, see idx * 3 below)
        List<String> universities = new List<String>{ 'University of Toronto', 'University of Waterloo', 'Toronto Metropolitan University',
            'York University', 'McMaster University', 'Carleton University', 'University of Ottawa', 'McGill University', 'Concordia University',
            'University of British Columbia', 'Simon Fraser University', 'University of Calgary', 'University of Alberta', 'Dalhousie University',
            'University of Manitoba', 'Western University', 'University of Victoria' };

        List<Contact> contacts = new List<Contact>();
        List<List<String>> resumes = new List<List<String>>();
        Integer thisYear = Date.today().year();
        for (Integer i = 0; i < n; i++) {
            Integer idx = startIdx + i;
            Plan spec = plans == null ? null : plans[i];
            Archetype arc = arcs[spec != null ? spec.arch : mix[Math.mod(idx, mix.size())]];
            Integer yrs = spec != null ? spec.years : 8 + Math.mod(idx * 5, 19);                           // 8..26 years of experience (19 is prime, so every value comes up)
            Integer level = yrs < 14 ? 0 : (yrs < 20 ? 1 : 2);                 // director / vice president / C-level
            String firstName = firsts[Math.mod(idx, firsts.size())];
            String lastName = lasts[Math.mod(idx * 7 + idx / firsts.size(), lasts.size())];
            String city = spec != null ? spec.city : cities[Math.mod(idx * 3, cities.size())];
            String modes = spec != null ? spec.modes : modeCombos[Math.mod(idx * 5 + 1, modeCombos.size())];
            Integer pick = idx / mix.size() + Math.mod(idx, 2);                // spreads degrees and certifications within one function
            Boolean bilingual = spec != null ? spec.bilingual : (city == 'Montreal' || city == 'Quebec City' || (city == 'Ottawa' && Math.mod(idx, 2) == 0));

            // role types: the function, and for some people a second function they could also lead (technology and IT, for example)
            String roles = arc.role;
            if (arc.alsoRole != null && Math.mod(idx * 7 + pick, 3) == 0) { roles += ';' + arc.alsoRole; }

            Integer mult = level == 0 ? 70 : (level == 1 ? 100 : 140);
            Integer salary = spec != null ? spec.salary : Math.max(100000, (arc.salary * mult / 100 / 2500) * 2500 + (Math.mod(idx * 13, 5) - 2) * 2500);   // Canadian dollars, steps of 2,500

            // skills: all core skills plus a rotating subset of the optional ones (so some people lack some skills on purpose)
            List<String> skills = new List<String>(arc.core);
            if (spec != null) { skills.addAll(spec.extras); }                    // a job-matching candidate has every skill the job asks for
            Integer extra = spec != null ? 2 : Math.min(arc.optional.size(), 3 + level + Math.mod(idx, 3));
            Integer offset = Math.mod(idx * 5, arc.optional.size());
            for (Integer k = 0; k < extra; k++) {
                String more = arc.optional[Math.mod(offset + k, arc.optional.size())];
                if (!skills.contains(more)) { skills.add(more); }
            }
            if (bilingual) { skills.add('English (fluent)'); skills.add('French (fluent)'); }

            // resume text: the current role, then one earlier role per step down the ladder (three earlier roles after 18 years)
            List<String> lines = new List<String>();
            String title = arc.titles[level + 2];
            lines.add('SUMMARY');
            lines.add(title + ' with ' + yrs + ' years of experience in ' + skills[0] + ', ' + skills[1] + ' and ' + skills[2] + '. Based in ' + place(city) + '.'
                + (bilingual ? ' Bilingual (English and French).' : ''));
            lines.add('');
            lines.add('SKILLS');
            lines.add(String.join(skills, ', '));
            lines.add('');
            lines.add('EXPERIENCE');
            Integer curYears = Math.min(6, Math.max(2, yrs / 4));
            Integer curStart = thisYear - curYears;
            addJob(lines, title, employers[Math.mod(idx, employers.size())], city,
                months[Math.mod(idx, 12)] + ' ' + curStart, 'Present', arc.bullets, idx, 2);
            Integer remaining = yrs - curYears;
            Integer earlier = yrs >= 18 ? 3 : 2;
            Integer step = remaining / earlier;
            Integer endYear = curStart - 1;
            for (Integer j = 0; j < earlier; j++) {
                Boolean oldest = j == earlier - 1;
                Integer startYear = oldest ? thisYear - yrs : endYear - step + 1;
                addJob(lines, arc.titles[Math.max(0, level + 1 - j)], employers[Math.mod(idx + 5 * (j + 1), employers.size())],
                    cities[Math.mod(idx + 2 * (j + 1), cities.size())], (oldest ? 'Jul ' : 'Jan ') + startYear, 'Dec ' + endYear,
                    arc.bullets, idx + 2 * (j + 1), 2);
                endYear = startYear - 1;
            }

            // education: a first degree (a graduate degree stands alone) and, for most, an MBA taken a few years into the career
            Integer gradEnd = thisYear - yrs;
            String degree = arc.degrees[Math.mod(pick, arc.degrees.size())];
            Boolean graduate = degree.startsWith('MBA') || degree.startsWith('M.Sc');
            lines.add('');
            lines.add('EDUCATION');
            if (!graduate && Math.mod(idx, 3) != 0) {
                Integer mbaEnd = gradEnd + 5 + Math.mod(idx, 3);
                lines.add('MBA - ' + universities[Math.mod(idx * 3 + 1, universities.size())] + ', ' + (mbaEnd - 2) + ' - ' + mbaEnd);
            }
            lines.add(degree + ' - ' + universities[Math.mod(idx * 3, universities.size())] + ', ' + (gradEnd - (graduate ? 2 : 4)) + ' - ' + gradEnd);
            if (!arc.certs.isEmpty() && (spec != null || Math.mod(idx, 4) != 0)) {
                lines.add('');
                lines.add('CERTIFICATIONS');
                String certs = spec != null ? String.join(arc.certs, ', ') : arc.certs[Math.mod(pick, arc.certs.size())];
                if (spec == null && arc.certs.size() > 1 && Math.mod(idx, 3) == 0) { certs += ', ' + arc.certs[Math.mod(pick + 1, arc.certs.size())]; }
                lines.add(certs);
            }

            contacts.add(new Contact(
                FirstName = firstName, LastName = lastName,
                Email = 'bulk.' + firstName.toLowerCase() + '.' + lastName.toLowerCase() + '.' + (idx + 1) + '@demo-candidates.example',
                City__c = city, Work_Modes__c = modes, Expected_Salary__c = salary,
                Date_Available__c = Date.today().addDays(AVAILABLE_IN_DAYS[Math.mod(idx * 7, AVAILABLE_IN_DAYS.size())]),
                Role_Types__c = knownRoles(false, roles), Has_Resume__c = true));
            resumes.add(lines);
        }

        // The PDFs are the expensive part. Build them BEFORE saving anything and stop in good time before the CPU limit (a call that runs
        // out of CPU saves nothing at all), then save only the candidates whose resume is ready.
        List<ContentVersion> files = buildResumeFiles(contacts, resumes, true);
        Boolean cutShort = files.size() < contacts.size();
        while (contacts.size() > files.size()) { contacts.remove(contacts.size() - 1); }
        insert contacts;
        Integer fileCount = attachFiles(contacts, files);

        System.debug('BULK DEMO DATA ADDED: ' + contacts.size() + ' of ' + n + ' contacts and ' + fileCount + ' PDF resumes (numbers '
            + (startIdx + 1) + ' to ' + (startIdx + contacts.size()) + ').'
            + (cutShort ? ' Stopped early to stay under the CPU limit: run it again for the rest.' : ''));
        System.debug('Total demo contacts with Has_Resume__c = true: '
            + [SELECT COUNT() FROM Contact WHERE Email LIKE '%@demo-candidates.example' AND Has_Resume__c = true]);
        return contacts.size();
    }

    private static void addJob(List<String> lines, String title, String employer, String city, String startText, String endText,
                               List<String> bullets, Integer seed, Integer count) {
        lines.add(title + ' - ' + employer + ', ' + place(city));
        lines.add(startText + ' - ' + endText);
        for (Integer k = 0; k < count; k++) { lines.add('- ' + bullets[Math.mod(seed + k, bullets.size())]); }
    }

    // =====================================================================================
    //  ROLE TYPES  (only values the picklist has are ever set, so the loader never fails on a missing value)
    // =====================================================================================
    private static Set<String> contactRoleValues;
    private static Set<String> jobRoleValues;

    /** The active values of the Role Types picklist on Job (forJob) or on Contact, read once. */
    private static Set<String> roleValues(Boolean forJob) {
        if ((forJob ? jobRoleValues : contactRoleValues) == null) {
            Schema.SObjectField field = forJob ? Job__c.Role_Types__c : Contact.Role_Types__c;
            Set<String> values = new Set<String>();
            for (Schema.PicklistEntry e : field.getDescribe().getPicklistValues()) {
                if (e.isActive()) { values.add(e.getValue()); }
            }
            if (forJob) { jobRoleValues = values; } else { contactRoleValues = values; }
        }
        return forJob ? jobRoleValues : contactRoleValues;
    }

    /** "A;B" without the values the picklist does not have; null when none is left. */
    private static String knownRoles(Boolean forJob, String roles) {
        if (String.isBlank(roles)) { return null; }
        Set<String> valid = roleValues(forJob);
        List<String> keep = new List<String>();
        for (String r : roles.split(';')) { if (valid.contains(r.trim())) { keep.add(r.trim()); } }
        return keep.isEmpty() ? null : String.join(keep, ';');
    }

    private static List<Job__c> withKnownRoles(List<Job__c> jobs) {
        for (Job__c j : jobs) { j.Role_Types__c = knownRoles(true, j.Role_Types__c); }
        return jobs;
    }

    // =====================================================================================
    //  CANADIAN PLACES
    // =====================================================================================
    private static final Map<String, String> PROVINCES = new Map<String, String>{
        'Toronto' => 'ON', 'Mississauga' => 'ON', 'Brampton' => 'ON', 'Markham' => 'ON', 'Ottawa' => 'ON', 'Waterloo' => 'ON',
        'Kitchener' => 'ON', 'Hamilton' => 'ON', 'Montreal' => 'QC', 'Quebec City' => 'QC', 'Gatineau' => 'QC',
        'Vancouver' => 'BC', 'Burnaby' => 'BC', 'Calgary' => 'AB', 'Edmonton' => 'AB', 'Winnipeg' => 'MB', 'Halifax' => 'NS' };

    /** "Toronto" -> "Toronto, ON". A city that is not in the table is returned as it is. */
    private static String place(String city) {
        if (String.isBlank(city)) { return ''; }
        String province = PROVINCES.get(city);
        return province == null ? city : city + ', ' + province;
    }

    /** Splits "Employer, City" or "Employer, City, ON" into [employer, city] (the province stays with the city). */
    private static List<String> employerAndCity(String rest) {
        Integer comma = rest.lastIndexOf(', ');
        if (comma <= 0) { return new List<String>{ rest, '' }; }
        String tail = rest.substring(comma + 2);
        if (tail.length() == 2 && tail.equals(tail.toUpperCase())) {
            Integer before = rest.substring(0, comma).lastIndexOf(', ');
            if (before > 0) { return new List<String>{ rest.substring(0, before), rest.substring(before + 2) }; }
        }
        return new List<String>{ rest.substring(0, comma), tail };
    }
}
