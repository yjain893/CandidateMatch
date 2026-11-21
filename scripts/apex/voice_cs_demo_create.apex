// Demo data for the customer service voice agent.
// NOT RUN BY CLAUDE. You run it yourself, after reading it:
//   sf apex run -o demoOrg --file scripts/apex/voice_cs_demo_create.apex
// What it does:
//   1. Creates up to 3 contacts (phone and email) on the first 3 "DEMO - " accounts.
//      Last names start with "DEMO - ". Skips a contact whose email already exists, so it is safe to run twice.
//   2. Fills the shipping address of the demo orders that have none.
// What it never touches: the Candidate Match contacts, and any record that is not a DEMO - account, a DEMO - contact or an order of a DEMO - account.
// Phone numbers use the fictional 555-01xx range. Undo with scripts/apex/voice_cs_demo_cleanup.apex.

List<Account> accts = [SELECT Id, Name FROM Account WHERE Name LIKE 'DEMO - %' ORDER BY Name LIMIT 3];
// stops the script before any change if there are fewer than 3 demo accounts (the log then shows an AssertException with this text)
System.assert(accts.size() >= 3, 'Expected at least 3 accounts named "DEMO - ...", found ' + accts.size() + '. Nothing was changed.');

List<List<String>> people = new List<List<String>>{
    new List<String>{'John',  'DEMO - Walker', '(415) 555-0101', 'john.demo@example.com'},
    new List<String>{'Maria', 'DEMO - Lopez',  '(415) 555-0102', 'maria.demo@example.com'},
    new List<String>{'Ahmed', 'DEMO - Khan',   '(415) 555-0103', 'ahmed.demo@example.com'}
};

Set<String> existingEmails = new Set<String>();
for (Contact c : [SELECT Email FROM Contact WHERE LastName LIKE 'DEMO - %']) {
    existingEmails.add(c.Email);
}

List<Contact> newContacts = new List<Contact>();
for (Integer i = 0; i < people.size(); i++) {
    if (existingEmails.contains(people[i][3])) {
        continue;
    }
    newContacts.add(new Contact(FirstName = people[i][0], LastName = people[i][1], AccountId = accts[i].Id,
                                Phone = people[i][2], Email = people[i][3]));
}
insert newContacts;
System.debug('DEMO contacts created: ' + newContacts.size());

List<List<String>> addresses = new List<List<String>>{
    new List<String>{'100 Market Street',   'San Francisco', 'CA', '94105', 'US'},
    new List<String>{'200 Mission Street',  'San Francisco', 'CA', '94105', 'US'},
    new List<String>{'300 Howard Street',   'San Francisco', 'CA', '94105', 'US'},
    new List<String>{'400 Folsom Street',   'San Francisco', 'CA', '94107', 'US'},
    new List<String>{'500 Brannan Street',  'San Francisco', 'CA', '94107', 'US'},
    new List<String>{'600 Townsend Street', 'San Francisco', 'CA', '94103', 'US'}
};

List<Order> orders = [SELECT Id, OrderNumber, ShippingStreet FROM Order WHERE Account.Name LIKE 'DEMO - %' ORDER BY OrderNumber];
List<Order> toUpdate = new List<Order>();
for (Integer i = 0; i < orders.size() && i < addresses.size(); i++) {
    if (String.isNotBlank(orders[i].ShippingStreet)) {
        continue;
    }
    orders[i].ShippingStreet = addresses[i][0];
    orders[i].ShippingCity = addresses[i][1];
    orders[i].ShippingStateCode = addresses[i][2];
    orders[i].ShippingPostalCode = addresses[i][3];
    orders[i].ShippingCountryCode = addresses[i][4];
    toUpdate.add(orders[i]);
}
update toUpdate;
System.debug('DEMO order addresses filled: ' + toUpdate.size());
