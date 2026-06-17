String stamp = Datetime.now().formatGMT('yyyyMMddHHmmss');
String email = 'alexkwitko+postlive' + stamp + '@gmail.com';

Id personAccountRt = [
    SELECT Id
    FROM RecordType
    WHERE SObjectType = 'Account'
      AND IsPersonType = true
    LIMIT 1
].Id;

Account account = new Account(
    FirstName = 'Post',
    LastName = 'Live ' + stamp,
    PersonEmail = email,
    Email_Consent__c = true,
    RecordTypeId = personAccountRt
);
insert account;

PricebookEntry pbe = [
    SELECT Id, Product2Id, UnitPrice, Pricebook2Id
    FROM PricebookEntry
    WHERE IsActive = true
      AND Pricebook2.IsStandard = true
      AND Product2.Woo_Product_Id__c != null
      AND Product2.Family IN ('Single-Origin', 'Blends', 'Espresso')
    ORDER BY UnitPrice DESC
    LIMIT 1
];

Order orderRecord = new Order(
    AccountId = account.Id,
    EffectiveDate = Date.today(),
    Status = 'Draft',
    Pricebook2Id = pbe.Pricebook2Id,
    Source__c = 'Ecommerce',
    Woo_Order_Id__c = 'CODEXPOST' + stamp,
    Woo_Status__c = 'completed',
    Fulfillment_Status__c = 'Shipped'
);
insert orderRecord;

insert new OrderItem(
    OrderId = orderRecord.Id,
    PricebookEntryId = pbe.Id,
    Product2Id = pbe.Product2Id,
    Quantity = 1,
    UnitPrice = pbe.UnitPrice
);

update new Order(Id = orderRecord.Id, Status = 'Activated');

Order created = [
    SELECT Id, OrderNumber, Woo_Order_Id__c, Account.PersonEmail
    FROM Order
    WHERE Id = :orderRecord.Id
    LIMIT 1
];
System.debug('CODEX_POST_PURCHASE_PROOF_ORDER=' + JSON.serialize(created));
