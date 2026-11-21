// Undoes scripts/apex/voice_cs_demo_create.apex.
// NOT RUN BY CLAUDE. You run it yourself:
//   sf apex run -o demoOrg --file scripts/apex/voice_cs_demo_cleanup.apex
// Deletes only the demo contacts it created (last name "DEMO - ..." and an email ending in ".demo@example.com"),
// and clears the shipping address of the orders of "DEMO - " accounts. Nothing else is touched.

List<Contact> demoContacts = [SELECT Id FROM Contact WHERE LastName LIKE 'DEMO - %' AND Email LIKE '%.demo@example.com'];
delete demoContacts;
System.debug('DEMO contacts deleted: ' + demoContacts.size());

List<Order> orders = [SELECT Id FROM Order WHERE Account.Name LIKE 'DEMO - %'];
for (Order o : orders) {
    o.ShippingStreet = null;
    o.ShippingCity = null;
    o.ShippingStateCode = null;
    o.ShippingPostalCode = null;
    o.ShippingCountryCode = null;
}
update orders;
System.debug('DEMO order addresses cleared: ' + orders.size());
