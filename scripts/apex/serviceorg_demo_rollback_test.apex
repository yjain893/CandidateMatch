// Demo data for the voice agent in the serviceOrg sandbox. NOT run by Claude without your say-so.
// Every record is named "DEMO - ...". Undo with scripts/apex/serviceorg_demo_cleanup.apex.
// Runs create and then cleanup inside one transaction and rolls it back: nothing is kept. Read the RESULT lines.
Savepoint sp = Database.setSavepoint();
{
    Id stdBook = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
    System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Name LIKE 'DEMO - %'], 'DEMO - accounts already exist, nothing was created');

    List<Account> accts = new List<Account>{
        new Account(Name = 'DEMO - Northwind Clinic'),
        new Account(Name = 'DEMO - Riverside Pharmacy'),
        new Account(Name = 'DEMO - Lakeview Hospital')
    };
    insert accts;

    insert new List<Contact>{
        new Contact(FirstName = 'John',  LastName = 'DEMO - Walker', AccountId = accts[0].Id, Phone = '(415) 555-0201', Email = 'john.demo@example.com'),
        new Contact(FirstName = 'Maria', LastName = 'DEMO - Lopez',  AccountId = accts[1].Id, Phone = '(415) 555-0202', Email = 'maria.demo@example.com'),
        new Contact(FirstName = 'Ahmed', LastName = 'DEMO - Khan',   AccountId = accts[2].Id, Phone = '(415) 555-0203', Email = 'ahmed.demo@example.com')
    };

    Product2 prod = new Product2(Name = 'DEMO - Test Item', IsActive = true);
    insert prod;
    PricebookEntry entry = new PricebookEntry(Pricebook2Id = stdBook, Product2Id = prod.Id, UnitPrice = 1000, IsActive = true);
    insert entry;

    List<List<String>> addresses = new List<List<String>>{
        new List<String>{'100 Market Street',   'San Francisco', 'California', '94105', 'United States'},
        new List<String>{'200 Mission Street',  'San Francisco', 'California', '94105', 'United States'},
        new List<String>{'300 Howard Street',   'San Francisco', 'California', '94105', 'United States'},
        new List<String>{'400 Folsom Street',   'San Francisco', 'California', '94107', 'United States'},
        new List<String>{'500 Brannan Street',  'San Francisco', 'California', '94107', 'United States'},
        new List<String>{'600 Townsend Street', 'San Francisco', 'California', '94103', 'United States'}
    };
    List<Order> orders = new List<Order>();
    for (Integer i = 0; i < 6; i++) {
        orders.add(new Order(AccountId = accts[Math.mod(i, 3)].Id, Pricebook2Id = stdBook, Status = 'Draft',
                             EffectiveDate = Date.today().addDays(-3 * i), EndDate = Date.today().addDays(7 - 3 * i),
                             ShippingStreet = addresses[i][0], ShippingCity = addresses[i][1], ShippingState = addresses[i][2],
                             ShippingPostalCode = addresses[i][3], ShippingCountry = addresses[i][4]));
    }
    insert orders;

    List<OrderItem> lines = new List<OrderItem>();
    for (Integer i = 0; i < orders.size(); i++) {
        lines.add(new OrderItem(OrderId = orders[i].Id, PricebookEntryId = entry.Id, Quantity = 1, UnitPrice = 1000 * (i + 1)));
    }
    insert lines;

    // two stay Draft, two are Activated, one Shipped, one Delivered
    for (Integer i = 2; i < 6; i++) {
        orders[i].Status = 'Activated';
    }
    update orders;
    orders[4].Status = 'Shipped';
    orders[5].Status = 'Delivered';
    update orders;
    System.debug('RESULT created accounts ' + accts.size() + ', contacts 3, orders ' + orders.size() + ', order lines ' + lines.size());
}
{
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
}
Database.rollback(sp);
System.debug('RESULT rolled back, nothing was kept; DEMO - accounts now ' + [SELECT COUNT() FROM Account WHERE Name LIKE 'DEMO - %']);
