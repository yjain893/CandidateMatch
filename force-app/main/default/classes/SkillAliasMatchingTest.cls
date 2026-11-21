/** The job's skill map: saved from the AI's aliases, and used by the candidate matcher's skill filter and counts. */
@IsTest
private class SkillAliasMatchingTest {
    private static final String EXTRACT_JSON = '{"requiredSkills":["REST API","Lightning Web Components"],"niceToHaveSkills":["Platform Developer certification"],'
        + '"skillAliases":{"rest api":["REST API Integration","REST APIs","REST API","  ","RESTful API","rest apis"],'
        + '"Lightning Web Components":["LWC","Lightning Web Component"],'
        + '"Platform Developer certification":["Salesforce Platform Developer I","Salesforce Platform Developer II"]},'
        + '"synonyms":[],"minExperienceYears":3}';

    // ---------------------------------------------------------------------------------------------------- helpers

    static Job__c newJob(String description, String skillMap) {
        Job__c j = new Job__c(Name = 'Dev', Job_Description__c = description, Skill_Map__c = skillMap);
        insert j;
        return j;
    }

    /** A candidate with a parsed resume and the given skills stored the way the parser stores them. */
    static Contact candidate(String lastName, List<String> skillNames) {
        Contact c = new Contact(LastName = lastName, Has_Resume__c = true, Resume_Parse_Status__c = 'Parsed',
                                Candidate_Profile__c = 'Skills: ' + String.join(skillNames, ', '));
        insert c;
        List<Skill__c> rows = new List<Skill__c>();
        for (String n : skillNames) {
            rows.add(new Skill__c(Name = n, Name_Key__c = ResumeParserService.normalizeKey(n), Contact__c = c.Id));
        }
        insert rows;
        return c;
    }

    static CandidateMatchOrchestrator.Filters filters(Id jobId, List<String> selected, List<String> options) {
        CandidateMatchOrchestrator.Filters f = new CandidateMatchOrchestrator.Filters();
        f.jobId = jobId; f.skills = selected; f.skillOptions = options;
        return f;
    }

    static List<String> names(List<Contact> contacts) {
        List<String> out = new List<String>();
        for (Contact c : contacts) { out.add(c.Name); }
        return out;
    }

    static List<String> aliasesOf(Map<String, Object> savedMap, String skill) {
        List<String> out = new List<String>();
        for (Object o : (List<Object>) savedMap.get(skill)) { out.add(String.valueOf(o)); }
        return out;
    }

    static CandidateMatcherV2Controller.SkillCount skillOf(CandidateMatcherV2Controller.MatchCount c, String name) {
        for (CandidateMatcherV2Controller.SkillCount s : c.skills) { if (s.name == name) { return s; } }
        return null;
    }

    // ------------------------------------------------------------------------- the map is saved on the job

    @IsTest static void theMapIsSavedOnTheJobFromTheAliasesTheAiReturned() {
        Job__c job = newJob('Senior developer', null);
        JobRequirementsService.applyText(job.Id, EXTRACT_JSON);

        Map<String, Object> saved = (Map<String, Object>) JSON.deserializeUntyped(
            [SELECT Skill_Map__c FROM Job__c WHERE Id = :job.Id].Skill_Map__c);
        System.assertEquals(3, saved.size(), 'two required skills and one nice-to-have');
        System.assertEquals(new List<String>{ 'REST API Integration', 'REST APIs', 'RESTful API' }, aliasesOf(saved, 'REST API'),
            'the key was matched by normalized name; the skill itself, the blank and the repeat were dropped');
        System.assertEquals(new List<String>{ 'LWC', 'Lightning Web Component' }, aliasesOf(saved, 'Lightning Web Components'));
        System.assertEquals(new List<String>{ 'Salesforce Platform Developer I', 'Salesforce Platform Developer II' },
            aliasesOf(saved, 'Platform Developer certification'));
    }

    @IsTest static void aSkillTheAiGaveNoAliasesForIsStillInTheMap() {
        Job__c job = newJob('Apex developer', null);
        JobRequirementsService.applyText(job.Id, '{"requiredSkills":["Apex"],"niceToHaveSkills":[]}');
        Map<String, Object> saved = (Map<String, Object>) JSON.deserializeUntyped(
            [SELECT Skill_Map__c FROM Job__c WHERE Id = :job.Id].Skill_Map__c);
        System.assertEquals(0, aliasesOf(saved, 'Apex').size());
    }

    @IsTest static void noSkillsMeansNoMap() {
        Job__c job = newJob('Apex developer', null);
        JobRequirementsService.applyText(job.Id, '{"requiredSkills":[],"niceToHaveSkills":[]}');
        System.assertEquals(null, [SELECT Skill_Map__c FROM Job__c WHERE Id = :job.Id].Skill_Map__c);
    }

    @IsTest static void atMostTenAliasesAndNoVeryLongNames() {
        List<String> many = new List<String>{ 'x'.repeat(61) };
        for (Integer i = 0; i < 15; i++) { many.add('Alias ' + i); }
        Job__c job = newJob('Apex developer', null);
        JobRequirementsService.applyText(job.Id,
            '{"requiredSkills":["Apex"],"niceToHaveSkills":[],"skillAliases":{"Apex":' + JSON.serialize(many) + '}}');
        Map<String, Object> saved = (Map<String, Object>) JSON.deserializeUntyped(
            [SELECT Skill_Map__c FROM Job__c WHERE Id = :job.Id].Skill_Map__c);
        List<String> aliases = aliasesOf(saved, 'Apex');
        System.assertEquals(10, aliases.size());
        System.assertEquals('Alias 0', aliases[0], 'the 61-character name was skipped');
    }

    @IsTest static void raisingTheExtractionVersionMakesAnOldHashStale() {
        Job__c job = newJob('Apex developer', null);
        update new Job__c(Id = job.Id, Requirements_Hash__c = JobRequirementsService.hashOf('Apex developer'));   // the hash saved before the version existed
        PromptRunner.mockResponse = EXTRACT_JSON;
        JobRequirementsService.ensureFresh(job.Id);

        Job__c r = [SELECT Job_Description__c, Required_Skills__c, Skill_Map__c, Requirements_Hash__c FROM Job__c WHERE Id = :job.Id];
        System.assertEquals('REST API, Lightning Web Components', r.Required_Skills__c, 'the job was read again');
        System.assertNotEquals(null, r.Skill_Map__c);
        System.assertEquals(JobRequirementsService.contentHash(r.Job_Description__c), r.Requirements_Hash__c);

        PromptRunner.mockError = 'the prompt must not be called again for an unchanged job';
        JobRequirementsService.ensureFresh(job.Id);                       // would throw if it asked the AI again
    }

    // ------------------------------------------------------------------------------- the filter uses the map

    @IsTest static void aCandidateSatisfiesASkillByAnyNameInTheJobsMap() {
        Job__c job = newJob('Developer', '{"REST API":["Web Services","RESTful Web Services"]}');
        candidate('Alpha', new List<String>{ 'Web Services' });
        candidate('Bravo', new List<String>{ 'REST API' });
        candidate('Charlie', new List<String>{ 'GraphQL' });

        System.assertEquals(new List<String>{ 'Alpha', 'Bravo' },
            names(CandidateMatchOrchestrator.findCandidates(filters(job.Id, new List<String>{ 'REST API' }, null), 200)));
        System.assertEquals(new List<String>{ 'Bravo' },
            names(CandidateMatchOrchestrator.findCandidates(filters(null, new List<String>{ 'REST API' }, null), 200)),
            'without a job there is no map, and "Web Services" shares no words with "REST API": only the exact name matches');
    }

    @IsTest static void theAliasesAreComparedByNormalizedName() {
        Job__c job = newJob('Developer', '{"Lightning Web Components":["  LWC  ","Lightning-Web Component"]}');
        candidate('Alpha', new List<String>{ 'lwc' });
        candidate('Bravo', new List<String>{ 'Lightning Web Component' });
        System.assertEquals(new List<String>{ 'Alpha', 'Bravo' },
            names(CandidateMatchOrchestrator.findCandidates(filters(job.Id, new List<String>{ 'lightning web components' }, null), 200)));
    }

    @IsTest static void everyCountOnTheScreenUsesTheMapToo() {
        Job__c job = newJob('Developer', '{"REST API":["REST API Integration","REST APIs"],'
            + '"Platform Developer certification":["Salesforce Platform Developer I","Salesforce Platform Developer II"]}');
        candidate('Pat', new List<String>{ 'REST API Integration', 'Salesforce Platform Developer I' });
        candidate('Quinn', new List<String>{ 'REST APIs', 'Apex' });
        candidate('Robin', new List<String>{ 'REST API' });
        candidate('Sam', new List<String>{ 'Java' });
        List<String> options = new List<String>{ 'REST API', 'Platform Developer certification' };

        CandidateMatcherV2Controller.MatchCount c = CandidateMatcherV2Controller.countMatches(
            JSON.serialize(filters(job.Id, new List<String>{ 'REST API' }, options)));
        System.assertEquals(4, c.pool);
        System.assertEquals(3, c.matched, 'Pat, Quinn and Robin all satisfy REST API, each by a different name');
        System.assertEquals(4, skillOf(c, 'REST API').count, 'a selected skill shows what removing it would give: Sam would join');
        System.assertEquals(1, skillOf(c, 'Platform Developer certification').count, 'only Pat, by "Salesforce Platform Developer I"');

        CandidateMatcherV2Controller.MatchCount without = CandidateMatcherV2Controller.countMatches(
            JSON.serialize(filters(null, new List<String>{ 'REST API' }, options)));
        System.assertEquals(2, without.matched, 'no map: Robin by the name itself and Pat, whose "REST API Integration" contains the words "REST API"');
    }

    @IsTest static void aLongerNameThatContainsAnAliasAsWholeWordsAlsoMatches() {
        Job__c job = newJob('Developer', '{"Platform Developer certification":["Platform Developer I"],"REST API":["REST API Integration"]}');
        candidate('Alpha', new List<String>{ 'Salesforce Platform Developer I' });
        candidate('Bravo', new List<String>{ 'Salesforce Platform Developer II' });                // "II" is another word than "I"
        candidate('Charlie', new List<String>{ 'Salesforce Platform Developer I Certification' });
        candidate('Delta', new List<String>{ 'Platform Developer I' });
        candidate('Echo', new List<String>{ 'Java' });
        List<String> options = new List<String>{ 'Platform Developer certification', 'REST API' };

        System.assertEquals(new List<String>{ 'Alpha', 'Charlie', 'Delta' },
            names(CandidateMatchOrchestrator.findCandidates(
                filters(job.Id, new List<String>{ 'Platform Developer certification' }, null), 200)));

        CandidateMatcherV2Controller.MatchCount c = CandidateMatcherV2Controller.countMatches(
            JSON.serialize(filters(job.Id, new List<String>{ 'Platform Developer certification' }, options)));
        System.assertEquals(3, c.matched, 'the counts on the screen follow the same rule: Alpha, Charlie and Delta');
    }

    @IsTest static void onlyWholeWordsCountAndOnlyNamesOfSeveralWords() {
        Job__c job = newJob('Developer', '{"REST API":["REST API Integration"],"Structured Query Language":["SQL","Query Language"]}');
        candidate('Alpha', new List<String>{ 'Forest API Gateway' });          // contains "rest api" but not as words
        candidate('Bravo', new List<String>{ 'SQL Server' });                    // "SQL" is one word: exact name only
        candidate('Charlie', new List<String>{ 'REST API Integration Testing' }); // the alias "rest api integration" as words
        candidate('Delta', new List<String>{ 'SQL' });

        System.assertEquals(new List<String>{ 'Charlie' },
            names(CandidateMatchOrchestrator.findCandidates(filters(job.Id, new List<String>{ 'REST API' }, null), 200)));
        System.assertEquals(new List<String>{ 'Delta' },
            names(CandidateMatchOrchestrator.findCandidates(filters(job.Id, new List<String>{ 'Structured Query Language' }, null), 200)));
    }

    @IsTest static void manyAliasesStillGiveAValidQuery() {
        Map<String, List<String>> skillMap = new Map<String, List<String>>();
        List<String> selected = new List<String>();
        List<String> theirSkills = new List<String>();
        for (Integer i = 0; i < 12; i++) {
            String skill = 'Skill number ' + i;
            List<String> aliases = new List<String>();
            for (Integer j = 0; j < 10; j++) { aliases.add('Other name ' + i + ' variant ' + j); }
            skillMap.put(skill, aliases);
            selected.add(skill);
            theirSkills.add(skill);
        }
        Job__c job = newJob('Developer', JSON.serialize(skillMap));          // 120 aliases of two or more words: more than are matched inside longer names
        candidate('Alpha', theirSkills);

        System.assertEquals(new List<String>{ 'Alpha' }, names(CandidateMatchOrchestrator.findCandidates(filters(job.Id, selected, null), 200)),
            'no error; the exact names still match');
    }

    @IsTest static void aShorterNameMadeOfWordsOfTheSkillMatchesEvenWhenTheAiDidNotListIt() {
        // the skill map the AI saved for this job forgot the plain "REST API"
        Job__c job = newJob('Developer', '{"REST API Integration":["REST API Integrations","REST Integration"]}');
        candidate('Alpha', new List<String>{ 'REST API' });
        candidate('Bravo', new List<String>{ 'REST API Gateway' });       // shares two words but is not made of the skill's words
        candidate('Charlie', new List<String>{ 'GraphQL' });
        candidate('Delta', new List<String>{ 'API Integration' });         // also consecutive words of the skill
        List<String> selected = new List<String>{ 'REST API Integration' };

        System.assertEquals(new List<String>{ 'Alpha', 'Delta' }, names(CandidateMatchOrchestrator.findCandidates(filters(job.Id, selected, null), 200)));
        System.assertEquals(new List<String>{ 'Alpha', 'Delta' }, names(CandidateMatchOrchestrator.findCandidates(filters(null, selected, null), 200)),
            'worked out from the words, so it does not need the job\'s map');

        CandidateMatcherV2Controller.MatchCount c = CandidateMatcherV2Controller.countMatches(JSON.serialize(filters(job.Id, selected, selected)));
        System.assertEquals(2, c.matched, 'the counts on the screen follow the same rule');
    }

    @IsTest static void aLongerNameMatchesOnlyWhenTheSkillIsMostOfIt() {
        candidate('Alpha', new List<String>{ 'Salesforce Platform Developer I' });                // 3 of 4 words
        candidate('Bravo', new List<String>{ 'Platform Developer II' });                          // "II" is another word than "I"
        candidate('Charlie', new List<String>{ 'Salesforce Platform Developer I Certification' }); // 3 of 5 words (60%)
        candidate('Delta', new List<String>{ 'Salesforce Platform Developer I Certification Exam Preparation' }); // 3 of 7
        System.assertEquals(new List<String>{ 'Alpha', 'Charlie' },
            names(CandidateMatchOrchestrator.findCandidates(filters(null, new List<String>{ 'Platform Developer I' }, null), 200)));
    }

    @IsTest static void aSingleWordIsNeverCutOutOfALongerName() {
        candidate('Alpha', new List<String>{ 'Apex Development' });
        candidate('Bravo', new List<String>{ 'Salesforce' });
        candidate('Charlie', new List<String>{ 'Salesforce Flow Builder' });
        candidate('Delta', new List<String>{ 'Apex' });
        System.assertEquals(new List<String>{ 'Delta' },
            names(CandidateMatchOrchestrator.findCandidates(filters(null, new List<String>{ 'Apex' }, null), 200)),
            'one-word skills match by the exact name only');
        System.assertEquals(new List<String>{ 'Charlie' },
            names(CandidateMatchOrchestrator.findCandidates(filters(null, new List<String>{ 'Salesforce Flow' }, null), 200)),
            'a bare "Salesforce" is not enough for "Salesforce Flow"; "Salesforce Flow Builder" is 2 of 3 words');
    }

    @IsTest static void partialNamesAreConsecutiveWordsThatCoverEnough() {
        Set<String> three = CandidateMatchOrchestrator.partialNames('rest api integration');
        System.assertEquals(2, three.size());
        System.assert(three.contains('rest api') && three.contains('api integration'));
        Set<String> four = CandidateMatchOrchestrator.partialNames('salesforce platform developer certification');
        System.assertEquals(2, four.size(), 'three of four words only: two words are 50%');
        System.assert(four.contains('salesforce platform developer') && four.contains('platform developer certification'));
        System.assert(CandidateMatchOrchestrator.partialNames('rest api').isEmpty(), 'two words: nothing shorter with two words');
        System.assert(CandidateMatchOrchestrator.partialNames('apex').isEmpty());
        System.assert(CandidateMatchOrchestrator.partialNames('').isEmpty());
        System.assert(CandidateMatchOrchestrator.partialNames(null).isEmpty());
    }

    @IsTest static void aJobWithoutAMapOrWithABrokenMapMatchesExactNamesOnly() {
        candidate('Alpha', new List<String>{ 'Web Services' });
        candidate('Bravo', new List<String>{ 'REST API' });

        Job__c noMap = newJob('Developer', null);
        System.assertEquals(new List<String>{ 'Bravo' },
            names(CandidateMatchOrchestrator.findCandidates(filters(noMap.Id, new List<String>{ 'REST API' }, null), 200)));

        Job__c broken = newJob('Developer', 'this was edited by hand and is not JSON');
        System.assertEquals(new List<String>{ 'Bravo' },
            names(CandidateMatchOrchestrator.findCandidates(filters(broken.Id, new List<String>{ 'REST API' }, null), 200)),
            'no error: the filter falls back to the skill\'s own name');
    }

    @IsTest static void applyFiltersReadsTheJobsMapEvenIfTheScreenDidNotSendTheJob() {
        Job__c job = newJob('Developer', '{"REST API":["Web Services"]}');
        candidate('Alpha', new List<String>{ 'Web Services' });
        PromptRunner.mockByTemplate = new Map<String, String>{ CandidateMatchService.TEMPLATE =>
            '{"skillsScore":80,"experienceScore":80,"fitScore":80,"educationScore":80,"matchedSkills":[],"missingSkills":[],"fitNote":"ok","reasoning":"ok"}' };
        CandidateMatchOrchestrator.Filters f = new CandidateMatchOrchestrator.Filters();
        f.skills = new List<String>{ 'REST API' };                        // no jobId on purpose: start() adds it

        Test.startTest();
        CandidateMatchOrchestrator.StartResult r = CandidateMatchOrchestrator.start(job.Id, f);
        Test.stopTest();

        System.assertEquals(1, r.matched);
    }
}
