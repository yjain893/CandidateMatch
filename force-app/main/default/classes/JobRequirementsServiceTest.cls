@IsTest
private class JobRequirementsServiceTest {
    @IsTest static void extractionFillsBlankFieldsOnly() {
        Job__c job = new Job__c(Name = 'Dev', Job_Description__c = '<p>Senior Java dev in Austin, hybrid, 5+ years.</p>', City__c = 'Dallas');
        insert job;
        JobRequirementsService.applyText(job.Id,
            '{"requiredSkills":["Java"],"niceToHaveSkills":["AWS"],"synonyms":["Java SE","J2EE"],'
            + '"location":"Austin, TX","workMode":"Hybrid","minExperienceYears":5}');
        Job__c r = [SELECT City__c, Work_Modes__c, Min_Experience_Years__c, Skill_Synonyms__c, Requirements_Hash__c FROM Job__c WHERE Id = :job.Id];
        System.assertEquals('Dallas', r.City__c);            // recruiter value kept
        System.assertEquals('Hybrid', r.Work_Modes__c);
        System.assertEquals(5, r.Min_Experience_Years__c);
        System.assert(r.Skill_Synonyms__c.contains('J2EE'));
        System.assertNotEquals(null, r.Requirements_Hash__c);
    }

    @IsTest static void aRepeatedKeyInTheAnswerStillWorks() {
        Job__c job = new Job__c(Name = 'Dev', Job_Description__c = 'Java dev, 5+ years');
        insert job;
        JobRequirementsService.applyText(job.Id,
            '{"requiredSkills":["Java"],"niceToHaveSkills":[],"synonyms":[],"minExperienceYears":3,"minExperienceYears":5}');
        System.assertEquals(5, [SELECT Min_Experience_Years__c FROM Job__c WHERE Id = :job.Id].Min_Experience_Years__c);
    }

    @IsTest static void normalizesWorkMode() {
        System.assertEquals('On-site', JobRequirementsService.normalizeMode('On site'));
        System.assertEquals('Remote', JobRequirementsService.normalizeMode('fully remote'));
        System.assertEquals(null, JobRequirementsService.normalizeMode('unknown'));
    }

    @IsTest static void richTextBecomesPlainText() {
        String t = JobRequirementsService.plain('<p>Java &amp; Apex</p><ul><li>SQL</li></ul>');
        System.assert(t.contains('Java & Apex'));
        System.assert(!t.contains('<'));
        System.assert(t.contains('SQL'));
    }
}