Date t = Date.today();
Id prod = [SELECT Product2Id FROM PricebookEntry WHERE Product2.ProductCode='COFFEE-CLUB' AND Pricebook2.IsStandard=true LIMIT 1].Product2Id;

// {Name, churnTier, churnScore, qty, daysUntilRenewal}
List<List<Object>> rows = new List<List<Object>>{
    new List<Object>{'Acme Roasters',     'A', 0.82, 10, 20},   // at-risk + due soon -> SAVE
    new List<Object>{'Bluebird Cafe',      'C', 0.09, 30, 15},   // healthy + large -> RENEW+UPSELL
    new List<Object>{'Downtown Diner',     'B', 0.45, 8,  45},   // medium -> RENEW
    new List<Object>{'Far Future Roastery','C', 0.07, 5,  200}   // not due -> filtered out
};
List<Account> accs = new List<Account>();
for (List<Object> r : rows) accs.add(new Account(Name=(String)r[0], Churn_Risk_Tier__c=(String)r[1], Churn_Score__c=(Double)r[2]));
insert accs;

List<Contact> cons = new List<Contact>();
List<Asset> assets = new List<Asset>();
for (Integer i=0;i<rows.size();i++){
    List<Object> r = rows[i];
    cons.add(new Contact(LastName='Owner', FirstName=(String)r[0], Email=((String)r[0]).deleteWhitespace().toLowerCase()+'@example.com', AccountId=accs[i].Id));
    assets.add(new Asset(Name='Coffee Club Subscription', AccountId=accs[i].Id, Product2Id=prod,
        Quantity=(Integer)r[3], Price=180, Status='Installed', InstallDate=t.addYears(-1).addDays((Integer)r[4]),
        UsageEndDate=t.addDays((Integer)r[4])));
}
insert cons;
insert assets;
System.debug('SEED_DONE accounts='+accs.size()+' assets='+assets.size());
