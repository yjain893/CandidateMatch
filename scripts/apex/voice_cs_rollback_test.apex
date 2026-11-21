// Can the shipping address of an order be changed, and which values does Salesforce accept?
// NOT RUN BY CLAUDE. You run it yourself:
//   sf apex run -o demoOrg --file scripts/apex/voice_cs_rollback_test.apex
// Every attempt is rolled back, so nothing is kept. Read the lines that start with RESULT in the log.
// It sends the same text values the agent's tool sends (ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, ShippingCountry).
// Limit: anonymous Apex runs as YOU, so this proves what Salesforce allows on the record, not what the integration user's permissions allow.
// To test the integration user, assign it the permission sets and watch the first real call, or use the REST API as that user.

List<Order> activated = [SELECT Id, OrderNumber FROM Order WHERE Account.Name LIKE 'DEMO - %' AND Status = 'Activated' ORDER BY OrderNumber LIMIT 1];
List<Order> draft = [SELECT Id, OrderNumber FROM Order WHERE Account.Name LIKE 'DEMO - %' AND Status = 'Draft' ORDER BY OrderNumber LIMIT 1];

List<String> labels = new List<String>();
List<Id> targets = new List<Id>();
List<Map<String, Object>> changes = new List<Map<String, Object>>();

if (activated.isEmpty()) {
    System.debug('RESULT no Activated demo order found, so those cases were not tested');
} else {
    String n = activated[0].OrderNumber;
    labels.add('Activated ' + n + ', street only');
    targets.add(activated[0].Id);
    changes.add(new Map<String, Object>{'ShippingStreet' => '103, London Street'});

    labels.add('Activated ' + n + ', full address with state and country as names');
    targets.add(activated[0].Id);
    changes.add(new Map<String, Object>{'ShippingStreet' => '103, London Street', 'ShippingCity' => 'San Francisco',
                                        'ShippingState' => 'California', 'ShippingPostalCode' => '94105', 'ShippingCountry' => 'United States'});

    labels.add('Activated ' + n + ', state and country as codes in the text fields');
    targets.add(activated[0].Id);
    changes.add(new Map<String, Object>{'ShippingStreet' => '103, London Street', 'ShippingState' => 'CA', 'ShippingCountry' => 'US'});

    labels.add('Activated ' + n + ', a state and country outside the picklists (free text)');
    targets.add(activated[0].Id);
    changes.add(new Map<String, Object>{'ShippingStreet' => '103, London Street', 'ShippingCity' => 'London',
                                        'ShippingState' => 'Greater London', 'ShippingCountry' => 'United Kingdom'});
}
if (draft.isEmpty()) {
    System.debug('RESULT no Draft demo order found, so that case was not tested');
} else {
    labels.add('Draft ' + draft[0].OrderNumber + ', street only');
    targets.add(draft[0].Id);
    changes.add(new Map<String, Object>{'ShippingStreet' => '103, London Street'});
}

for (Integer i = 0; i < labels.size(); i++) {
    Savepoint sp = Database.setSavepoint();
    try {
        Order o = new Order(Id = targets[i]);
        for (String field : changes[i].keySet()) {
            o.put(field, changes[i].get(field));
        }
        Database.SaveResult r = Database.update(o, false);
        if (r.isSuccess()) {
            System.debug('RESULT ' + labels[i] + ': accepted');
        } else {
            Database.Error e = r.getErrors()[0];
            System.debug('RESULT ' + labels[i] + ': REFUSED ' + e.getStatusCode() + ' - ' + e.getMessage());
        }
    } catch (Exception ex) {
        System.debug('RESULT ' + labels[i] + ': EXCEPTION ' + ex.getMessage());
    }
    Database.rollback(sp);
}
System.debug('RESULT done, everything was rolled back');
