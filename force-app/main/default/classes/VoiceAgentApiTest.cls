@IsTest
private class VoiceAgentApiTest {

    private static final String CONTACT_Q = 'SELECT Id, FirstName, Email, AccountId, Phone, MobilePhone FROM Contact WHERE AccountId != null AND (Phone LIKE \'%0142\' OR MobilePhone LIKE \'%0142\') LIMIT 20';

    @TestSetup
    static void setup() {
        Account acct = new Account(Name = 'Voice Test Co');
        insert acct;
        insert new Contact(FirstName = 'Jo', LastName = 'Tester', AccountId = acct.Id, Phone = '(415) 555-0142', Email = 'jo@example.com');
        insert new Order(AccountId = acct.Id, EffectiveDate = Date.today(), Status = 'Draft');
    }

    private static RestResponse run(String method, String uri, Map<String, String> params, String body) {
        RestRequest req = new RestRequest();
        req.requestURI = uri;
        req.httpMethod = method;
        if (params != null) {
            for (String key : params.keySet()) {
                req.addParameter(key, params.get(key));
            }
        }
        if (body != null) {
            req.requestBody = Blob.valueOf(body);
        }
        RestContext.request = req;
        RestContext.response = new RestResponse();
        if (method == 'GET') {
            VoiceAgentApi.query();
        } else {
            VoiceAgentApi.updateOrder();
        }
        return RestContext.response;
    }

    private static RestResponse ask(String q) {
        return run('GET', '/services/apexrest/voiceagent/query', new Map<String, String>{'q' => q}, null);
    }

    private static Order theOrder() {
        return [SELECT Id, OrderNumber FROM Order LIMIT 1];
    }

    @IsTest
    static void findsAContactByTheLastFourDigits() {
        RestResponse res = ask(CONTACT_Q);
        System.assertEquals(200, res.statusCode);
        System.assert(res.responseBody.toString().contains('Jo'));
        System.assert(res.responseBody.toString().contains('jo@example.com'));
    }

    @IsTest
    static void findsAnOrderByNumber() {
        Order o = theOrder();
        RestResponse res = ask('SELECT Id, Status, ShippingStreet FROM Order WHERE OrderNumber = \'' + o.OrderNumber + '\' LIMIT 1');
        System.assertEquals(200, res.statusCode);
        System.assert(res.responseBody.toString().contains(o.Id));
    }

    @IsTest
    static void refusesAnyOtherQuery() {
        System.assertEquals(400, ask('SELECT Id FROM Account').statusCode);
        System.assertEquals(400, ask('SELECT Id FROM Order WHERE Id != null').statusCode);
        System.assertEquals(400, ask('SELECT Id FROM Order WHERE OrderNumber = \'1\' OR Id != null LIMIT 1').statusCode);
        System.assertEquals(400, ask('').statusCode);
    }

    @IsTest
    static void refusesFieldsOutsideTheList() {
        Order o = theOrder();
        System.assertEquals(400, ask('SELECT Id, Description FROM Order WHERE OrderNumber = \'' + o.OrderNumber + '\' LIMIT 1').statusCode);
        System.assertEquals(400, ask(CONTACT_Q.replace('Email', 'Birthdate')).statusCode);
    }

    @IsTest
    static void refusesAnUnknownPath() {
        System.assertEquals(404, run('GET', '/services/apexrest/voiceagent/other', new Map<String, String>{'q' => CONTACT_Q}, null).statusCode);
        System.assertEquals(404, run('PATCH', '/services/apexrest/voiceagent/contact/' + theOrder().Id, null, '{"ShippingCity":"X"}').statusCode);
    }

    @IsTest
    static void changesTheShippingAddress() {
        Order o = theOrder();
        RestResponse res = run('PATCH', '/services/apexrest/voiceagent/order/' + o.Id, null, '{"ShippingStreet":"103, London Street","ShippingCity":"London"}');
        System.assertEquals(204, res.statusCode);
        Order after = [SELECT ShippingStreet, ShippingCity FROM Order WHERE Id = :o.Id];
        System.assertEquals('103, London Street', after.ShippingStreet);
        System.assertEquals('London', after.ShippingCity);
    }

    @IsTest
    static void refusesToChangeAnythingElse() {
        Order o = theOrder();
        String uri = '/services/apexrest/voiceagent/order/' + o.Id;
        System.assertEquals(400, run('PATCH', uri, null, '{"Status":"Activated"}').statusCode);
        System.assertEquals(400, run('PATCH', uri, null, '{"ShippingCity":"X","TotalAmount":1}').statusCode);
        System.assertEquals('Draft', [SELECT Status FROM Order WHERE Id = :o.Id].Status);
    }

    @IsTest
    static void refusesBadInput() {
        Order o = theOrder();
        String uri = '/services/apexrest/voiceagent/order/' + o.Id;
        System.assertEquals(400, run('PATCH', uri, null, '{}').statusCode);
        System.assertEquals(400, run('PATCH', uri, null, 'not json').statusCode);
        System.assertEquals(400, run('PATCH', uri, null, '{"ShippingPostalCode":"123456789012345678901"}').statusCode);
        System.assertEquals(400, run('PATCH', '/services/apexrest/voiceagent/order/nonsense', null, '{"ShippingCity":"X"}').statusCode);
        Id anAccount = [SELECT Id FROM Account LIMIT 1].Id;
        System.assertEquals(400, run('PATCH', '/services/apexrest/voiceagent/order/' + anAccount, null, '{"ShippingCity":"X"}').statusCode);
    }

    @IsTest
    static void worksForAnApiOnlyIntegrationUser() {
        List<Profile> profiles = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - API Only Integrations' LIMIT 1];
        if (profiles.isEmpty()) {
            return;   // this org has no such profile
        }
        Order o = theOrder();
        User integration;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            integration = new User(Username = 'voiceagent.test.' + System.currentTimeMillis() + '@example.com', LastName = 'Integration',
                                   Email = 'noreply@example.com', Alias = 'vint', ProfileId = profiles[0].Id, TimeZoneSidKey = 'America/Los_Angeles',
                                   LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US');
            insert integration;
            // the add-on license that lets an API-only integration user work with standard objects such as Contact and Order
            List<PermissionSetLicense> addOn = [SELECT Id FROM PermissionSetLicense WHERE DeveloperName = 'SalesforceAPIIntegration'];
            if (!addOn.isEmpty()) {
                insert new PermissionSetLicenseAssign(AssigneeId = integration.Id, PermissionSetLicenseId = addOn[0].Id);
            }
            List<PermissionSet> sets = [SELECT Id FROM PermissionSet WHERE Name = 'Voice_Agent_Access'];
            if (!sets.isEmpty()) {
                insert new PermissionSetAssignment(AssigneeId = integration.Id, PermissionSetId = sets[0].Id);
            }
        }
        System.runAs(integration) {
            RestResponse contacts = ask(CONTACT_Q);
            System.assertEquals(200, contacts.statusCode, 'contact lookup as the integration user: ' + contacts.responseBody);
            System.assert(contacts.responseBody.toString().contains('jo@example.com'));
            RestResponse orders = ask('SELECT Id, Status, ShippingStreet FROM Order WHERE OrderNumber = \'' + o.OrderNumber + '\' LIMIT 1');
            System.assertEquals(200, orders.statusCode, 'order lookup as the integration user: ' + orders.responseBody);
            RestResponse changed = run('PATCH', '/services/apexrest/voiceagent/order/' + o.Id, null, '{"ShippingStreet":"1 Test Road"}');
            System.assertEquals(204, changed.statusCode, 'address change as the integration user: ' + changed.responseBody);
        }
        System.assertEquals('1 Test Road', [SELECT ShippingStreet FROM Order WHERE Id = :o.Id].ShippingStreet);
    }
}
