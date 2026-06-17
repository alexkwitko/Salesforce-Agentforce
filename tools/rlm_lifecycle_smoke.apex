// Fresh test buyer
Account acc = new Account(Name='RLM Demo Buyer');
insert acc;
Contact c = new Contact(LastName='Demo', Email='rlm.demo@example.com', AccountId=acc.Id);
insert c;

// 1. PROVISION (by email)
SubProvision.Request pr = new SubProvision.Request();
pr.email='rlm.demo@example.com'; pr.productCode='COFFEE-CLUB'; pr.quantity=10;
System.debug('PROVISION >> ' + SubProvision.run(new List<SubProvision.Request>{pr})[0].summary);

// 2. GET
SubGetMySubscriptions.Request gr = new SubGetMySubscriptions.Request();
gr.email='rlm.demo@example.com';
System.debug('GET >> ' + SubGetMySubscriptions.run(new List<SubGetMySubscriptions.Request>{gr})[0].summary);

// 3. AMEND (by email, resolves latest sub) to 25
SubAmend.Request ar = new SubAmend.Request();
ar.email='rlm.demo@example.com'; ar.newQuantity=25;
System.debug('AMEND >> ' + SubAmend.run(new List<SubAmend.Request>{ar})[0].summary);

// 4. RENEW 12 months
SubRenew.Request rr = new SubRenew.Request();
rr.email='rlm.demo@example.com'; rr.termMonths=12;
System.debug('RENEW >> ' + SubRenew.run(new List<SubRenew.Request>{rr})[0].summary);

// 5. CANCEL
SubCancel.Request cr = new SubCancel.Request();
cr.email='rlm.demo@example.com';
System.debug('CANCEL >> ' + SubCancel.run(new List<SubCancel.Request>{cr})[0].summary);
