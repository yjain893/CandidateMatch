/** Scoring rules in CandidateMatchService: weights, the skill check, the review flag, and what happens after a resume is parsed. */
@IsTest
private class CandidateMatchServiceTest {

    static CandidateMatchService.ScoreResult result(Integer skills, Integer exp, Integer fit, Integer edu, List<String> matched, String reasoning) {
        CandidateMatchService.ScoreResult r = new CandidateMatchService.ScoreResult();
        r.skillsScore = skills; r.experienceScore = exp; r.fitScore = fit; r.educationScore = edu;
        r.matchedSkills = matched; r.reasoning = reasoning;
        return r;
    }

    static Id jobId() {
        Job__c job = new Job__c(Name = 'Dev', Job_Description__c = 'x');
        insert job;
        return job.Id;
    }

    static Id contactId() {
        Contact c = new Contact(LastName = 'Cand');
        insert c;
        return c.Id;
    }

    @IsTest static void fitCountsOnlyWhenJobSpecifiesIt() {
        CandidateMatchService.ScoreResult r = result(100, 100, 0, 100, new List<String>{ 'Java' }, 'Strong skills');
        r.fitNote = 'Far away';
        Id j = jobId(); Id c = contactId();

        Candidate_Match__c withFit = CandidateMatchService.buildMatch(j, c, r, 'Skills: Java', null, true);
        System.assertEquals(80, withFit.Score__c);               // (4500+2500+0+1000)/100
        System.assert(withFit.Reasoning__c.contains('Far away'));
        Candidate_Match__c noFit = CandidateMatchService.buildMatch(j, c, r, 'Skills: Java', null, false);
        System.assertEquals(100, noFit.Score__c);
        System.assertEquals(null, noFit.Fit_Score__c);
    }

    @IsTest static void halvesRoundUpSoAHigherScoreNeverTiesWithALowerOne() {
        // skills 45%, experience 25%, fit 20%, education 10%. Plain round() is half-even, so 98.5 and 97.5 both used to show 98.
        Map<String, List<Integer>> parts = new Map<String, List<Integer>>{
            'liam'   => new List<Integer>{ 100, 100, 100, 85 },       // 98.5
            'elena'  => new List<Integer>{ 100, 96, 100, 85 },        // 97.5
            'marc'   => new List<Integer>{ 100, 94, 100, 90 },        // 97.5
            'jin'    => new List<Integer>{ 100, 94, 100, 80 },        // 96.5
            'carlos' => new List<Integer>{ 100, 94, 100, 70 } };      // 95.5
        Map<String, Decimal> shown = new Map<String, Decimal>();
        Id j = jobId(); Id c = contactId();
        for (String name : parts.keySet()) {
            List<Integer> p = parts.get(name);
            Candidate_Match__c m = CandidateMatchService.buildMatch(j, c,
                result(p[0], p[1], p[2], p[3], new List<String>{ 'Java' }, 'ok'), 'Skills: Java', null, true);
            shown.put(name, m.Score__c);
        }
        System.assertEquals(99, shown.get('liam'), '98.5 rounds up, not to the even 98');
        System.assertEquals(98, shown.get('elena'));
        System.assertEquals(98, shown.get('marc'));
        System.assertEquals(97, shown.get('jin'), '96.5 rounds up, not to the even 96');
        System.assertEquals(96, shown.get('carlos'));
        System.assert(shown.get('liam') > shown.get('elena'), 'a candidate who really scored higher shows a higher score');
    }

    @IsTest static void componentScoresAreRoundedHalfUpToo() {
        CandidateMatchService.ScoreResult r = new CandidateMatchService.ScoreResult();
        r.skillsScore = 72.5; r.experienceScore = 64.5; r.fitScore = 80.5; r.educationScore = 70.5;
        r.matchedSkills = new List<String>{ 'Java' }; r.reasoning = 'ok';
        Candidate_Match__c m = CandidateMatchService.buildMatch(jobId(), contactId(), r, 'Skills: Java', null, true);
        System.assertEquals(73, m.Skills_Score__c);
        System.assertEquals(65, m.Experience_Score__c);
        System.assertEquals(81, m.Fit_Score__c);
        System.assertEquals(71, m.Education_Score__c);
    }

    @IsTest static void unverifiedHighScoreIsCapped() {
        CandidateMatchService.ScoreResult r = result(95, 95, 95, 95, new List<String>{ 'Kubernetes' }, 'Great');
        Candidate_Match__c m = CandidateMatchService.buildMatch(jobId(), contactId(), r, 'Skills: Java', null, true);
        System.assertEquals(50, m.Score__c);
        System.assertEquals(true, m.Needs_Review__c);
    }

    @IsTest static void oneUnverifiedSkillAmongVerifiedOnesIsRemovedButNotFlagged() {
        CandidateMatchService.ScoreResult r = result(90, 80, 100, 70, new List<String>{ 'Java', 'Kubernetes' }, 'Good fit');
        Candidate_Match__c m = CandidateMatchService.buildMatch(jobId(), contactId(), r, 'Skills: Java', null, true);
        System.assertEquals('Java', m.Matched_Skills__c);         // Kubernetes is not in the profile
        System.assert(m.Reasoning__c.contains('Unverified skills removed: Kubernetes'));
        System.assertEquals(false, m.Needs_Review__c);            // 1 of 2 claims unverified is not enough to flag
        System.assertEquals(88, m.Score__c);                      // (90*45 + 80*25 + 100*20 + 70*10) / 100 = 87.5, rounded
    }

    @IsTest static void rowIsFlaggedWhenMostClaimedSkillsAreUnverified() {
        CandidateMatchService.ScoreResult r = result(60, 60, 60, 60, new List<String>{ 'Java', 'Kubernetes', 'Terraform' }, 'Mixed');
        Candidate_Match__c m = CandidateMatchService.buildMatch(jobId(), contactId(), r, 'Skills: Java', null, true);
        System.assertEquals(true, m.Needs_Review__c);
        System.assertEquals('Java', m.Matched_Skills__c);
    }

    @IsTest static void blankReasoningIsFlagged() {
        CandidateMatchService.ScoreResult r = result(80, 80, 80, 80, new List<String>{ 'Java' }, null);
        Candidate_Match__c m = CandidateMatchService.buildMatch(jobId(), contactId(), r, 'Skills: Java', null, true);
        System.assertEquals(true, m.Needs_Review__c);
    }

    @IsTest static void skillsAreVerifiedByTheResumesOwnWordingIgnoringCaseAndPunctuation() {
        String profile = 'Summary: Dev\nSkills: Apex (7y), REST API Integration, Salesforce DX, Node.js\nEmployment:\nBuilt integrations';
        CandidateMatchService.ScoreResult r = result(80, 80, 80, 80,
            new List<String>{ 'APEX', 'rest api integration', 'Salesforce DX', 'node.js' }, 'ok');
        Candidate_Match__c m = CandidateMatchService.buildMatch(jobId(), contactId(), r, profile, null, true);
        System.assertEquals('APEX, rest api integration, Salesforce DX, node.js', m.Matched_Skills__c);
        System.assert(!m.Reasoning__c.contains('Unverified'));
        System.assertEquals(false, m.Needs_Review__c);
    }

    @IsTest static void aDifferentWordFormIsNotVerifiedButOneMissIsNotEnoughToFlagTheRow() {
        // The rule is "as written in the resume" (the prompt makes the AI copy the resume's wording).
        CandidateMatchService.ScoreResult r = result(80, 80, 80, 80, new List<String>{ 'Data modeling', 'Apex' }, 'ok');
        Candidate_Match__c m = CandidateMatchService.buildMatch(jobId(), contactId(), r, 'Skills: Apex\nBuilt data models', null, true);
        System.assertEquals('Apex', m.Matched_Skills__c);
        System.assert(m.Reasoning__c.contains('[Unverified skills removed: Data modeling]'));
        System.assertEquals(false, m.Needs_Review__c, 'one of two claims failing is not enough to flag the row');
    }

    @IsTest static void aPartialPhraseIsNotVerified() {
        CandidateMatchService.ScoreResult r = result(80, 80, 80, 80, new List<String>{ 'REST API Integration', 'Apex' }, 'ok');
        Candidate_Match__c m = CandidateMatchService.buildMatch(jobId(), contactId(), r, 'Skills: Apex, REST', null, true);
        System.assertEquals('Apex', m.Matched_Skills__c, '"REST" alone is not the claimed phrase');
    }

    @IsTest static void aRepeatedKeyInTheAiAnswerStillScores() {
        // The model sometimes repeats a key. This used to fail the row with "Duplicate field: ...ScoreResult.fitScore".
        Job__c job = new Job__c(Name = 'Dev', Job_Description__c = 'Java', City__c = 'Jaipur');
        insert job;
        Contact c = new Contact(LastName = 'Repeat', City__c = 'Jaipur', Resume_Parse_Status__c = 'Parsed', Candidate_Profile__c = 'Skills: Java');
        insert c;
        insert new Candidate_Match__c(Job__c = job.Id, Contact__c = c.Id, Status__c = 'Queued for scoring', Run_Key__c = 'rk');
        PromptRunner.mockByTemplate = new Map<String, String>{ CandidateMatchService.TEMPLATE =>
            '{"skillsScore":80,"experienceScore":70,"fitScore":90,"fitScore":60,"educationScore":70,'
            + '"matchedSkills":["Java"],"missingSkills":[],"fitNote":"x","reasoning":"Good"}' };

        CandidateMatchService.scoreDirect(job.Id, new List<Id>{ c.Id });

        Candidate_Match__c m = [SELECT Status__c, Fit_Score__c FROM Candidate_Match__c];
        System.assertEquals('Scored', m.Status__c);
        System.assertEquals(60, m.Fit_Score__c, 'the last value of the repeated key wins');
    }

    @IsTest static void aSkillMustMatchWholeWords() {
        CandidateMatchService.ScoreResult r = result(80, 80, 80, 80, new List<String>{ 'Java', 'Apex' }, 'ok');
        Candidate_Match__c m = CandidateMatchService.buildMatch(jobId(), contactId(), r, 'Skills: JavaScript, Apex', null, true);
        System.assertEquals('Apex', m.Matched_Skills__c, 'Java is not found inside JavaScript');
    }

}