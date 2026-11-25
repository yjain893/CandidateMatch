// Demo data for the voice agent in the serviceOrg sandbox. NOT run by Claude without your say-so.
// Every record is named "DEMO - ...". Undo with scripts/apex/serviceorg_demo_cleanup.apex.
// Deletes only records under accounts named "DEMO - ..." and the DEMO - product.
List<Order> demoOrders = [SELECT Id, Status FROM Order WHERE Account.Name LIKE 'DEMO - %'];
for (Order o : demoOrders) {
    o.Status = 'Draft';
}
update demoOrders;
delete [SELECT Id FROM OrderItem WHERE Order.Account.Name LIKE 'DEMO - %'];
delete demoOrders;
delete [SELECT Id FROM Contact WHERE Account.Name LIKE 'DEMO - %'];
delete [SELECT Id FROM PricebookEntry WHERE Product2.Name LIKE 'DEMO - %'];
delete [SELECT Id FROM Product2 WHERE Name LIKE 'DEMO - %'];
delete [SELECT Id FROM Account WHERE Name LIKE 'DEMO - %'];
System.debug('RESULT cleaned up: DEMO - accounts left ' + [SELECT COUNT() FROM Account WHERE Name LIKE 'DEMO - %']);
