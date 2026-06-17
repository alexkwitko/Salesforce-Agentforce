Id acct = [SELECT Id FROM Account ORDER BY CreatedDate DESC LIMIT 1].Id;
Id prod = [SELECT Id FROM Product2 WHERE ProductCode='COFFEE-CLUB' LIMIT 1].Id;
Asset a = new Asset(
    Name='Coffee Club Subscription',
    AccountId=acct, Product2Id=prod,
    Quantity=10, Price=18, Status='Active',
    InstallDate=Date.today(),
    LifecycleStartDate=Date.today(),
    LifecycleEndDate=Date.today().addYears(1)
);
insert a;
System.debug('ASSET_OK='+a.Id);
